import Contracts
import Foundation
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// Building the environment and loading the symbol list: a server that is down at launch, a list that comes back
/// empty, a launch that is cancelled or called twice, and what is started once the list is there.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppEnvironmentTests {
    // MARK: Construction

    @Test func buildingTheEnvironmentStartsNothing() {
        let rig = EnvRig()
        #expect(rig.log.entries.isEmpty)
        #expect(rig.builds.market.isEmpty)
        #expect(rig.builds.trading.count == 1)
        #expect(rig.tradingClient.starts == 0)
        #expect(rig.rest.symbolCalls == 0)
        #expect(rig.rest.accountCalls == 0)
        #expect(rig.sleeper.requested == 0)
        #expect(!rig.env.pump.isRunning)
        #expect(rig.env.symbols.isEmpty)
        #expect(rig.env.marketConnection == .connecting)
        #expect(rig.env.tradingConnection == .connecting)
    }

    @Test func theEnvironmentKeepsTheNoticeOfItsConfig() {
        // A config that is used as given has no notice to keep.
        let usable = EnvRig()
        #expect(usable.env.configNotice == nil)

        let mistyped = ClientConfig(host: "bad host")
        let rig = EnvRig(config: mistyped)
        #expect(rig.env.configNotice != nil)
        #expect(rig.env.configNotice == AppEnvironment.configNotice(for: mistyped))
    }

    @Test func oneRecorderIsSharedByTheStateTheClientAndTheStore() async throws {
        let rig = EnvRig()
        await rig.env.bootstrap()
        let market = try #require(rig.builds.market.first)
        let trading = try #require(rig.builds.trading.first)
        #expect(market.latency === rig.env.latency)
        #expect(trading.latency === rig.env.latency)
        #expect(market.state === rig.env.marketState)
        #expect(market.config == rig.env.config)
        #expect(trading.config == rig.env.config)

        // The state records into the environment's recorder.
        _ = rig.env.marketState.apply(
            frame: marketFrame(sendNs: 1_000, updates: [symbolUpdate(seq: 1)]), receivedAtNs: 2_000
        )
        #expect(rig.env.latency.summary(.tickToApp) == summary(of: [1_000]))

        // The store reads the account through the environment's REST API, and records into its recorder.
        #expect(rig.rest.accountCalls >= 1)
        await rig.env.trading.submit(
            OrderDraft(clientOrderId: "C-1", symbolId: 4, side: .buy, type: .market, quantity: 100)
        )
        let handlers = try #require(rig.tradingClient.handlers)
        await handlers.onEvent(acceptedEvent(1, client: "C-1", order: "O-1"))
        await handlers.onEvent(fillEvent(2, order: "O-1"))
        #expect(rig.env.latency.summary(.orderSubmitToFill).count == 1)
    }

    // MARK: Retrying the list

    @Test func bootstrapRetriesUntilServerIsUp() async {
        let rig = EnvRig(rest: FakeRest([.failure(URLError(.cannotConnectToHost)), .failure(URLError(.timedOut))]))
        await rig.env.bootstrap()
        #expect(rig.rest.symbolCalls == 3)
        // The waits are the backoff for the first and second retry at full jitter, and no real time passed.
        #expect(rig.sleeper.durations == [.milliseconds(250), .milliseconds(500)])
        #expect(rig.env.symbols == sampleSymbols)
        #expect(rig.market.starts == 1)
        #expect(rig.tradingClient.starts == 1)
    }

    @Test func theWaitsFollowTheBackoffAndItsCap() async {
        let failures = [FakeRest.Answer](repeating: .failure(URLError(.cannotConnectToHost)), count: 8)
        let rig = EnvRig(rest: FakeRest(failures))
        await rig.env.bootstrap()
        let expected: [Duration] = [
            .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(10),
            .seconds(10),
        ]
        #expect(rig.sleeper.durations == expected)
        #expect(rig.rest.symbolCalls == 9)
    }

    @Test func theWaitUsesTheJitterTheEnvironmentIsGiven() async {
        let sleeper = FakeSleeper()
        let env = AppEnvironment(
            config: ClientConfig(), rest: FakeRest([.failure(URLError(.timedOut))]),
            makeMarketClient: { _, _, _, _ in FakeMarketClient(log: EventLog()) },
            makeTradingClient: { _, _ in FakeTradingClient(log: EventLog()) },
            sleep: { try await sleeper.sleep($0) }, jitter: { 0.0 }
        )
        await env.bootstrap()
        // A jitter of 0 halves the first wait.
        #expect(sleeper.durations == [.milliseconds(125)])
    }

    @Test func bothConnectionsReadReconnectingWhileTheListCannotLoad() async {
        let rig = EnvRig(
            rest: FakeRest([.failure(URLError(.cannotConnectToHost)), .failure(URLError(.cannotConnectToHost))]),
            sleeper: FakeSleeper(.holdUntilReleased)
        )
        let (task, finished) = rig.bootstrapInTask()
        await waitFor("the first wait begins") { rig.sleeper.requested == 1 }
        #expect(rig.env.marketConnection == .reconnecting(attempt: 1))
        #expect(rig.env.tradingConnection == .reconnecting(attempt: 1))
        #expect(rig.env.symbols.isEmpty)
        #expect(!finished.isSet)

        rig.sleeper.release()
        await waitFor("the second wait begins") { rig.sleeper.requested == 2 }
        #expect(rig.env.marketConnection == .reconnecting(attempt: 2))
        #expect(rig.env.tradingConnection == .reconnecting(attempt: 2))

        rig.sleeper.release()
        await waitFor("the list is loaded") { finished.isSet }
        // The clients' own states take over: both say `.connecting` once started.
        await waitFor("both clients report") {
            rig.env.marketConnection == .connecting && rig.env.tradingConnection == .connecting
        }
        #expect(rig.env.symbols == sampleSymbols)
        task.cancel()
    }

    @Test func anEmptyListCountsAsAFailedAttempt() async {
        let rig = EnvRig(rest: FakeRest([.list([])]))
        await rig.env.bootstrap()
        #expect(rig.rest.symbolCalls == 2)
        #expect(rig.sleeper.durations == [.milliseconds(250)])
        #expect(rig.env.symbols == sampleSymbols)
        #expect(rig.market.starts == 1)
    }

    @Test func theListKeepsTheServersOrder() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        #expect(rig.env.symbols.map(\.ticker) == ["PTT", "AOT", "CPALL"])
        #expect(rig.builds.market.first?.symbols == sampleSymbols)
    }

    // MARK: Cancelling and calling twice

    @Test func aBootstrapCancelledDuringTheWaitStartsNothingAndALaterCallStartsOneClient() async {
        let rig = EnvRig(
            rest: FakeRest([.failure(URLError(.cannotConnectToHost))]), sleeper: FakeSleeper(.holdUntilReleased)
        )
        let (task, finished) = rig.bootstrapInTask()
        await waitFor("the wait begins") { rig.sleeper.requested == 1 }
        task.cancel()
        await waitFor("the cancelled call returns") { finished.isSet }
        #expect(rig.builds.market.isEmpty)
        #expect(rig.market.starts == 0)
        #expect(rig.tradingClient.starts == 0)
        #expect(rig.env.symbols.isEmpty)

        // The environment is idle again, so a later call does the job.
        await rig.env.bootstrap()
        #expect(rig.builds.market.count == 1)
        #expect(rig.market.starts == 1)
        #expect(rig.tradingClient.starts == 1)
        #expect(rig.env.symbols == sampleSymbols)
    }

    @Test func aListThatArrivesAfterTheCancellationStartsNothing() async {
        let rig = EnvRig(rest: FakeRest([.hold]))
        let (task, finished) = rig.bootstrapInTask()
        await waitFor("the request is out") { rig.rest.heldCount == 1 }
        task.cancel()
        let released = rig.rest.release(.success(sampleSymbols))
        #expect(released)
        await waitFor("the cancelled call returns") { finished.isSet }
        #expect(rig.builds.market.isEmpty)
        #expect(rig.market.starts == 0)
        #expect(rig.tradingClient.starts == 0)
        #expect(rig.env.symbols.isEmpty)

        await rig.env.bootstrap()
        #expect(rig.market.starts == 1)
        #expect(rig.tradingClient.starts == 1)
    }

    @Test func aCancellationErrorFromTheRequestLeavesAtOnce() async {
        let rig = EnvRig(rest: FakeRest([.failure(CancellationError())]))
        await rig.env.bootstrap()
        #expect(rig.rest.symbolCalls == 1)
        #expect(rig.sleeper.requested == 0)
        #expect(rig.env.marketConnection == .connecting)
        #expect(rig.market.starts == 0)

        await rig.env.bootstrap()
        #expect(rig.market.starts == 1)
    }

    @Test func anErrorOfACancelledRequestIsNotAFailedAttempt() async {
        let rig = EnvRig(rest: FakeRest([.hold]))
        let (task, finished) = rig.bootstrapInTask()
        await waitFor("the request is out") { rig.rest.heldCount == 1 }
        task.cancel()
        // What the URL loading system throws when the task that awaits a request is cancelled.
        let released = rig.rest.release(.failure(URLError(.cancelled)))
        #expect(released)
        await waitFor("the cancelled call returns") { finished.isSet }
        #expect(rig.sleeper.requested == 0)
        #expect(rig.env.marketConnection == .connecting)
        #expect(rig.env.tradingConnection == .connecting)
        #expect(rig.market.starts == 0)

        await rig.env.bootstrap()
        #expect(rig.market.starts == 1)
    }

    @Test func aSleepThatThrowsLeavesTheLoopAndALaterCallBeginsAgain() async {
        let rig = EnvRig(
            rest: FakeRest([.failure(URLError(.cannotConnectToHost))]), sleeper: FakeSleeper(.throwError(TestFailure()))
        )
        await rig.env.bootstrap()
        #expect(rig.rest.symbolCalls == 1)
        #expect(rig.sleeper.requested == 1)
        #expect(rig.market.starts == 0)

        await rig.env.bootstrap()
        #expect(rig.rest.symbolCalls == 2)
        #expect(rig.market.starts == 1)
    }

    @Test func aSecondCallAfterSuccessStartsNoSecondClient() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        await rig.env.bootstrap()
        #expect(rig.rest.symbolCalls == 1)
        #expect(rig.builds.market.count == 1)
        #expect(rig.market.starts == 1)
        #expect(rig.market.subscribed.count == 1)
        #expect(rig.tradingClient.starts == 1)
    }

    @Test func aCallWhileOneIsRunningReturnsAtOnce() async {
        let rig = EnvRig(rest: FakeRest([.hold]))
        let (_, finished) = rig.bootstrapInTask()
        await waitFor("the request is out") { rig.rest.heldCount == 1 }

        await rig.env.bootstrap()
        // It came back without asking the server again, while the first call is still waiting for its list.
        #expect(rig.rest.symbolCalls == 1)
        #expect(!finished.isSet)
        #expect(rig.market.starts == 0)

        // The running call does the job once its list arrives.
        let released = rig.rest.release(.success(sampleSymbols))
        #expect(released)
        await waitFor("the first call returns") { finished.isSet }
        #expect(rig.market.starts == 1)
        #expect(rig.tradingClient.starts == 1)
        #expect(rig.builds.market.count == 1)
    }

    // MARK: Starting up

    @Test func theTickersAreSubscribedBeforeTheClientStarts() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        #expect(rig.market.subscribed == [["PTT", "AOT", "CPALL"]])
        let market = rig.log.entries.filter { $0.hasPrefix("market.") }
        // The state observer is made first, then the tickers are stored, and only then does the client connect.
        #expect(market == ["market.connection", "market.subscribe", "market.start"])
    }

    @Test func theMarketStartsBeforeTradingAndTradingIsObservedAfterItsStart() async throws {
        let rig = EnvRig()
        await rig.env.bootstrap()
        let entries = rig.log.entries
        let marketStart = try #require(entries.firstIndex(of: "market.start"))
        let tradingStart = try #require(entries.firstIndex(of: "trading.startEventStream"))
        #expect(marketStart < tradingStart)
        // The store watches the connection right after it starts the stream and the environment's own observer
        // comes after that: a stream made before the start would be dead for a client that was stopped before.
        let trading = entries.filter { $0.hasPrefix("trading.") }
        #expect(trading == ["trading.startEventStream", "trading.connection", "trading.connection"])
    }

    @Test func theTradingStreamIsStartedOnceAndTheEnvironmentNeverTradesByItself() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        #expect(rig.tradingClient.starts == 1)
        #expect(rig.tradingClient.handlers != nil)
        #expect(rig.tradingClient.nudges == 0)
        #expect(rig.tradingClient.stops == 0)
        #expect(rig.env.trading.state.orders.isEmpty)
    }
}

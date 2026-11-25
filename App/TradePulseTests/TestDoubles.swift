import Contracts
import Foundation
import Synchronization
import TradeCore
import TradeNetworking

// The doubles the app's tests stand in for the network with. None of them opens a socket or waits for time to pass:
// each answers at once, or holds a call until the test lets it go.

/// The calls the fakes of one test received, in the order they arrived.
final class EventLog: Sendable {
    /// The entries so far, oldest first.
    private let lines = Mutex<[String]>([])

    /// Notes that `line` happened.
    func add(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    /// Everything noted so far, in the order it happened.
    var entries: [String] {
        lines.withLock { $0 }
    }
}

/// The connection states a fake client reports: every stream it hands out yields the current state first, if there is
/// one, and then every state the test pushes; a stream ends when the client is stopped.
final class StateHub: Sendable {
    /// How a stream of states ended.
    typealias Termination = AsyncStream<ConnectionState>.Continuation.Termination

    /// What the hub keeps between calls, under one lock.
    private struct Shared {
        /// The state a new stream says first; nil before the first one was pushed.
        var current: ConnectionState?
        /// The streams that are open.
        var observers: [AsyncStream<ConnectionState>.Continuation] = []
        /// How the streams that are over ended, in the order they ended.
        var terminations: [Termination] = []
    }

    /// The hub's state.
    private let shared = Mutex(Shared())

    /// A new stream, as the real clients hand out on every access.
    func makeStream() -> AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionState.self)
        continuation.onTermination = { [weak self] termination in
            self?.shared.withLock { $0.terminations.append(termination) }
        }
        shared.withLock { shared in
            if let current = shared.current { continuation.yield(current) }
            shared.observers.append(continuation)
        }
        return stream
    }

    /// Makes `state` the current one and sends it to every open stream.
    func push(_ state: ConnectionState) {
        let observers = shared.withLock { shared in
            shared.current = state
            return shared.observers
        }
        for observer in observers { observer.yield(state) }
    }

    /// What a stopped client does: says `.stopped` and ends every stream.
    func stop() {
        let observers = shared.withLock { shared in
            shared.current = .stopped
            defer { shared.observers = [] }
            return shared.observers
        }
        for observer in observers {
            observer.yield(.stopped)
            observer.finish()
        }
    }

    /// How the streams that are over ended: cancelled by their reader, or finished by the client.
    var terminations: [Termination] {
        shared.withLock { $0.terminations }
    }
}

/// A market client that records what it was asked, in order, and reports the states the test pushes. With
/// `holdsSubscribe` its first `subscribe` does not return until the test calls `releaseSubscribe()`.
final class FakeMarketClient: MarketDataClient {
    /// What the client counts between calls, under one lock.
    private struct Shared {
        /// The tickers of every `subscribe` call, in order.
        var subscribed: [[String]] = []
        /// How many times `start()` was called.
        var starts = 0
        /// How many times `stop()` was called.
        var stops = 0
        /// How many times `nudge()` was called.
        var nudges = 0
    }

    /// Where the client notes every call it gets.
    private let log: EventLog
    /// The states the client reports.
    private let hub = StateHub()
    /// Whether the first `subscribe` waits for `releaseSubscribe()`.
    private let holdsSubscribe: Bool
    /// Set when `subscribe` was entered.
    private let entered = Flag()
    /// What a held `subscribe` waits on.
    private let gate = AsyncStream<Void>.makeStream()
    /// The client's counters.
    private let shared = Mutex(Shared())

    /// A client that notes its calls in `log`.
    init(log: EventLog, holdsSubscribe: Bool = false) {
        self.log = log
        self.holdsSubscribe = holdsSubscribe
    }

    /// A new stream of the client's states on every access, as the real client gives.
    var connection: AsyncStream<ConnectionState> {
        log.add("market.connection")
        return hub.makeStream()
    }

    /// Like the supervised client, it says `.connecting` as soon as it starts.
    func start() {
        log.add("market.start")
        shared.withLock { $0.starts += 1 }
        hub.push(.connecting)
    }

    /// Notes the stop, says `.stopped` and ends every stream.
    func stop() async {
        log.add("market.stop")
        shared.withLock { $0.stops += 1 }
        hub.stop()
    }

    /// Notes the tickers, and waits for `releaseSubscribe()` when the client holds its subscribe.
    func subscribe(_ tickers: [String]) async {
        log.add("market.subscribe")
        shared.withLock { $0.subscribed.append(tickers) }
        entered.set()
        guard holdsSubscribe else { return }
        var iterator = gate.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    /// Notes the call.
    func unsubscribe(_ tickers: [String]) async {
        log.add("market.unsubscribe")
    }

    /// Notes and counts the call.
    func nudge() {
        log.add("market.nudge")
        shared.withLock { $0.nudges += 1 }
    }

    /// The offset between the server's clock and the client's, which a fake does not have.
    var clockOffsetNs: Int64 { 0 }

    /// Sends `state` to everyone watching the connection.
    func push(_ state: ConnectionState) {
        hub.push(state)
    }

    /// Lets a held `subscribe` return.
    func releaseSubscribe() {
        gate.continuation.yield()
    }

    /// The tickers of every `subscribe` call, in order.
    var subscribed: [[String]] { shared.withLock { $0.subscribed } }
    /// How many times `start()` was called.
    var starts: Int { shared.withLock { $0.starts } }
    /// How many times `stop()` was called.
    var stops: Int { shared.withLock { $0.stops } }
    /// How many times `nudge()` was called.
    var nudges: Int { shared.withLock { $0.nudges } }
    /// Whether `subscribe` was called, even if it has not returned yet.
    var hasEnteredSubscribe: Bool { entered.isSet }
    /// How the streams that are over ended.
    var terminations: [StateHub.Termination] { hub.terminations }
}

/// A trading client that keeps the three closures of its event stream for the test, counts what it is asked and reports
/// the states the test pushes. `submit` answers a canned acceptance and `cancel` answers false. Starting the event
/// stream makes `startsAs` its state, as a supervised client says `.connecting` the moment it starts.
final class FakeTradingClient: TradingClient {
    /// The three closures the store gave the event stream.
    struct Handlers: Sendable {
        /// Where the stream resumes: the last event number seen and the epoch it belongs to.
        let resumeFrom: @Sendable () -> (seq: UInt64, epoch: String?)
        /// Takes one order event.
        let onEvent: @Sendable (Tp_OrderEvent) async -> Void
        /// Called when the server cannot resume the stream where it left off.
        let onOutOfRange: @Sendable () async -> Void
    }

    /// What the client counts between calls, under one lock.
    private struct Shared {
        /// The closures of the event stream; nil until it is started.
        var handlers: Handlers?
        /// How many times the event stream was started.
        var starts = 0
        /// How many times `stop()` was called.
        var stops = 0
        /// How many times `nudge()` was called.
        var nudges = 0
    }

    /// Where the client notes every call it gets.
    private let log: EventLog
    /// The states the client reports.
    private let hub = StateHub()
    /// The state starting the event stream makes current.
    private let startsAs: ConnectionState
    /// The client's counters.
    private let shared = Mutex(Shared())

    /// A client that notes its calls in `log` and says `startsAs` when its event stream starts.
    init(log: EventLog, startsAs: ConnectionState = .connecting) {
        self.log = log
        self.startsAs = startsAs
    }

    /// Accepts every order.
    func submit(_ d: OrderDraft) async throws -> SubmitResult {
        SubmitResult(
            orderId: "O-" + d.clientOrderId, accepted: true, rejectReason: nil, serverRecvNs: 1, serverAckNs: 2,
            clientRoundTripNs: 3
        )
    }

    /// Cancels nothing.
    func cancel(orderId: String) async throws -> Bool {
        false
    }

    /// Keeps the closures for the test, notes the call and makes `startsAs` the current state.
    func startEventStream(
        resumeFrom: @escaping @Sendable () -> (seq: UInt64, epoch: String?),
        onEvent: @escaping @Sendable (Tp_OrderEvent) async -> Void,
        onOutOfRange: @escaping @Sendable () async -> Void
    ) {
        log.add("trading.startEventStream")
        shared.withLock { shared in
            shared.starts += 1
            shared.handlers = Handlers(resumeFrom: resumeFrom, onEvent: onEvent, onOutOfRange: onOutOfRange)
        }
        hub.push(startsAs)
    }

    /// A new stream of the client's states on every access, as the real client gives.
    var connection: AsyncStream<ConnectionState> {
        log.add("trading.connection")
        return hub.makeStream()
    }

    /// Notes and counts the call.
    func nudge() {
        log.add("trading.nudge")
        shared.withLock { $0.nudges += 1 }
    }

    /// Notes the stop, says `.stopped` and ends every stream.
    func stop() async {
        log.add("trading.stop")
        shared.withLock { $0.stops += 1 }
        hub.stop()
    }

    /// Sends `state` to everyone watching the connection.
    func push(_ state: ConnectionState) {
        hub.push(state)
    }

    /// The closures of the event stream; nil until it was started.
    var handlers: Handlers? { shared.withLock { $0.handlers } }
    /// How many times the event stream was started.
    var starts: Int { shared.withLock { $0.starts } }
    /// How many times `stop()` was called.
    var stops: Int { shared.withLock { $0.stops } }
    /// How many times `nudge()` was called.
    var nudges: Int { shared.withLock { $0.nudges } }
    /// How the streams that are over ended.
    var terminations: [StateHub.Termination] { hub.terminations }
}

/// A REST API whose symbol list and candle history answer from scripts and whose other calls all fail as a server that
/// is not there: with `URLError.cannotConnectToHost`. A scripted `.hold` keeps the call until the test releases it.
final class FakeRest: RestAPI {
    /// What one call to `symbols()` does.
    enum Answer: Sendable {
        /// Returns this list.
        case list([SymbolDTO])
        /// Throws this error.
        case failure(any Error)
        /// Does not return until the test calls `release(_:)`.
        case hold
    }

    /// What one call to `candles(ticker:interval:limit:)` does.
    enum CandleAnswer: Sendable {
        /// Returns these candles.
        case candles([Candle])
        /// Throws this error.
        case failure(any Error)
        /// Does not return until the test calls `releaseCandles(call:_:)`.
        case hold
    }

    /// The arguments of one call to `candles(ticker:interval:limit:)`.
    struct CandleCall: Equatable, Sendable {
        /// The ticker asked for.
        let ticker: String
        /// The interval asked for.
        let interval: CandleInterval
        /// How many candles were asked for.
        let limit: Int
    }

    /// What the fake keeps between calls, under one lock.
    private struct Shared {
        /// The answers still to give, oldest first.
        var script: [Answer]
        /// The answer once the script is used up.
        var fallback: Answer
        /// How many times `symbols()` was called.
        var symbolCalls = 0
        /// How many times `account()` was called.
        var accountCalls = 0
        /// The calls of `symbols()` that wait for a release, oldest first.
        var held: [CheckedContinuation<[SymbolDTO], any Error>] = []
        /// The candle answers still to give, oldest first.
        var candleScript: [CandleAnswer]
        /// The candle answer once the candle script is used up.
        var candleFallback: CandleAnswer
        /// Every call of `candles(ticker:interval:limit:)`, in the order it arrived.
        var candleCalls: [CandleCall] = []
        /// The candle calls that wait for a release, by the number of the call (0 is the first call).
        var heldCandles: [Int: CheckedContinuation<[Candle], any Error>] = [:]
    }

    /// The fake's script and counters.
    private let shared: Mutex<Shared>

    /// A fake that gives the answers of `script`, one per call, and `fallback` once the script is used up. The history
    /// calls are answered the same way from `candles` and `candlesFallback`; unless a test says otherwise they fail as
    /// a server that is not there.
    init(
        _ script: [Answer] = [], fallback: Answer = .list(sampleSymbols), candles: [CandleAnswer] = [],
        candlesFallback: CandleAnswer = .failure(URLError(.cannotConnectToHost))
    ) {
        shared = Mutex(
            Shared(script: script, fallback: fallback, candleScript: candles, candleFallback: candlesFallback)
        )
    }

    /// Gives the next answer of the script.
    func symbols() async throws -> [SymbolDTO] {
        let answer = shared.withLock { shared in
            shared.symbolCalls += 1
            return shared.script.isEmpty ? shared.fallback : shared.script.removeFirst()
        }
        switch answer {
        case .list(let list): return list
        case .failure(let error): throw error
        case .hold:
            return try await withCheckedThrowingContinuation { continuation in
                shared.withLock { $0.held.append(continuation) }
            }
        }
    }

    /// Lets the oldest held call return `result`; false when no call is held.
    @discardableResult
    func release(_ result: Result<[SymbolDTO], any Error>) -> Bool {
        let held = shared.withLock { shared in
            shared.held.isEmpty ? nil : shared.held.removeFirst()
        }
        held?.resume(with: result)
        return held != nil
    }

    /// How many times `symbols()` was called.
    var symbolCalls: Int { shared.withLock { $0.symbolCalls } }
    /// How many times `account()` was called.
    var accountCalls: Int { shared.withLock { $0.accountCalls } }
    /// How many calls of `symbols()` wait for a release.
    var heldCount: Int { shared.withLock { $0.held.count } }

    /// Counts the call and fails as a server that is not there.
    func account() async throws -> AccountDTO {
        shared.withLock { $0.accountCalls += 1 }
        throw URLError(.cannotConnectToHost)
    }

    /// Notes the call and gives the next answer of the candle script. A held call does not return until the test
    /// releases it by its number; the call is noted first, so a test can wait for it to be held.
    func candles(ticker: String, interval: CandleInterval, limit: Int) async throws -> [Candle] {
        let (number, answer) = shared.withLock { shared in
            shared.candleCalls.append(CandleCall(ticker: ticker, interval: interval, limit: limit))
            let answer = shared.candleScript.isEmpty ? shared.candleFallback : shared.candleScript.removeFirst()
            return (shared.candleCalls.count - 1, answer)
        }
        switch answer {
        case .candles(let candles): return candles
        case .failure(let error): throw error
        case .hold:
            return try await withCheckedThrowingContinuation { continuation in
                shared.withLock { $0.heldCandles[number] = continuation }
            }
        }
    }

    /// Lets the held candle call number `call` (0 is the first call) return `result`; false when that call is not held.
    @discardableResult
    func releaseCandles(call: Int, _ result: Result<[Candle], any Error>) -> Bool {
        let held = shared.withLock { $0.heldCandles.removeValue(forKey: call) }
        held?.resume(with: result)
        return held != nil
    }

    /// Every call of `candles(ticker:interval:limit:)` so far, in the order it arrived.
    var candleCalls: [CandleCall] { shared.withLock { $0.candleCalls } }
    /// How many candle calls wait for a release.
    var heldCandleCount: Int { shared.withLock { $0.heldCandles.count } }

    /// Fails as a server that is not there.
    func transactions(cursor: String?, limit: Int) async throws -> TransactionPageDTO {
        throw URLError(.cannotConnectToHost)
    }

    /// Fails as a server that is not there.
    func serverTimeNs() async throws -> Int64 {
        throw URLError(.cannotConnectToHost)
    }

    /// Fails as a server that is not there.
    func lab() async throws -> LabSettings {
        throw URLError(.cannotConnectToHost)
    }

    /// Fails as a server that is not there.
    func setLab(_ patch: LabPatch) async throws -> LabSettings {
        throw URLError(.cannotConnectToHost)
    }

    /// Fails as a server that is not there.
    func dropConnections() async throws {
        throw URLError(.cannotConnectToHost)
    }

    /// Fails as a server that is not there.
    func resetServer() async throws -> String {
        throw URLError(.cannotConnectToHost)
    }
}

/// The `sleep` the environment waits with: it records every duration it was asked for and then, as the test chose,
/// returns at once, waits until the test calls `release()` (and throws `CancellationError` when its task is
/// cancelled first), or throws an error of the test's making.
final class FakeSleeper: Sendable {
    /// What every sleep does.
    enum Behavior: Sendable {
        /// Returns at once, as if the time had passed.
        case returnAtOnce
        /// Waits until `release()` and throws `CancellationError` when cancelled first.
        case holdUntilReleased
        /// Throws this error.
        case throwError(any Error)
    }

    /// What the sleeper keeps between calls, under one lock.
    private struct Shared {
        /// The durations asked for, in order.
        var durations: [Duration] = []
        /// The gates of the sleeps that wait for a release, oldest first.
        var gates: [AsyncStream<Void>.Continuation] = []
    }

    /// What every sleep does.
    private let behavior: Behavior
    /// The sleeper's record and gates.
    private let shared = Mutex(Shared())

    /// A sleeper whose sleeps all behave as `behavior`.
    init(_ behavior: Behavior = .returnAtOnce) {
        self.behavior = behavior
    }

    /// Records `duration` and then behaves as chosen.
    func sleep(_ duration: Duration) async throws {
        shared.withLock { $0.durations.append(duration) }
        switch behavior {
        case .returnAtOnce:
            return
        case .throwError(let error):
            throw error
        case .holdUntilReleased:
            let (gate, opener) = AsyncStream<Void>.makeStream()
            shared.withLock { $0.gates.append(opener) }
            var iterator = gate.makeAsyncIterator()
            // An `AsyncStream` iterator returns nil when the waiting task is cancelled.
            guard await iterator.next() != nil else { throw CancellationError() }
        }
    }

    /// Lets the oldest held sleep return.
    func release() {
        let opener = shared.withLock { shared in
            shared.gates.isEmpty ? nil : shared.gates.removeFirst()
        }
        opener?.yield()
    }

    /// Every duration asked for so far, in order.
    var durations: [Duration] { shared.withLock { $0.durations } }

    /// How many sleeps were asked for.
    var requested: Int { durations.count }
}

/// A failure of the test's own, for a double that has to throw something that is not a `CancellationError`.
struct TestFailure: Error {}

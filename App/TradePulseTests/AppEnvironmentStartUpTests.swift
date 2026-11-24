import Foundation
import Testing
import TradeNetworking
@testable import TradePulse

/// A start-up that is under way when the caller is cancelled or the environment is shut down: it is never left half
/// done, because a market client that runs with no trading, or a client nobody stops, could not be put right later.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppEnvironmentStartUpTests {
    /// Lets the main actor take a good many turns, for a check that something has NOT happened. A positive control
    /// always follows it: the thing is then allowed to happen, and a test fails if it does not.
    private func letTheMainActorRun() async {
        for _ in 0..<1_000 {
            await Task.yield()
        }
    }

    @Test func aCancellationDuringTheStartUpDoesNotCutItShort() async {
        let rig = EnvRig(holdsSubscribe: true)
        let (task, finished) = rig.bootstrapInTask()
        await waitFor("the tickers are being stored") { rig.market.hasEnteredSubscribe }
        task.cancel()
        await letTheMainActorRun()
        // The call is still waiting for its start-up, and the client is not started yet.
        #expect(!finished.isSet)
        #expect(rig.market.starts == 0)

        rig.market.releaseSubscribe()
        await waitFor("the call returns") { finished.isSet }
        // Both clients were started even though the caller was cancelled on the way.
        #expect(rig.market.starts == 1)
        #expect(rig.tradingClient.starts == 1)

        // The observers were made as well: the connection properties follow the clients.
        rig.market.push(.connected)
        rig.tradingClient.push(.connected)
        await waitFor("both connections are up") {
            rig.env.marketConnection == .connected && rig.env.tradingConnection == .connected
        }
    }

    @Test func shutdownWaitsForAStartUpThatIsUnderWay() async {
        let rig = EnvRig(holdsSubscribe: true)
        let (_, bootstrapped) = rig.bootstrapInTask()
        await waitFor("the tickers are being stored") { rig.market.hasEnteredSubscribe }

        let env = rig.env
        let shutDown = Flag()
        let shutdown = Task { @MainActor in
            await env.shutdown()
            shutDown.set()
        }
        await letTheMainActorRun()
        #expect(!shutDown.isSet)
        #expect(rig.market.stops == 0)

        rig.market.releaseSubscribe()
        await waitFor("the shutdown returns") { shutDown.isSet }
        #expect(bootstrapped.isSet)
        // The client was started and then stopped, in that order, and nothing is left running.
        let market = rig.log.entries.filter { $0.hasPrefix("market.") }
        #expect(market == ["market.connection", "market.subscribe", "market.start", "market.stop"])
        #expect(rig.tradingClient.starts == 1)
        #expect(rig.tradingClient.stops == 1)
        shutdown.cancel()
    }

    @Test func shutdownWhileTheListIsStillLoadingStartsNothing() async {
        let rig = EnvRig(
            rest: FakeRest([.failure(URLError(.cannotConnectToHost))]), sleeper: FakeSleeper(.holdUntilReleased)
        )
        let (_, finished) = rig.bootstrapInTask()
        await waitFor("the wait begins") { rig.sleeper.requested == 1 }

        await rig.env.shutdown()
        #expect(rig.tradingClient.stops == 1)

        // The wait ends, and the loop leaves without asking the server again or starting anything.
        rig.sleeper.release()
        await waitFor("the call returns") { finished.isSet }
        #expect(rig.rest.symbolCalls == 1)
        #expect(rig.builds.market.isEmpty)
        #expect(rig.market.starts == 0)
        #expect(rig.tradingClient.starts == 0)
    }

    @Test func aListThatArrivesAfterShutdownStartsNothing() async {
        let rig = EnvRig(rest: FakeRest([.hold]))
        let (_, finished) = rig.bootstrapInTask()
        await waitFor("the request is out") { rig.rest.heldCount == 1 }

        await rig.env.shutdown()
        let released = rig.rest.release(.success(sampleSymbols))
        #expect(released)
        await waitFor("the call returns") { finished.isSet }
        #expect(rig.builds.market.isEmpty)
        #expect(rig.market.starts == 0)
        #expect(rig.tradingClient.starts == 0)
        #expect(rig.env.symbols.isEmpty)
    }
}

import Foundation
import Observation
import Testing
import TradeNetworking
@testable import TradePulse

/// The two connection states the environment publishes for the banner: they follow what the clients report, exactly,
/// and each one follows its own client.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppEnvironmentConnectionTests {
    /// A run of states in which every one differs from the one before it, `.stopped` included.
    private static let journey: [ConnectionState] = [
        .connected, .reconnecting(attempt: 1), .reconnecting(attempt: 2), .connected, .stopped, .connecting,
    ]

    @Test func theMarketConnectionMirrorsTheClientsStream() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        for state in Self.journey {
            rig.market.push(state)
            await waitFor("the market connection reads \(state)") { rig.env.marketConnection == state }
        }
    }

    @Test func theTradingConnectionMirrorsTheClientsStream() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        for state in Self.journey {
            rig.tradingClient.push(state)
            await waitFor("the trading connection reads \(state)") { rig.env.tradingConnection == state }
        }
    }

    @Test func eachConnectionFollowsItsOwnClient() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        rig.market.push(.connected)
        await waitFor("the market connection is up") { rig.env.marketConnection == .connected }
        #expect(rig.env.tradingConnection == .connecting)

        rig.tradingClient.push(.reconnecting(attempt: 3))
        await waitFor("the trading connection is retrying") {
            rig.env.tradingConnection == .reconnecting(attempt: 3)
        }
        #expect(rig.env.marketConnection == .connected)
    }

    @Test func aTradingClientThatIsAlreadyUpIsShownAsUpAtOnce() async {
        let rig = EnvRig(tradingStartsAs: .connected)
        await rig.env.bootstrap()
        // The observer is made after the start, and a new stream says the current state first.
        await waitFor("the trading connection is up") { rig.env.tradingConnection == .connected }
    }

    @Test func theMarketConnectionIsShownAsConnectingOnceTheClientHasStarted() async {
        let rig = EnvRig(
            rest: FakeRest([.failure(URLError(.cannotConnectToHost))]), sleeper: FakeSleeper(.holdUntilReleased)
        )
        let (task, finished) = rig.bootstrapInTask()
        await waitFor("the first wait begins") { rig.sleeper.requested == 1 }
        #expect(rig.env.marketConnection == .reconnecting(attempt: 1))

        rig.sleeper.release()
        await waitFor("the call returns") { finished.isSet }
        // The client's own first state replaces the retry count of the list.
        await waitFor("the market connection reads connecting") { rig.env.marketConnection == .connecting }
        task.cancel()
    }

    @Test func aChangeOfAConnectionCanBeObserved() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        let marketChanged = Flag()
        let tradingChanged = Flag()
        withObservationTracking {
            _ = rig.env.marketConnection
        } onChange: {
            marketChanged.set()
        }
        withObservationTracking {
            _ = rig.env.tradingConnection
        } onChange: {
            tradingChanged.set()
        }
        rig.market.push(.connected)
        await waitFor("the market change is seen") { marketChanged.isSet }
        #expect(!tradingChanged.isSet)

        rig.tradingClient.push(.connected)
        await waitFor("the trading change is seen") { tradingChanged.isSet }
    }

    @Test func theListOfSymbolsCanBeObserved() async {
        let rig = EnvRig()
        let changed = Flag()
        withObservationTracking {
            _ = rig.env.symbols
        } onChange: {
            changed.set()
        }
        #expect(!changed.isSet)
        await rig.env.bootstrap()
        #expect(changed.isSet)
    }
}

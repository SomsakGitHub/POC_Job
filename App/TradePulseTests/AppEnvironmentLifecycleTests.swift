import Foundation
import Testing
import TradeNetworking
@testable import TradePulse

/// What the environment does when the app comes to the foreground and leaves it, and when it is shut down. The pump
/// really starts a display link in these tests, so every test that starts it stops it again before it ends.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppEnvironmentLifecycleTests {
    // MARK: Foreground and background

    @Test func becomingActiveRightAfterLaunchStartsOnlyThePump() {
        let rig = EnvRig()
        defer { rig.env.pump.stop() }
        rig.env.appDidBecomeActive()
        #expect(rig.env.pump.isRunning)
        // No client exists yet and none was called.
        #expect(rig.log.entries.isEmpty)
        #expect(rig.market.nudges == 0)
        #expect(rig.tradingClient.nudges == 0)
    }

    @Test func aBlipThatNeverReachedTheBackgroundNudgesNothing() async {
        let rig = EnvRig()
        defer { rig.env.pump.stop() }
        rig.env.appDidBecomeActive()
        await rig.env.bootstrap()
        // Control Center or the notification shade: inactive and active again, never in the background.
        rig.env.appDidBecomeActive()
        rig.env.appDidBecomeActive()
        #expect(rig.market.nudges == 0)
        #expect(rig.tradingClient.nudges == 0)
        #expect(rig.env.pump.isRunning)
    }

    @Test func returningFromTheBackgroundNudgesBothClientsOnce() async {
        let rig = EnvRig()
        defer { rig.env.pump.stop() }
        rig.env.appDidBecomeActive()
        await rig.env.bootstrap()

        rig.env.appDidEnterBackground()
        #expect(!rig.env.pump.isRunning)
        // Leaving the foreground touches no connection.
        #expect(rig.market.nudges == 0)
        #expect(rig.tradingClient.nudges == 0)

        rig.env.appDidBecomeActive()
        #expect(rig.env.pump.isRunning)
        #expect(rig.market.nudges == 1)
        #expect(rig.tradingClient.nudges == 1)

        // Active again without a visit to the background in between: nothing more.
        rig.env.appDidBecomeActive()
        #expect(rig.market.nudges == 1)
        #expect(rig.tradingClient.nudges == 1)
    }

    @Test func everyVisitToTheBackgroundIsFollowedByOneNudge() async {
        let rig = EnvRig()
        defer { rig.env.pump.stop() }
        await rig.env.bootstrap()
        for visit in 1...3 {
            rig.env.appDidEnterBackground()
            rig.env.appDidBecomeActive()
            #expect(rig.market.nudges == visit)
            #expect(rig.tradingClient.nudges == visit)
        }
    }

    @Test func leavingTheForegroundTouchesNoConnection() async {
        let rig = EnvRig()
        defer { rig.env.pump.stop() }
        rig.env.appDidBecomeActive()
        await rig.env.bootstrap()
        let before = rig.log.entries
        rig.env.appDidEnterBackground()
        #expect(rig.log.entries == before)
        #expect(rig.market.stops == 0)
        #expect(rig.tradingClient.stops == 0)
        #expect(!rig.env.pump.isRunning)
    }

    @Test func aVisitToTheBackgroundBeforeTheClientsExistNudgesNothingLater() async {
        let rig = EnvRig()
        defer { rig.env.pump.stop() }
        rig.env.appDidBecomeActive()
        rig.env.appDidEnterBackground()
        rig.env.appDidBecomeActive()
        // There was nothing to nudge, and the visit is not remembered for the clients that come later.
        #expect(rig.log.entries.isEmpty)

        await rig.env.bootstrap()
        rig.env.appDidBecomeActive()
        #expect(rig.market.nudges == 0)
        #expect(rig.tradingClient.nudges == 0)
    }

    // MARK: Shutting down

    @Test func shutdownStopsWhatWasStartedAndTheMarketFirst() async {
        let rig = EnvRig()
        rig.env.appDidBecomeActive()
        await rig.env.bootstrap()
        #expect(rig.env.pump.isRunning)

        await rig.env.shutdown()
        #expect(rig.market.stops == 1)
        #expect(rig.tradingClient.stops == 1)
        #expect(!rig.env.pump.isRunning)
        let stops = rig.log.entries.filter { $0.hasSuffix(".stop") }
        #expect(stops == ["market.stop", "trading.stop"])
    }

    @Test func shutdownEndsTheObserversBeforeItStopsTheClients() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        // Both observers have taken a state from their stream, so each is waiting for the next.
        rig.market.push(.connected)
        rig.tradingClient.push(.connected)
        await waitFor("both connections are up") {
            rig.env.marketConnection == .connected && rig.env.tradingConnection == .connected
        }

        await rig.env.shutdown()
        // The environment's streams were cancelled; a stream that the client ended would read `.finished`. The
        // store's own stream of the trading client is the one that ends with the client.
        #expect(rig.market.terminations == [.cancelled])
        #expect(rig.tradingClient.terminations == [.cancelled, .finished])
    }

    @Test func shutdownTwiceStopsOnce() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        await rig.env.shutdown()
        await rig.env.shutdown()
        #expect(rig.market.stops == 1)
        #expect(rig.tradingClient.stops == 1)
    }

    @Test func afterShutdownNothingStartsAgain() async {
        let rig = EnvRig()
        defer { rig.env.pump.stop() }
        await rig.env.bootstrap()
        await rig.env.shutdown()

        await rig.env.bootstrap()
        #expect(rig.rest.symbolCalls == 1)
        #expect(rig.builds.market.count == 1)
        #expect(rig.market.starts == 1)
        #expect(rig.tradingClient.starts == 1)

        rig.env.appDidBecomeActive()
        #expect(!rig.env.pump.isRunning)
        rig.env.appDidEnterBackground()
        rig.env.appDidBecomeActive()
        #expect(rig.market.nudges == 0)
        #expect(rig.tradingClient.nudges == 0)
    }

    @Test func shutdownBeforeTheBootstrapStopsOnlyWhatExists() async {
        let rig = EnvRig()
        await rig.env.shutdown()
        #expect(rig.market.stops == 0)
        #expect(rig.market.starts == 0)
        #expect(rig.tradingClient.stops == 1)

        await rig.env.bootstrap()
        #expect(rig.rest.symbolCalls == 0)
        #expect(rig.market.starts == 0)
        #expect(rig.tradingClient.starts == 0)
    }
}

import Foundation
import SwiftUI
import Testing
@testable import TradePulse

/// How the app starts, and how a change of the scene's phase reaches the environment. The test bundle is hosted by
/// the app itself, so the app has to know that it is only there to be tested and must not open a connection.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppLaunchTests {
    @Test func theHostKnowsItIsRunningUnitTests() {
        #expect(TradePulseApp.isRunningUnitTests)
    }

    @Test func theVariableItReadsIsSetByTheTestRunner() {
        // The system fact the check above rests on, so that a runner that stops setting it is named by a failure.
        let path = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]
        #expect(path != nil)
    }

    // MARK: Scene phases

    @Test func theActivePhaseStartsThePump() {
        let rig = EnvRig()
        defer { rig.env.pump.stop() }
        rig.env.scenePhaseChanged(to: .active)
        #expect(rig.env.pump.isRunning)
    }

    @Test func theBackgroundPhaseStopsThePumpAndTheNextActiveOneNudgesTheClients() async {
        let rig = EnvRig()
        defer { rig.env.pump.stop() }
        await rig.env.bootstrap()
        rig.env.scenePhaseChanged(to: .active)
        #expect(rig.env.pump.isRunning)

        rig.env.scenePhaseChanged(to: .background)
        #expect(!rig.env.pump.isRunning)
        #expect(rig.market.nudges == 0)

        rig.env.scenePhaseChanged(to: .active)
        #expect(rig.env.pump.isRunning)
        #expect(rig.market.nudges == 1)
        #expect(rig.tradingClient.nudges == 1)
    }

    @Test func theInactivePhaseDoesNothing() async {
        let rig = EnvRig()
        defer { rig.env.pump.stop() }
        await rig.env.bootstrap()
        let before = rig.log.entries

        rig.env.scenePhaseChanged(to: .inactive)
        #expect(!rig.env.pump.isRunning)
        #expect(rig.log.entries == before)

        // Nor does it end what the active phase started, or leave a visit to the background behind.
        rig.env.scenePhaseChanged(to: .active)
        rig.env.scenePhaseChanged(to: .inactive)
        rig.env.scenePhaseChanged(to: .active)
        #expect(rig.env.pump.isRunning)
        #expect(rig.market.nudges == 0)
        #expect(rig.tradingClient.nudges == 0)
    }
}

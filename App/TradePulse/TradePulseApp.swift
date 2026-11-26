import SwiftUI

/// The app: one window with the tabs, over one `AppEnvironment` that starts when the window appears.
@main
struct TradePulseApp: App {
    /// Whether this process is the host of a unit-test run. The test bundle is loaded into this very app, and an app
    /// that started its connections then would open sockets during the tests, and talk to a real server if one is up.
    static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Everything the screens share. Building it starts nothing.
    @State private var environment = AppEnvironment()
    /// Whether the window is in use, inactive or away.
    @Environment(\.scenePhase) private var scenePhase

    /// The one window. A unit-test run shows a line of text instead of the app, so that the host stays quiet.
    var body: some Scene {
        WindowGroup {
            if Self.isRunningUnitTests {
                Text("Running unit tests")
            } else {
                RootTabView()
                    .environment(environment)
                    .task { await environment.bootstrap() }
                    .task { await printLatencyLinesIfAsked() }
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        environment.scenePhaseChanged(to: phase)
                    }
            }
        }
    }

    /// Prints the latency line every five seconds for as long as the app runs, when it was launched with
    /// `--print-latency`, and does nothing otherwise. The measurement script reads the lines from standard output.
    private func printLatencyLinesIfAsked() async {
        guard LatencyPrinter.shouldStart(
            arguments: ProcessInfo.processInfo.arguments, isRunningUnitTests: Self.isRunningUnitTests
        ) else { return }
        await LatencyPrinter(latency: environment.latency, pump: environment.pump).run()
    }
}

/// How the phases of the window reach the environment.
extension AppEnvironment {
    /// Passes a change of the window's phase on: the app became active, or it went to the background. Inactive, the
    /// phase of a short interruption, changes nothing.
    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active: appDidBecomeActive()
        case .background: appDidEnterBackground()
        case .inactive: break
        @unknown default: break
        }
    }
}

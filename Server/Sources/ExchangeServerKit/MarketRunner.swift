import Contracts
import ExchangeCore
import ServiceLifecycle

/// The service that keeps the simulated market moving in real time.
///
/// The engine's market is a pure function of the times it is told, so something has to tell it the time: this runner
/// does, over and over, and hands every batch of changed quotes to `publish`. It is a service of the same group as the
/// HTTP and gRPC servers, so it starts and stops with them.
///
/// Each iteration reads the lab settings, advances the engine to the clock's present (`nowNs`, in whole milliseconds)
/// at 20 updates per symbol per second times the lab's rate multiplier, or at 500 in stress mode, publishes the quotes
/// that changed (nothing, when none did) and sleeps 10 ms, or 2 ms in stress mode. An iteration, once begun, runs to
/// its end: only the sleep can be interrupted, so the engine and `publish` never see a half-done step.
struct MarketRunner: Service {
    /// Updates per symbol per second in normal mode, before the lab's multiplier.
    static let normalRate = 20.0
    /// Updates per symbol per second in stress mode, whatever the multiplier.
    static let stressRate = 500.0
    /// How long the runner waits after an iteration in normal mode.
    static let normalPause = Duration.milliseconds(10)
    /// How long the runner waits after an iteration in stress mode.
    static let stressPause = Duration.milliseconds(2)

    private let engine: ExchangeEngine
    private let lab: LabControls
    private let nowNs: @Sendable () -> Int64
    private let publish: @Sendable ([SymbolQuote]) async -> Void
    private let pause: @Sendable (Duration) async throws -> Void

    /// A runner over `engine`, reading the time from `nowNs` (nanoseconds since the Unix epoch) and the rate from
    /// `lab`. `publish` receives each non-empty batch of changed quotes; by default it drops them. `pause` waits out
    /// the time between two iterations and throws when the task is cancelled; it sleeps, unless a test wants to see
    /// the waits without living through them.
    init(
        engine: ExchangeEngine, lab: LabControls, nowNs: @escaping @Sendable () -> Int64,
        publish: @escaping @Sendable ([SymbolQuote]) async -> Void = { _ in },
        pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.engine = engine
        self.lab = lab
        self.nowNs = nowNs
        self.publish = publish
        self.pause = pause
    }

    /// Runs until the task is cancelled or a graceful shutdown begins. A service group waits for a service for as long
    /// as it takes, so a loop that did not end on a graceful shutdown would keep the whole server from stopping.
    func run() async throws {
        await cancelWhenGracefulShutdown { await iterate() }
    }

    private func iterate() async {
        while !Task.isCancelled {
            let settings = await lab.settings()
            let rate = settings.stress ? Self.stressRate : Self.normalRate * settings.rateMultiplier
            let changed = await engine.advance(toMs: nowNs() / 1_000_000, updatesPerSymbolPerSecond: rate)
            if !changed.isEmpty {
                await publish(changed)
            }
            do {
                try await pause(settings.stress ? Self.stressPause : Self.normalPause)
            } catch {
                return  // cancelled
            }
        }
    }
}

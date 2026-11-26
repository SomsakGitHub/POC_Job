import Contracts
import Foundation
import QuartzCore
import Synchronization
import TradeCore
import TradeNetworking
@testable import TradePulse

/// The `sleep` of a loop that waits between rounds: it records every wait it was asked for and returns at once, until
/// the call number `endsOnCall` (the first call is number 1), which throws `CancellationError` as a wait does when its
/// task is cancelled. `onCall` runs with the number of each call before the call returns or throws, so a test can look
/// at what happened before the wait, or cancel the task during it.
final class CountingSleeper: Sendable {
    /// What the sleeper keeps between calls, under one lock.
    private struct Shared {
        /// The durations asked for, in order.
        var durations: [Duration] = []
    }

    /// The call number that throws.
    private let endsOnCall: Int
    /// What runs on every call, with the number of the call.
    private let onCall: @Sendable (Int) -> Void
    /// The sleeper's record.
    private let shared = Mutex(Shared())

    /// A sleeper that returns at once for the calls before number `endsOnCall` and throws on that one and the ones
    /// after it.
    init(endsOnCall: Int, onCall: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.endsOnCall = endsOnCall
        self.onCall = onCall
    }

    /// Records `duration`, runs the hook and then returns or throws.
    func sleep(_ duration: Duration) async throws {
        let number = shared.withLock { shared in
            shared.durations.append(duration)
            return shared.durations.count
        }
        onCall(number)
        if number >= endsOnCall { throw CancellationError() }
    }

    /// Every duration asked for so far, in order.
    var durations: [Duration] { shared.withLock { $0.durations } }
}

/// A clock in nanoseconds that gives the values it was given one by one, and the last one for ever after: a probe that
/// reads the clock twice sees a start and an end that the test chose.
final class SteppingClock: Sendable {
    /// The values still to give, and the one given last.
    private struct Shared {
        /// What is still to give, oldest first.
        var upcoming: [UInt64]
        /// What was given last.
        var last: UInt64
        /// How many times the clock was read.
        var reads = 0
    }

    /// The clock's state.
    private let shared: Mutex<Shared>

    /// A clock that reads `values` in order.
    init(_ values: [UInt64]) {
        shared = Mutex(Shared(upcoming: values, last: values.last ?? 0))
    }

    /// The next value, or the last one once they are used up.
    func read() -> UInt64 {
        shared.withLock { shared in
            shared.reads += 1
            guard !shared.upcoming.isEmpty else { return shared.last }
            shared.last = shared.upcoming.removeFirst()
            return shared.last
        }
    }

    /// How many times the clock was read.
    var reads: Int { shared.withLock { $0.reads } }
}

/// The Lab's model over fakes: a REST API a test scripts, a trading store over a fake client, a pump whose clocks the
/// test moves, and a monotonic clock the model reads. Nothing here opens a socket or waits for time to pass.
@MainActor
struct LabRig {
    /// The REST API the model and the trading store call.
    let rest: FakeRest
    /// The pump and the market state it watches, with the recorder the market state records into.
    let pumpRig: PumpRig
    /// The trading store the account check compares with the server.
    let trading: TradingRig
    /// The monotonic clock the model reads, in nanoseconds; it starts at one second.
    let clock = ManualClock(1_000_000_000)
    /// The model under test.
    let model: LabViewModel

    /// A model over `rest`. `sleep` is how its loop waits; by default a wait ends the loop, so that a test that runs
    /// the loop by mistake does not run for ever. `monotonicNs` replaces the rig's clock when a test needs to say what
    /// the clock reads on each look, and `makeLink` is what the pump makes its display link with when a test starts it.
    init(
        rest: FakeRest = FakeRest(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in throw CancellationError() },
        monotonicNs: (@Sendable () -> UInt64)? = nil,
        makeLink: @escaping FramePump.LinkFactory = { CADisplayLink(target: $0, selector: $1) }
    ) {
        let clock = clock
        let pumpRig = PumpRig(makeLink: makeLink)
        let trading = TradingRig(rest: rest)
        self.rest = rest
        self.pumpRig = pumpRig
        self.trading = trading
        model = LabViewModel(
            rest: rest, latency: pumpRig.latency, pump: pumpRig.pump, trading: trading.store, sleep: sleep,
            monotonicNs: monotonicNs ?? { UInt64(clamping: clock.read()) }
        )
    }

    /// The recorder the model resets and the market state records into.
    var latency: LatencyRecorder { pumpRig.latency }
    /// The pump whose counters the model samples and resets.
    var pump: FramePump { pumpRig.pump }

    /// Starts the trading store, which reads the account once: from then on the store has an epoch.
    func startTrading() async {
        await trading.start()
    }
}

/// An account of the server in epoch `epoch` with `cash` satang and no positions, as the account check reads it.
func labAccount(cash: Int64 = 100_000_000, epoch: String = "E1") -> FakeRest.AccountAnswer {
    .account(accountDTO(cash: cash, epoch: epoch))
}

/// The settings the lab's server reports when the test says nothing else: not the defaults, so that a model that did
/// not take them over is caught.
let busyLab = LabSettings(rateMultiplier: 4.5, stress: true, extraLatencyMs: 50, jitterMs: 20, dropUpdates: true)

import Contracts
import ExchangeCore
import ServiceLifecycleTestKit
import Synchronization
import Testing
@testable import ExchangeServerKit

/// A clock for the runner that a test controls: every reading is `stepNs` later than the one before and is counted
/// and timed, so a test knows how many iterations ran and how far apart they started.
final class SteppedClock: Sendable {
    private struct State {
        var next: Int64
        var times: [ContinuousClock.Instant] = []
    }

    private let state: Mutex<State>
    private let stepNs: Int64

    /// The first reading is one step after `startNs`.
    init(startNs: Int64, stepNs: Int64) {
        state = Mutex(State(next: startNs + stepNs))
        self.stepNs = stepNs
    }

    func now() -> Int64 {
        state.withLock { state in
            state.times.append(.now)
            defer { state.next += stepNs }
            return state.next
        }
    }

    var readings: Int {
        state.withLock { $0.times.count }
    }

    var readingTimes: [ContinuousClock.Instant] {
        state.withLock { $0.times }
    }
}

/// The batches a runner handed to `publish`, in order.
final class PublishedBatches: Sendable {
    private let batches = Mutex<[[SymbolQuote]]>([])

    func append(_ batch: [SymbolQuote]) {
        batches.withLock { $0.append(batch) }
    }

    var all: [[SymbolQuote]] {
        batches.withLock { $0 }
    }
}

/// The waits a runner asked for, in order. Each one is over at once, after other tasks have had a turn, so a runner
/// that uses it goes round as fast as the clock lets it.
final class RecordedPauses: Sendable {
    private let asked = Mutex<[Duration]>([])

    func wait(_ duration: Duration) async {
        asked.withLock { $0.append(duration) }
        await Task.yield()
    }

    var all: [Duration] {
        asked.withLock { $0 }
    }
}

/// The first number offered to it, kept.
final class FirstValue: Sendable {
    private let stored = Mutex<Int?>(nil)

    /// Keeps `number` unless one was kept before; says whether this call kept it.
    func offer(_ number: Int) -> Bool {
        stored.withLock { stored in
            guard stored == nil else { return false }
            stored = number
            return true
        }
    }

    var value: Int? {
        stored.withLock { $0 }
    }
}

/// One run of a runner over a market that starts at `startNs` and whose clock moves 2 ms at every reading. The
/// runner's waits are recorded and over at once, so how long a run takes does not depend on how busy the machine is.
private struct RunnerRun {
    static let startNs: Int64 = 1_732_000_000_000_000_000
    static let stepNs: Int64 = 2_000_000

    let clock = SteppedClock(startNs: RunnerRun.startNs, stepNs: RunnerRun.stepNs)
    let published = PublishedBatches()
    let pauses = RecordedPauses()
    let lab: LabControls

    init(lab: LabControls = LabControls()) {
        self.lab = lab
    }

    /// An engine over the catalog (seed 42) that sits still until it is told the time, as the runner's engine does.
    static func makeEngine() -> ExchangeEngine {
        ExchangeEngine(symbols: SymbolCatalog.defaultSymbols, seed: 42, nowNs: { startNs })
    }

    /// Runs a runner until its clock has been read `readings` times, stops it and waits for it to end. The runner
    /// finishes every iteration it began, so the clock's final reading count is the number of iterations.
    func run(
        readings: Int, afterPublish: @escaping @Sendable ([SymbolQuote]) async -> Void = { _ in }
    ) async throws -> Int {
        let clock = clock
        let published = published
        let pauses = pauses
        let runner = MarketRunner(
            engine: Self.makeEngine(), lab: lab, nowNs: { clock.now() },
            publish: { batch in
                published.append(batch)
                await afterPublish(batch)
            },
            pause: { await pauses.wait($0) }
        )
        let task = Task { try await runner.run() }
        let reached = await eventually { clock.readings >= readings }
        task.cancel()
        let ended = await finishes(within: patience) { _ = await task.result }
        try #require(reached, "the runner read its clock only \(clock.readings) times")
        try #require(ended, "the runner did not end when its task was cancelled")
        return clock.readings
    }

    /// What the engine answers when it is advanced to the same times at `rate(reading)`: the batches that are not
    /// empty, in order. This is what a runner has to publish.
    static func expectedBatches(readings: Int, rate: (Int) -> Double) async -> [[SymbolQuote]] {
        let engine = makeEngine()
        var batches: [[SymbolQuote]] = []
        for reading in 1...readings {
            let toMs = (startNs + Int64(reading) * stepNs) / 1_000_000
            let changed = await engine.advance(toMs: toMs, updatesPerSymbolPerSecond: rate(reading))
            if !changed.isEmpty { batches.append(changed) }
        }
        return batches
    }
}

/// The market runner: how fast it advances the market, what it publishes, how it paces itself and when it stops.
@Suite("MarketRunnerTests")
struct MarketRunnerTests {
    @Test func advancesAtTwentyUpdatesPerSymbolPerSecondAndPublishesOnlyWhatChanged() async throws {
        let run = RunnerRun()
        let readings = try await run.run(readings: 25)

        let expected = await RunnerRun.expectedBatches(readings: readings) { _ in 20 }
        #expect(run.published.all == expected)
        // The run has to include iterations that changed nothing, or "publishes only what changed" is not tested.
        #expect(!expected.isEmpty)
        #expect(expected.count < readings)
        #expect(run.published.all.allSatisfy { !$0.isEmpty })
    }

    @Test func rateMultiplierScalesTheNormalRate() async throws {
        let lab = LabControls()
        await lab.apply(LabPatch(rateMultiplier: 2.5))
        let run = RunnerRun(lab: lab)
        let readings = try await run.run(readings: 25)

        let expected = await RunnerRun.expectedBatches(readings: readings) { _ in 50 }
        #expect(run.published.all == expected)
        #expect(!expected.isEmpty)
    }

    @Test func stressModeAdvancesAtFiveHundredUpdatesPerSymbolPerSecond() async throws {
        let lab = LabControls()
        // The multiplier does not apply to stress mode: its rate is fixed.
        await lab.apply(LabPatch(rateMultiplier: 3, stress: true))
        let run = RunnerRun(lab: lab)
        let readings = try await run.run(readings: 40)

        let expected = await RunnerRun.expectedBatches(readings: readings) { _ in 500 }
        #expect(run.published.all == expected)
        #expect(!expected.isEmpty)
    }

    /// The settings are read again at every iteration: a change made while the runner runs takes effect at the next
    /// one, in the rate and in the wait alike. Here stress mode is switched on as the first batch is published.
    @Test func aLabChangeTakesEffectAtTheNextIteration() async throws {
        let lab = LabControls()
        let run = RunnerRun(lab: lab)
        let clock = run.clock
        let switchedAfter = FirstValue()
        let readings = try await run.run(readings: 30) { _ in
            if switchedAfter.offer(clock.readings) {
                await lab.apply(LabPatch(stress: true))
            }
        }

        let last = try #require(switchedAfter.value, "no batch was published, so stress mode was never switched on")
        let expected = await RunnerRun.expectedBatches(readings: readings) { $0 <= last ? 20 : 500 }
        #expect(run.published.all == expected)
        #expect(readings > last, "the run ended before the change could take effect")
        let waits = (1...readings).map { $0 <= last ? MarketRunner.normalPause : MarketRunner.stressPause }
        #expect(run.pauses.all == waits)
    }

    @Test func publishesNothingWhenTheClockStandsStill() async throws {
        let lab = LabControls()
        let clock = SteppedClock(startNs: RunnerRun.startNs, stepNs: 0)
        let published = PublishedBatches()
        let pauses = RecordedPauses()
        let runner = MarketRunner(
            engine: RunnerRun.makeEngine(), lab: lab, nowNs: { clock.now() }, publish: { published.append($0) },
            pause: { await pauses.wait($0) }
        )
        let task = Task { try await runner.run() }
        // Every reading is the market's own start time, so the market has nowhere to go.
        let looped = await eventually { clock.readings >= 10 }
        task.cancel()
        let ended = await finishes(within: patience) { _ = await task.result }
        #expect(looped, "the runner did not iterate")
        #expect(ended, "the runner did not end when its task was cancelled")
        #expect(published.all.isEmpty)
    }

    @Test func waitsTenMillisecondsBetweenIterations() async throws {
        let run = RunnerRun()
        let readings = try await run.run(readings: 12)
        #expect(run.pauses.all == Array(repeating: .milliseconds(10), count: readings))
    }

    @Test func waitsTwoMillisecondsBetweenIterationsInStressMode() async throws {
        let lab = LabControls()
        await lab.apply(LabPatch(stress: true))
        let run = RunnerRun(lab: lab)
        let readings = try await run.run(readings: 12)
        #expect(run.pauses.all == Array(repeating: .milliseconds(2), count: readings))
    }

    /// Without a wait of its own a runner sleeps, and a sleep never ends early: however busy the machine is, two
    /// iterations never begin less than the wait apart. A runner that did not wait would spin.
    @Test func theDefaultWaitIsASleep() async throws {
        let clock = SteppedClock(startNs: RunnerRun.startNs, stepNs: RunnerRun.stepNs)
        let runner = MarketRunner(engine: RunnerRun.makeEngine(), lab: LabControls(), nowNs: { clock.now() })
        let task = Task { try await runner.run() }
        let looped = await eventually { clock.readings >= 12 }
        task.cancel()
        let ended = await finishes(within: patience) { _ = await task.result }
        #expect(looped, "the runner did not iterate")
        #expect(ended, "the runner did not end when its task was cancelled")

        let times = clock.readingTimes
        let shortest = try #require(zip(times, times.dropFirst()).map { $1 - $0 }.min())
        #expect(shortest >= .milliseconds(10), "two iterations began \(shortest) apart")
    }

    @Test func endsWhenItsTaskIsCancelled() async throws {
        let clock = SteppedClock(startNs: RunnerRun.startNs, stepNs: RunnerRun.stepNs)
        let runner = MarketRunner(engine: RunnerRun.makeEngine(), lab: LabControls(), nowNs: { clock.now() })
        let task = Task { try await runner.run() }
        let running = await eventually { clock.readings >= 3 }
        #expect(running, "the runner did not iterate")

        task.cancel()
        let ended = await finishes(within: patience) { _ = await task.result }
        #expect(ended, "the runner did not end when its task was cancelled")
        let readings = clock.readings
        try await Task.sleep(for: .milliseconds(60))
        #expect(clock.readings == readings, "the runner went on reading the clock after it ended")
    }

    /// A wait that is cut short, as a sleep is when its task is cancelled, ends the runner at once.
    @Test func endsWhenItsWaitIsInterrupted() async {
        let clock = SteppedClock(startNs: RunnerRun.startNs, stepNs: RunnerRun.stepNs)
        let waits = Counter()
        let runner = MarketRunner(
            engine: RunnerRun.makeEngine(), lab: LabControls(), nowNs: { clock.now() },
            pause: { _ in
                waits.increment()
                if waits.value == 3 { throw CancellationError() }
            }
        )
        let ended = await finishes(within: patience) { _ = try? await runner.run() }
        #expect(ended, "the runner did not end when its wait was interrupted")
        #expect(clock.readings == 3)
    }

    @Test func endsOnAGracefulShutdown() async {
        let clock = SteppedClock(startNs: RunnerRun.startNs, stepNs: RunnerRun.stepNs)
        let runner = MarketRunner(engine: RunnerRun.makeEngine(), lab: LabControls(), nowNs: { clock.now() })
        let returned = await finishes(within: patience) {
            await testGracefulShutdown { trigger in
                let task = Task { try await runner.run() }
                _ = await eventually { clock.readings >= 3 }
                trigger.triggerGracefulShutdown()
                _ = await task.result
            }
        }
        #expect(returned, "run() went on after a graceful shutdown")
    }
}

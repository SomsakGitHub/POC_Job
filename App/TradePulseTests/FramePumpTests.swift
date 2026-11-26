import Observation
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// `(seconds, nanoseconds)`: a time in seconds and the whole nanoseconds it is, rounded to the nearest.
private let nanosecondCases: [(Double, Int64)] = [
    (0.016, 16_000_000), (0.0, 0), (-0.001, -1_000_000), (1.0, 1_000_000_000), (6e-10, 1), (4e-10, 0), (-6e-10, -1),
    (-4e-10, 0),
]

/// `(lhs, rhs, sum)`: two numbers and their sum, kept at the bound of the addends' sign when it does not fit.
private let additionCases: [(Int64, Int64, Int64)] = [
    (1, 2, 3), (5, -10, -5), (Int64.max, 1, Int64.max), (Int64.max - 1, 5, Int64.max),
    (Int64.max, Int64.max, Int64.max), (Int64.min, -1, Int64.min), (-5, Int64.min, Int64.min),
    (Int64.min, Int64.min, Int64.min), (Int64.max, Int64.min, -1), (Int64.min, Int64.max, -1),
]

/// What one display frame does: when the tick moves, what is stamped as rendered, and what counts as a hitch. Every
/// frame here is a direct call to `step` with clocks the test sets, so no test waits for the display.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FramePumpTests {
    // MARK: The tick

    @Test func tickAdvancesOnlyWhenVersionChanges() {
        let rig = PumpRig()
        #expect(rig.pump.tick == 0)

        rig.step(at: 1.0)
        #expect(rig.pump.tick == 0)

        rig.apply(seq: 1)
        rig.step(at: 1.016)
        #expect(rig.pump.tick == 1)

        rig.step(at: 1.032)
        #expect(rig.pump.tick == 1)

        // A heartbeat and a repeated update leave the market as it was.
        _ = rig.market.apply(frame: marketFrame(sendNs: 0, updates: []), receivedAtNs: 0)
        _ = rig.market.apply(frame: marketFrame(sendNs: 0, updates: [symbolUpdate(seq: 1)]), receivedAtNs: 0)
        rig.step(at: 1.048)
        #expect(rig.pump.tick == 1)

        rig.apply(seq: 2)
        rig.step(at: 1.064)
        #expect(rig.pump.tick == 2)

        // Forgetting the market is a change too: the list has to show that the prices are gone.
        rig.market.reset()
        rig.step(at: 1.080)
        #expect(rig.pump.tick == 3)
    }

    @Test func manyVersionBumpsBetweenStepsGiveOneTick() {
        let rig = PumpRig()
        rig.step(at: 1.0)
        for seq in 1...5 as ClosedRange<UInt64> {
            rig.apply(seq: seq, sendNs: 4_980_000_000 + Int64(seq))
        }
        #expect(rig.market.version == 5)
        rig.step(at: 1.016)
        // A feed faster than the display makes one redraw per frame, never one per update.
        #expect(rig.pump.tick == 1)

        rig.apply(seq: 6, sendNs: 4_990_000_000)
        rig.apply(seq: 7, sendNs: 4_991_000_000)
        rig.step(at: 1.032)
        #expect(rig.pump.tick == 2)
    }

    // MARK: Where a pump begins

    @Test func pricesThatWereThereBeforeThePumpWasMadeAreNotNewToIt() {
        let rig = PumpRig()
        rig.apply(seq: 1)
        let late = FramePump(marketState: rig.market, now: { 5_000_000_000 }, mediaNow: { 100.0 })
        late.step(timestamp: 1.0, targetTimestamp: 1.016, duration: 0.016)
        #expect(late.tick == 0)

        // The same pump does see the next change.
        rig.apply(seq: 2)
        late.step(timestamp: 1.016, targetTimestamp: 1.032, duration: 0.016)
        #expect(late.tick == 1)
    }

    @Test func aPumpBeginsWithTheCountsOfTheDetectorItWasGiven() {
        var detector = HitchDetector()
        detector.record(frameIntervalNs: 16_000_000, expectedNs: 16_000_000)
        detector.record(frameIntervalNs: 16_000_000, expectedNs: 16_000_000)
        detector.record(frameIntervalNs: 50_000_000, expectedNs: 16_000_000)
        #expect(detector.frames == 2)
        #expect(detector.hitches == 1)

        let rig = PumpRig()
        let pump = FramePump(marketState: rig.market, hitchDetector: detector, now: { 0 }, mediaNow: { 0 })
        #expect(pump.frames == 2)
        #expect(pump.hitches == 1)
    }

    // MARK: The render stamp

    @Test func renderStampUsesTargetTimestamp() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: 0.016)
        rig.pump.notifyRendered(drawNs: 2_000_000)

        // The frame is due 16 ms after "now", so the sample is `now + 16 ms - serverSendNs`.
        let expected: Int64 = 5_000_000_000 + 16_000_000 - 4_990_000_000
        #expect(rig.latency.summary(.tickToRender) == summary(of: [expected]))
        #expect(rig.pump.drawCost.count == 1)
        #expect(rig.pump.drawCost == summary(of: [2_000_000]))
    }

    @Test func theDueTimeIsMeasuredFromTheMediaClockNotFromTheFrameTimestamp() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.004)
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: 0.016)
        // The media clock is already 4 ms past the frame's timestamp, so the frame is due 12 ms from now.
        let expected: Int64 = 5_000_000_000 + 12_000_000 - 4_990_000_000
        #expect(rig.latency.summary(.tickToRender) == summary(of: [expected]))
    }

    @Test func listOnlySessionRecordsTickToRender() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: 0.016)
        // No chart is on screen and nothing calls `notifyRendered`: the step alone has measured the frame.
        let expected: Int64 = 5_000_000_000 + 16_000_000 - 4_990_000_000
        #expect(rig.latency.summary(.tickToRender) == summary(of: [expected]))
        #expect(rig.pump.drawCost.count == 0)
    }

    @Test func manyFramesAppliedBetweenStepsAreMeasuredFromTheOldestOne() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        rig.apply(seq: 1, sendNs: 4_980_000_000)
        rig.apply(seq: 2, sendNs: 4_985_000_000)
        rig.apply(seq: 3, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: 0.016)
        // The oldest frame waited longest, and the one draw shows all three.
        let expected: Int64 = 5_000_000_000 + 16_000_000 - 4_980_000_000
        #expect(rig.latency.summary(.tickToRender) == summary(of: [expected]))
    }

    @Test func noStaleStampReachesTheFirstDraw() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: 0.016)

        // The list stays on screen for half a minute with nothing new, then a chart draws for the first time.
        rig.clock.set(35_000_000_000)
        rig.pump.step(timestamp: 100.016, targetTimestamp: 100.032, duration: 0.016)
        rig.pump.notifyRendered(drawNs: 1_000_000)

        let expected: Int64 = 5_000_000_000 + 16_000_000 - 4_990_000_000
        // One sample, and not a clamped one that would put a bogus point among the measured ones.
        #expect(rig.latency.summary(.tickToRender) == summary(of: [expected]))
        #expect(rig.latency.summary(.tickToRender).clamped == 0)
    }

    @Test func notifyRenderedBeforeAnyStepUsesNow() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.notifyRendered(drawNs: 1_000_000)
        // With no frame due yet, the draw is measured at "now", never at a stale 0 that would be a negative sample.
        #expect(rig.latency.summary(.tickToRender) == summary(of: [10_000_000]))
        #expect(rig.latency.summary(.tickToRender).clamped == 0)
        #expect(rig.pump.drawCost == summary(of: [1_000_000]))
    }

    @Test func aDrawAfterAStepMeasuresAgainstTheDueTimeOfThatStep() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        rig.step(at: 100.0)
        // A frame that arrives after the step, and is drawn by the view in the same display frame.
        rig.apply(seq: 1, sendNs: 4_995_000_000)
        rig.pump.notifyRendered(drawNs: 1_000_000)
        let expected: Int64 = 5_000_000_000 + 16_000_000 - 4_995_000_000
        #expect(rig.latency.summary(.tickToRender) == summary(of: [expected]))
    }

    @Test func everyDrawCostIsKept() {
        let rig = PumpRig()
        for drawNs: Int64 in [1_000_000, 2_000_000, 3_000_000] {
            rig.pump.notifyRendered(drawNs: drawNs)
        }
        #expect(rig.pump.drawCost == summary(of: [1_000_000, 2_000_000, 3_000_000]))
    }

    // MARK: Hitches

    @Test func hitchCountedWhenIntervalExceedsOnePointFiveFrames() {
        let rig = PumpRig()
        let pump = rig.pump
        pump.step(timestamp: 10.0, targetTimestamp: 10.016, duration: 0.016)
        // The first frame has no interval to measure.
        #expect(pump.frames == 0)
        #expect(pump.hitches == 0)

        pump.step(timestamp: 10.016, targetTimestamp: 10.032, duration: 0.016)
        #expect(pump.frames == 1)
        #expect(pump.hitches == 0)

        // Exactly 1.5 frames (24 ms) is not a hitch.
        pump.step(timestamp: 10.040, targetTimestamp: 10.056, duration: 0.016)
        #expect(pump.frames == 2)
        #expect(pump.hitches == 0)

        // 25 ms is.
        pump.step(timestamp: 10.065, targetTimestamp: 10.081, duration: 0.016)
        #expect(pump.frames == 3)
        #expect(pump.hitches == 1)

        pump.step(timestamp: 10.100, targetTimestamp: 10.116, duration: 0.016)
        #expect(pump.frames == 4)
        #expect(pump.hitches == 2)
    }

    @Test func theBudgetOfAFrameIsTheDurationTheLinkReports() {
        let rig = PumpRig()
        // A 120 Hz display: frames are 8.333 ms, so 13 ms between two frames is over 1.5 frames.
        let duration = 1.0 / 120.0
        rig.pump.step(timestamp: 10.0, targetTimestamp: 10.0 + duration, duration: duration)
        rig.pump.step(timestamp: 10.013, targetTimestamp: 10.013 + duration, duration: duration)
        #expect(rig.pump.frames == 1)
        #expect(rig.pump.hitches == 1)
    }

    @Test func firstStepAfterRestartHasNoInterval() {
        let rig = PumpRig()
        rig.pump.start()
        defer { rig.pump.stop() }
        rig.step(at: 10.0)
        rig.step(at: 10.016)
        #expect(rig.pump.frames == 1)

        rig.pump.stop()
        rig.pump.start()
        // The app was away for ten seconds: that is not a frame, and certainly not a hitch.
        rig.step(at: 20.0)
        #expect(rig.pump.frames == 1)
        #expect(rig.pump.hitches == 0)

        rig.step(at: 20.016)
        #expect(rig.pump.frames == 2)
        #expect(rig.pump.hitches == 0)
    }

    @Test func aStepThatDoesNotMoveTheClockCountsAsNothing() {
        let rig = PumpRig()
        rig.step(at: 10.0)
        rig.step(at: 10.016)
        rig.step(at: 10.016)
        rig.step(at: 10.0)
        #expect(rig.pump.frames == 1)
        #expect(rig.pump.hitches == 0)
    }

    // MARK: Starting the statistics over

    @Test func resetStatisticsStartsTheCountsOverAndTheNextFramesCountAgain() {
        let rig = PumpRig()
        let pump = rig.pump
        rig.step(at: 10.0)
        rig.step(at: 10.016)
        rig.step(at: 10.100)
        pump.notifyRendered(drawNs: 2_000_000)
        let before = (pump.frames, pump.hitches, pump.drawCost.count)

        pump.resetStatistics()

        #expect(before.0 == 2 && before.1 == 1 && before.2 == 1, "two frames, one of them a hitch, and one draw")
        #expect(pump.frames == 0)
        #expect(pump.hitches == 0)
        #expect(pump.drawCost.count == 0)
        #expect(pump.drawCost == PercentileSummary(count: 0, p50Ns: nil, p95Ns: nil, p99Ns: nil, clamped: 0))

        // The frame before the reset is still the one the next interval is measured from, so the first frame after
        // the reset is a frame and not the first of a start.
        rig.step(at: 10.116)
        #expect(pump.frames == 1)
        #expect(pump.hitches == 0)
        rig.step(at: 10.200)
        #expect(pump.frames == 2)
        #expect(pump.hitches == 1)
    }

    @Test func resetStatisticsLeavesTheLinkTheRenderStampAndTheTickAlone() {
        let links = StubLinks()
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0, makeLink: { links.make($0, $1) })
        rig.pump.start()
        defer { rig.pump.stop() }
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: 0.016)
        let tickBefore = rig.pump.tick
        // Time goes by, and a frame is applied that no step has shown yet.
        rig.clock.set(9_000_000_000)
        rig.apply(seq: 2, sendNs: 4_995_000_000)

        rig.pump.resetStatistics()
        rig.pump.notifyRendered(drawNs: 1_000_000)

        #expect(tickBefore == 1)
        #expect(rig.pump.tick == tickBefore)
        #expect(rig.pump.isRunning)
        #expect(links.made.count == 1)
        #expect(links.made.first?.invalidations == 0)
        // The draw is stamped with the due time of the last step, 26 ms and then 21 ms after the server's stamps, and
        // not with the clock, which would make a latency of seconds.
        #expect(rig.latency.summary(.tickToRender) == summary(of: [26_000_000, 21_000_000]))
        #expect(rig.pump.drawCost == summary(of: [1_000_000]))
    }

    @Test func resetStatisticsOfAPumpThatCountedNothingTellsNobody() {
        let rig = PumpRig()
        let quiet = Flag()
        withObservationTracking {
            _ = rig.pump.frames
            _ = rig.pump.hitches
        } onChange: {
            quiet.set()
        }

        rig.pump.resetStatistics()
        let toldByTheReset = quiet.isSet

        // The control: the same observation is told when a frame is counted.
        rig.step(at: 10.0)
        rig.step(at: 10.016)

        #expect(!toldByTheReset)
        #expect(quiet.isSet)
        #expect(rig.pump.frames == 1)
    }

    // MARK: Totality

    @Test(arguments: [
        Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
        .leastNonzeroMagnitude, -.leastNonzeroMagnitude, 1e30, -1e30, 0,
    ])
    func degenerateTimestampsNeverTrap(value: Double) {
        let rig = PumpRig()
        let pump = rig.pump
        rig.step(at: 1.0)
        var expectedTick: UInt64 = 0

        // Each of the three numbers on its own, then all of them at once, and then the media clock.
        let calls: [(Double, Double, Double)] = [
            (value, 1.016, 0.016), (1.0, value, 0.016), (1.0, 1.016, value), (value, value, value),
        ]
        for (timestamp, target, duration) in calls {
            rig.apply(seq: expectedTick + 1, sendNs: 4_990_000_000)
            pump.step(timestamp: timestamp, targetTimestamp: target, duration: duration)
            expectedTick += 1
            #expect(pump.tick == expectedTick)
        }
        rig.media.set(value)
        rig.apply(seq: expectedTick + 1, sendNs: 4_990_000_000)
        rig.step(at: 1.0)
        #expect(pump.tick == expectedTick + 1)
        #expect(pump.hitches <= pump.frames)
    }

    @Test func aDueTimeThatCannotBeMeasuredIsTakenAsNow() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: .nan, duration: 0.016)
        #expect(rig.latency.summary(.tickToRender) == summary(of: [10_000_000]))

        rig.apply(seq: 2, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.016, targetTimestamp: .infinity, duration: 0.016)
        #expect(rig.latency.summary(.tickToRender) == summary(of: [10_000_000, 10_000_000]))
    }

    @Test func aDueTimeBeyondTheRangeIsKeptInRangeAndCounted() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 1e30, duration: 0.016)
        // The recorder clamps what is out of range and says so; nothing wraps around to a small number.
        let recorded = rig.latency.summary(.tickToRender)
        #expect(recorded.count == 1)
        #expect(recorded.clamped == 1)
    }

    @Test(arguments: nanosecondCases)
    func nanosecondsRoundToTheNearestNanosecond(seconds: Double, expected: Int64) {
        #expect(FramePump.nanoseconds(seconds) == expected)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nanosecondsOfSomethingThatIsNotANumberIsZero(seconds: Double) {
        #expect(FramePump.nanoseconds(seconds) == 0)
    }

    @Test func nanosecondsAreClampedAtTheBoundsOfInt64() {
        #expect(FramePump.nanoseconds(1e30) == Int64.max)
        #expect(FramePump.nanoseconds(-1e30) == Int64.min)
        #expect(FramePump.nanoseconds(.greatestFiniteMagnitude) == Int64.max)
        #expect(FramePump.nanoseconds(-.greatestFiniteMagnitude) == Int64.min)
        // The seconds whose nanoseconds are just about 2^63, which `Int64(_:)` would trap on.
        let edge = FramePump.nanoseconds(Double(Int64.max) / 1e9)
        #expect(edge >= Int64.max - 2_048)
        let negativeEdge = FramePump.nanoseconds(Double(Int64.min) / 1e9)
        #expect(negativeEdge <= Int64.min + 2_048)
    }

    @Test(arguments: additionCases)
    func saturatingAddClampsAtTheBoundOfTheAddendsSign(lhs: Int64, rhs: Int64, expected: Int64) {
        #expect(FramePump.saturatingAdd(lhs, rhs) == expected)
    }
}

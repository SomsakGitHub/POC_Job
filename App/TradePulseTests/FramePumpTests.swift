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

/// `(first, period, notBefore, refresh)`: a display that refreshes at `first` and every `period` from then on, a
/// moment, and the first refresh at or after it. A period of 0 or less is a grid that is not known, which has no
/// refresh but `first`, so a moment after `first` is taken as a refresh of its own.
private let firstRefreshCases: [(Int64, Int64, Int64, Int64)] = [
    // The refresh itself, and then the ones after it.
    (100, 16, 100, 100), (100, 16, 99, 100), (100, 16, 101, 116), (100, 16, 116, 116), (100, 16, 117, 132),
    (100, 16, 250, 260),
    // A grid that is not known.
    (100, 0, 150, 150), (100, -5, 150, 150), (100, 0, 50, 100), (100, -5, 100, 100),
    // Times before 0.
    (-100, 16, -100, -100), (-100, 16, -50, -36), (-1, 16, 0, 15),
    // The extremes: nothing traps, and a refresh that does not fit in an `Int64` is kept at the bound.
    (Int64.max, 16, Int64.max, Int64.max), (Int64.max, 16, 100, Int64.max), (Int64.min, 16, Int64.min, Int64.min),
    (Int64.min, 16, Int64.min + 1, Int64.min + 16), (Int64.min, 1, Int64.max, Int64.max),
    (Int64.min, 16, Int64.max, Int64.max), (Int64.min, Int64.max, Int64.max, Int64.max),
    (Int64.min, Int64.max, Int64.min + 1, -1), (Int64.min, Int64.max, 0, Int64.max - 1),
    (0, Int64.max, Int64.max, Int64.max), (1, Int64.max, Int64.max, Int64.max),
    (Int64.max - 10, 16, Int64.max, Int64.max), (Int64.min, 0, Int64.max, Int64.max),
    (Int64.min, Int64.min, Int64.max, Int64.max), (Int64.max, Int64.min, Int64.min, Int64.max),
]

/// `(stampedAfterDue, drawnAfterDue, refreshes)`: when the server stamped a tick and when the draw that shows it ended,
/// both in nanoseconds after the due time of the last step of a display of 16 ms frames, and the number of refreshes
/// after that due time at which the frame is on screen. The tick is applied after the step, so none of these frames can
/// be on screen at the due time.
private let lateDrawCases: [(Int64, Int64, Int64)] = [
    // The draw ends 5 ms after the due time, which has gone by: the frame is on the next refresh.
    (1_000_000, 5_000_000, 1),
    // The draw ends 2.3 frames after it: the refreshes at the due time and one and two frames after it have gone by,
    // so the frame is on the one three frames after it.
    (1_000_000, 36_800_000, 3),
    // The server stamped the tick before the due time, but it was applied after it. The stamp being positive does not
    // make it right.
    (-3_000_000, 5_000_000, 1),
    // The draw ends on the next refresh: it is on it.
    (1_000_000, 16_000_000, 1),
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

    @Test func aFrameAppliedWhileThePumpWasStoppedIsNotMeasuredWhenItStartsAgain() {
        let links = StubLinks()
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0, makeLink: { links.make($0, $1) })
        rig.pump.start()
        defer { rig.pump.stop() }
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: 0.016)
        rig.pump.stop()

        // A frame arrives after the last step, and the screen stops drawing for half a minute.
        rig.apply(seq: 2, sendNs: 4_995_000_000)
        rig.clock.set(35_000_000_000)
        rig.media.set(130.0)
        rig.pump.start()
        rig.pump.step(timestamp: 130.0, targetTimestamp: 130.016, duration: 0.016)

        // The frame that was never drawn is not measured against the first refresh after the return: the one sample
        // is the frame of the first step, and nothing is clamped.
        #expect(rig.latency.summary(.tickToRender) == summary(of: [26_000_000]))
        #expect(rig.latency.summary(.tickToRender).clamped == 0)
        // The new prices are still shown: the tick moves for them.
        #expect(rig.pump.tick == 2)
    }

    @Test func aDrawWhileThePumpIsStoppedMeasuresNothingAndItsCostIsKept() {
        let links = StubLinks()
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0, makeLink: { links.make($0, $1) })
        rig.pump.start()
        defer { rig.pump.stop() }
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: 0.016)
        rig.pump.stop()

        // A frame arrives after the last step and the app is away for half a minute. On the way back the chart draws,
        // before the display link starts again.
        rig.apply(seq: 2, sendNs: 4_995_000_000)
        rig.clock.set(35_000_000_000)
        rig.pump.notifyRendered(drawNs: 1_000_000)

        // Nobody saw that frame when it arrived, so the draw measures nothing: no sample, and nothing clamped. What
        // the draw cost is still kept.
        #expect(rig.latency.summary(.tickToRender) == summary(of: [26_000_000]))
        #expect(rig.latency.summary(.tickToRender).clamped == 0)
        #expect(rig.pump.drawCost == summary(of: [1_000_000]))

        // After the start the frame is not measured either, and the tick moves for it.
        rig.media.set(130.0)
        rig.pump.start()
        rig.pump.step(timestamp: 130.0, targetTimestamp: 130.016, duration: 0.016)
        #expect(rig.latency.summary(.tickToRender) == summary(of: [26_000_000]))
        #expect(rig.pump.tick == 2)
    }

    @Test func aFrameAppliedAfterAStartIsMeasuredAtTheNextStep() {
        let links = StubLinks()
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0, makeLink: { links.make($0, $1) })
        rig.pump.start()
        defer { rig.pump.stop() }
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: 0.016)

        #expect(rig.latency.summary(.tickToRender) == summary(of: [26_000_000]))
        #expect(rig.pump.tick == 1)
    }

    @Test func aDrawAfterAStartAndBeforeAnyStepIsNeverStampedBeforeTheClock() {
        let links = StubLinks()
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0, makeLink: { links.make($0, $1) })
        rig.pump.start()
        defer { rig.pump.stop() }
        // The last step before the stop is due at 5.016 s, on refreshes 16 ms apart.
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: 0.016)
        rig.pump.stop()

        // Half a minute later the pump starts again, and a frame is applied and drawn before the first step.
        rig.clock.set(35_000_000_000)
        rig.media.set(130.0)
        rig.pump.start()
        rig.apply(seq: 2, sendNs: 34_990_000_000)
        rig.pump.notifyRendered(drawNs: 1_000_000)

        // The draw is stamped with the first refresh of the old grid at or after the clock, which is 35.000 s itself:
        // 10 ms after the server's stamp, and never a refresh that had gone by.
        #expect(rig.latency.summary(.tickToRender) == summary(of: [26_000_000, 10_000_000]))
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

    // MARK: A stamp is never earlier than the moment it was taken

    @Test(arguments: lateDrawCases)
    func aDrawThatEndsAfterTheDueTimeIsStampedWithTheFirstRefreshAtOrAfterItsEnd(
        stampedAfterDue: Int64, drawnAfterDue: Int64, refreshes: Int64
    ) {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        // The step is due at 5.016 s, and the refreshes are 16 ms apart.
        rig.step(at: 100.0)
        let due: Int64 = 5_016_000_000
        rig.clock.set(due + drawnAfterDue)
        rig.apply(seq: 1, sendNs: due + stampedAfterDue)
        rig.pump.notifyRendered(drawNs: 1_000_000)

        let expected = refreshes * 16_000_000 - stampedAfterDue
        #expect(rig.latency.summary(.tickToRender) == summary(of: [expected]))
        #expect(rig.latency.summary(.tickToRender).clamped == 0)
    }

    @Test func aDrawAtTheDueTimeIsStampedWithItAndOneNanosecondLaterWithTheNextRefresh() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        rig.step(at: 100.0)
        // The due time is 5.016 s. A draw that ends then is on that refresh; one that ends a nanosecond later has
        // missed it.
        rig.clock.set(5_016_000_000)
        rig.apply(seq: 1, sendNs: 5_010_000_000)
        rig.pump.notifyRendered(drawNs: 1_000_000)
        rig.clock.set(5_016_000_001)
        rig.apply(seq: 2, sendNs: 5_010_000_000)
        rig.pump.notifyRendered(drawNs: 1_000_000)

        #expect(rig.latency.summary(.tickToRender) == summary(of: [6_000_000, 22_000_000]))
    }

    @Test func drawsThatEndBeforeTheDueTimeAreAllStampedWithIt() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        rig.step(at: 100.0)
        // Three ticks, each applied and drawn on its own, at 5.001 s, 5.008 s and 5.015 s: all before 5.016 s.
        let drawnAt: [Int64] = [5_001_000_000, 5_008_000_000, 5_015_000_000]
        for (index, at) in drawnAt.enumerated() {
            rig.clock.set(at)
            rig.apply(seq: UInt64(index + 1), sendNs: at - 500_000)
            rig.pump.notifyRendered(drawNs: 1_000_000)
        }

        let due: Int64 = 5_016_000_000
        let expected = drawnAt.map { due - ($0 - 500_000) }
        #expect(rig.latency.summary(.tickToRender) == summary(of: expected))
        #expect(rig.latency.summary(.tickToRender).clamped == 0)
    }

    @Test func aLinkThatFiresAfterItsTargetStampsTheFirstRefreshAtOrAfterTheClock() {
        // The media clock reads 14 ms after the target the link reports: the frame was due at 4.986 s, and the step
        // runs at 5.0 s. With 16 ms frames the refresh at or after 5.0 s is the next one, 5.002 s, and not the one
        // that has gone by.
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.030)
        rig.market.setClockOffset(7_000_000)
        rig.apply(seq: 1, sendNs: 4_999_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: 0.016)
        // A tick that is applied after the step and drawn at the same clock is stamped with the same refresh.
        rig.apply(seq: 2, sendNs: 4_999_500_000)
        rig.pump.notifyRendered(drawNs: 1_000_000)

        // A sample is on the server's clock: the client's clock plus the offset, less the server's stamp. At 5.0 s the
        // first tick is at least 8 ms old and the second at least 7.5 ms, and each is 2 ms older at the refresh.
        let refresh: Int64 = 5_002_000_000 + 7_000_000
        let expected = [refresh - 4_999_000_000, refresh - 4_999_500_000]
        #expect(rig.latency.summary(.tickToRender) == summary(of: expected))
        #expect(rig.latency.summary(.tickToRender).clamped == 0)
    }

    @Test func aLinkThatFiresOnTimeKeepsItsTargetAsTheStamp() {
        // The target is 1 ms ahead of the media clock, so the frame is due 1 ms from now and nothing has passed.
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.015)
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: 0.016)
        #expect(rig.latency.summary(.tickToRender) == summary(of: [11_000_000]))
    }

    @Test(arguments: [0.0, Double.nan, .infinity, -.infinity, -0.016])
    func aFrameWithNoLengthIsStampedWithTheDueTimeBeforeItAndWithTheClockAfterIt(duration: Double) {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        // Due at 5.016 s, on a display whose refreshes are not known.
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: duration)
        rig.clock.set(5_010_000_000)
        rig.apply(seq: 1, sendNs: 5_005_000_000)
        rig.pump.notifyRendered(drawNs: 1_000_000)
        // After the due time there is no next refresh to say, so the stamp is the clock: 5.04 s.
        rig.clock.set(5_040_000_000)
        rig.apply(seq: 2, sendNs: 5_030_000_000)
        rig.pump.notifyRendered(drawNs: 1_000_000)

        #expect(rig.latency.summary(.tickToRender) == summary(of: [11_000_000, 10_000_000]))
        #expect(rig.latency.summary(.tickToRender).clamped == 0)
    }

    @Test(arguments: [0.0, Double.nan])
    func aLateLinkWithNoFrameLengthStampsTheClock(duration: Double) {
        // The frame was due at 4.986 s and the step runs at 5.0 s. Nothing says where the refreshes are, so the stamp
        // is the clock and not the due time that has gone by.
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.030)
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        rig.pump.step(timestamp: 100.0, targetTimestamp: 100.016, duration: duration)

        #expect(rig.latency.summary(.tickToRender) == summary(of: [10_000_000]))
        #expect(rig.latency.summary(.tickToRender).clamped == 0)
    }

    @Test func noRenderIsStampedBeforeItsTickWasStampedByTheServer() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        // How long after the media clock a step says its frame is due, in seconds: on time, early, late and later.
        let leads: [Double] = [0.016, 0.004, -0.003, -0.020]
        var now: Int64 = 5_000_000_000
        for round in 0..<900 {
            // 0 to 39 ms between two events, in an order that takes a long time to repeat.
            now += Int64((round * 17 + round / 7) % 40) * 1_000_000
            rig.clock.set(now)
            rig.media.set(100.0 + Double(now - 5_000_000_000) / 1e9)
            // A tick the server stamped 1 ms ago, and then a frame: either a step or a draw shows it.
            rig.apply(seq: UInt64(round + 1), sendNs: now - 1_000_000)
            if round % 3 == 0 {
                let media = rig.media.read()
                rig.pump.step(
                    timestamp: media - 0.016, targetTimestamp: media + leads[(round / 3) % leads.count],
                    duration: 0.016
                )
            } else {
                rig.pump.notifyRendered(drawNs: 1_000_000)
            }
        }

        let rendered = rig.latency.summary(.tickToRender)
        #expect(rendered.count == 900)
        // A tick that was applied cannot have been on screen before the server sent it: nothing is below 0.
        #expect(rendered.clamped == 0)
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
        // Time goes by, less than a frame, and a frame is applied that no step has shown yet.
        rig.clock.set(5_010_000_000)
        rig.apply(seq: 2, sendNs: 4_995_000_000)

        rig.pump.resetStatistics()
        rig.pump.notifyRendered(drawNs: 1_000_000)

        #expect(tickBefore == 1)
        #expect(rig.pump.tick == tickBefore)
        #expect(rig.pump.isRunning)
        #expect(links.made.count == 1)
        #expect(links.made.first?.invalidations == 0)
        // The draw ends before the due time of the last step, so it is stamped with that due time, 26 ms and then 21 ms
        // after the server's stamps, and not with the clock, which is 6 ms earlier.
        #expect(rig.latency.summary(.tickToRender) == summary(of: [26_000_000, 21_000_000]))
        #expect(rig.pump.drawCost == summary(of: [1_000_000]))
    }

    @Test func resetStatisticsLeavesTheRefreshesOfTheLastStepWhereTheyAre() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        // The last step is due at 5.016 s, and the refreshes are 16 ms apart.
        rig.step(at: 100.0)
        rig.pump.resetStatistics()

        // A draw that ends at 5.021 s has missed the refresh at 5.016 s, and is on the next one, as it would be
        // without the reset.
        rig.clock.set(5_021_000_000)
        rig.apply(seq: 1, sendNs: 5_017_000_000)
        rig.pump.notifyRendered(drawNs: 1_000_000)

        #expect(rig.latency.summary(.tickToRender) == summary(of: [15_000_000]))
        #expect(rig.latency.summary(.tickToRender).clamped == 0)
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

    @Test(arguments: firstRefreshCases)
    func firstRefreshIsTheFirstPointOfTheGridAtOrAfterTheMoment(
        first: Int64, period: Int64, notBefore: Int64, expected: Int64
    ) {
        #expect(FramePump.firstRefresh(from: first, every: period, notBefore: notBefore) == expected)
    }

    @Test func firstRefreshAgreesWithAWalkAlongTheGridForSmallNumbers() {
        var disagreements: [String] = []
        for first in Int64(-10)...10 {
            for period in Int64(-2)...12 {
                for notBefore in Int64(-25)...40 {
                    // The walk: a step at a time from `first` until the moment is reached.
                    var walked = first
                    if period > 0 {
                        while walked < notBefore { walked += period }
                    } else if walked < notBefore {
                        walked = notBefore
                    }
                    let found = FramePump.firstRefresh(from: first, every: period, notBefore: notBefore)
                    if found != walked {
                        disagreements.append("(\(first), \(period), \(notBefore)) is \(found), not \(walked)")
                    }
                }
            }
        }
        #expect(disagreements.isEmpty, "\(disagreements.prefix(5))")
    }

    @Test func firstRefreshNeverTrapsAndNeverGoesBelowTheMomentOrTheRefreshItStartsFrom() {
        let edges: [Int64] = [.min, .min + 1, -1_000_000_007, -1, 0, 1, 16, 1_000_000_007, .max - 1, .max]
        var problems: [String] = []
        for first in edges {
            for period in edges {
                for notBefore in edges {
                    let found = FramePump.firstRefresh(from: first, every: period, notBefore: notBefore)
                    let call = "(\(first), \(period), \(notBefore)) is \(found)"
                    if found < first || found < notBefore {
                        problems.append("\(call), below the moment or the first refresh")
                    }
                    // A refresh that fits is on the grid, and the one before it is too early. One at the bound may be
                    // the bound of a refresh that did not fit.
                    if period > 0, first < notBefore, found < .max {
                        if (Int128(found) - Int128(first)) % Int128(period) != 0 {
                            problems.append("\(call), off the grid")
                        }
                        if Int128(found) - Int128(period) >= Int128(notBefore) {
                            problems.append("\(call), not the first one")
                        }
                    }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(5))")
    }
}

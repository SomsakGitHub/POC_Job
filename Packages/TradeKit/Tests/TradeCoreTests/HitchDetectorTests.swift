import Testing
// `@testable` only for the internal initializer that starts the counters next to their limit.
@testable import TradeCore

/// The frame budget at 60 Hz, to the nearest 0.1 ms: 16.7 ms.
private let budget: Int64 = 16_700_000

/// A detector whose first call (which is never measured) has been used up, so the next call is a measured frame.
private func afterTheFirstFrame() -> HitchDetector {
    var detector = HitchDetector()
    detector.record(frameIntervalNs: budget, expectedNs: budget)
    return detector
}

struct HitchDetectorTests {
    @Test func startsWithNothingCounted() {
        let detector = HitchDetector()
        #expect(detector.frames == 0)
        #expect(detector.hitches == 0)
    }

    // MARK: The reference cases

    /// The first call has no previous frame to measure against, so it counts as neither a frame nor a hitch, even if
    /// its interval would be a hitch.
    @Test(arguments: [budget, 30_000_000, 5_000_000_000, Int64.max] as [Int64])
    func theFirstFrameIsIgnored(interval: Int64) {
        var detector = HitchDetector()
        detector.record(frameIntervalNs: interval, expectedNs: budget)
        #expect(detector.frames == 0)
        #expect(detector.hitches == 0)
    }

    @Test func aFrameOnTheBudgetIsNotAHitch() {
        var detector = afterTheFirstFrame()
        detector.record(frameIntervalNs: 16_700_000, expectedNs: budget)
        #expect(detector.frames == 1)
        #expect(detector.hitches == 0)
    }

    @Test func aThirtyMillisecondFrameIsAHitch() {
        var detector = afterTheFirstFrame()
        detector.record(frameIntervalNs: 30_000_000, expectedNs: budget)
        #expect(detector.frames == 1)
        #expect(detector.hitches == 1)
    }

    // MARK: The threshold

    /// A hitch is an interval over 1.5 times the budget, worked out in integers as interval * 2 > expected * 3
    /// (in 128 bits, so no pair of `Int64` can overflow it): exactly 1.5 times is not a hitch, one nanosecond more is.
    /// The last rows sit where a Double product could no longer tell the sides apart.
    @Test(arguments: [
        // (interval, expected, is a hitch)
        (16_700_000, 16_700_000, false),
        (25_049_999, 16_700_000, false),
        (25_050_000, 16_700_000, false),    // exactly 1.5x
        (25_050_001, 16_700_000, true),
        (30_000_000, 16_700_000, true),
        (1, 1, false),
        (2, 1, true),
        (3, 2, false),                      // exactly 1.5x
        (4, 2, true),
        (4, 3, false),                      // 1.33x
        (5, 3, true),                       // 1.67x
        (Int64.max, 1, true),
        (1, Int64.max, false),
        (Int64.max, Int64.max, false),
        (Int64.max, Int64.max / 2, true),
        (Int64.max, Int64.max / 3, true),
        (Int64.max / 2, Int64.max / 3, false),      // 2 * interval and 3 * expected are both 2^63 - 2
        (Int64.max / 2 + 1, Int64.max / 3, true),   // 2^63 against 2^63 - 2: a Double sees no difference
    ] as [(Int64, Int64, Bool)])
    func hitchIsMoreThanOneAndAHalfTimesTheBudget(interval: Int64, expected: Int64, isHitch: Bool) {
        var detector = afterTheFirstFrame()
        detector.record(frameIntervalNs: interval, expectedNs: expected)
        #expect(detector.frames == 1)
        #expect(detector.hitches == (isHitch ? 1 : 0))
    }

    // MARK: Calls that are not frames

    /// An interval or a budget that is zero or negative cannot describe a frame (a clock that did not advance or went
    /// backwards, a display with no refresh rate yet): the call is dropped, and counts as nothing.
    @Test(arguments: [
        (0, budget),
        (-1, budget),
        (Int64.min, budget),
        (budget, 0),
        (budget, -1),
        (budget, Int64.min),
        (0, 0),
        (-5, -5),
        (Int64.min, Int64.min),
    ] as [(Int64, Int64)])
    func aNonPositiveIntervalOrBudgetIsNotCounted(interval: Int64, expected: Int64) {
        var detector = afterTheFirstFrame()
        detector.record(frameIntervalNs: interval, expectedNs: expected)
        #expect(detector.frames == 0)
        #expect(detector.hitches == 0)
    }

    /// "The first frame" is the first call, whatever it holds: a first call with no usable interval (there is nothing
    /// before the first frame to measure) still uses it up, so the second call is a measured frame, not a second
    /// skipped one.
    @Test(arguments: [(0, budget), (-1, budget), (budget, 0), (Int64.min, Int64.min)] as [(Int64, Int64)])
    func anUnusableFirstCallStillUsesUpTheFirstFrame(interval: Int64, expected: Int64) {
        var detector = HitchDetector()
        detector.record(frameIntervalNs: interval, expectedNs: expected)
        #expect(detector.frames == 0)
        detector.record(frameIntervalNs: budget, expectedNs: budget)
        #expect(detector.frames == 1)
        #expect(detector.hitches == 0)
    }

    @Test func ignoredCallsDoNotDisturbTheCountsSoFar() {
        var detector = afterTheFirstFrame()
        detector.record(frameIntervalNs: 40_000_000, expectedNs: budget)
        detector.record(frameIntervalNs: 0, expectedNs: budget)
        detector.record(frameIntervalNs: budget, expectedNs: -1)
        detector.record(frameIntervalNs: budget, expectedNs: budget)
        #expect(detector.frames == 2)
        #expect(detector.hitches == 1)
    }

    // MARK: Counting

    /// A hundred measured frames after the ignored first one, three of them slow: 100 frames, 3 hitches.
    @Test func countsFramesAndHitchesOverARun() {
        var detector = HitchDetector()
        let slow: Set<Int> = [30, 50, 75]
        for frame in 0...100 {
            detector.record(frameIntervalNs: slow.contains(frame) ? 33_400_000 : 16_700_000, expectedNs: budget)
        }
        #expect(detector.frames == 100)
        #expect(detector.hitches == 3)
    }

    /// Each frame can also have its own budget (a display that changes its refresh rate): the frame is judged
    /// against the budget it is given.
    @Test func eachFrameIsJudgedAgainstTheBudgetItIsGiven() {
        var detector = afterTheFirstFrame()
        detector.record(frameIntervalNs: 20_000_000, expectedNs: 8_300_000)    // 120 Hz budget: a hitch
        detector.record(frameIntervalNs: 20_000_000, expectedNs: 16_700_000)   // 60 Hz budget: not
        #expect(detector.frames == 2)
        #expect(detector.hitches == 1)
    }

    // MARK: Saturation

    /// The counters stop at `Int.max` instead of trapping, and each counts on its own: a frame that is also a hitch
    /// moves whichever of the two still has room.
    @Test func countersSaturateInsteadOfTrapping() {
        var detector = HitchDetector(frames: Int.max - 2, hitches: Int.max - 1)
        for _ in 0..<5 {
            detector.record(frameIntervalNs: 100_000_000, expectedNs: budget)
        }
        #expect(detector.frames == Int.max)
        #expect(detector.hitches == Int.max)
    }

    @Test func aFullFrameCounterDoesNotStopTheHitchCounter() {
        var detector = HitchDetector(frames: Int.max, hitches: 0)
        detector.record(frameIntervalNs: 100_000_000, expectedNs: budget)
        #expect(detector.frames == Int.max)
        #expect(detector.hitches == 1)
    }

    @Test func aFullHitchCounterDoesNotStopTheFrameCounter() {
        var detector = HitchDetector(frames: 5, hitches: Int.max)
        detector.record(frameIntervalNs: 100_000_000, expectedNs: budget)
        detector.record(frameIntervalNs: budget, expectedNs: budget)
        #expect(detector.frames == 7)
        #expect(detector.hitches == Int.max)
    }
}

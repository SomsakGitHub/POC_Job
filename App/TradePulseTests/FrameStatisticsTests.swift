import Testing
import TradeCore
@testable import TradePulse

/// `(fps, words)`: a frame rate as the meter gives it, and the text for it.
private let fpsCases: [(Double?, String)] = [
    (nil, "\u{2014}"), (59.8, "59.8 fps"), (60, "60.0 fps"), (0, "0.0 fps"), (59.96, "60.0 fps"), (59.94, "59.9 fps"),
    (59.75, "59.8 fps"), (0.25, "0.3 fps"), (120, "120.0 fps"), (8.333, "8.3 fps"), (.nan, "\u{2014}"),
    (.infinity, "\u{2014}"), (-1, "\u{2014}"), (1e30, "\u{2014}"),
]

/// `(hitches, frames, words)`: the hitches among the frames and the words that say how many they are.
private let hitchCases: [(Int, Int, String)] = [
    (3, 750, "3 hitches (0.4%)"), (1, 1_000, "1 hitch (0.1%)"), (0, 100, "0 hitches (0.0%)"),
    // 6.25 % is half way between 6.2 and 6.3, and half way rounds up.
    (1, 16, "1 hitch (6.3%)"), (1, 8, "1 hitch (12.5%)"), (1, 3, "1 hitch (33.3%)"), (2, 3, "2 hitches (66.7%)"),
    // 0.05 % is half way between 0.0 and 0.1, 0.025 % is not.
    (1, 2_000, "1 hitch (0.1%)"), (1, 4_000, "1 hitch (0.0%)"), (1_234, 100_000, "1,234 hitches (1.2%)"),
    (5, 5, "5 hitches (100.0%)"), (7, 5, "7 hitches (100.0%)"),
    // With no frame there is no rate, whatever the hitches say.
    (1, 0, "\u{2014}"), (0, 0, "\u{2014}"), (5, -1, "\u{2014}"), (-3, 100, "0 hitches (0.0%)"),
    (Int.max, Int.max, "9,223,372,036,854,775,807 hitches (100.0%)"),
    (Int.max - 1, Int.max, "9,223,372,036,854,775,806 hitches (100.0%)"),
]

/// What the Lab says about the frames: the rate the display link runs at, how many frames hitched and what drawing the
/// chart cost. The meter takes the times it is given, so no test waits for a clock.
@Suite(.timeLimit(.minutes(1)))
struct FrameStatisticsTests {
    /// Whether `value` is `expected`, give or take the error of a division.
    private func approximately(_ value: Double?, _ expected: Double) -> Bool {
        value.map { abs($0 - expected) < 1e-6 } ?? false
    }

    // MARK: Frame rate

    @Test func theFirstSampleOnlySetsTheBaseline() {
        var meter = FrameRateMeter()

        let first = meter.sample(frames: 100, atNs: 1_000_000_000)
        let second = meter.sample(frames: 130, atNs: 1_500_000_000)

        #expect(first == nil)
        #expect(approximately(second, 60), "the half second after the first sample: \(String(describing: second))")
    }

    @Test func aSteadyRateIsReadFromEveryHalfSecond() {
        var meter = FrameRateMeter()
        var answers: [Double?] = []

        for step in 0...3 {
            answers.append(meter.sample(frames: 30 * step, atNs: Int64(step) * 500_000_000))
        }

        #expect(answers.count == 4)
        #expect(answers[0] == nil)
        for answer in answers.dropFirst() {
            #expect(approximately(answer, 60), "\(String(describing: answer))")
        }
    }

    @Test func theRateIsThatOfTheLastSpanAndNotTheAverageOfAllOfThem() {
        var meter = FrameRateMeter()
        _ = meter.sample(frames: 0, atNs: 0)

        let busy = meter.sample(frames: 30, atNs: 500_000_000)
        let slow = meter.sample(frames: 45, atNs: 1_000_000_000)

        #expect(approximately(busy, 60))
        #expect(approximately(slow, 30), "15 frames in the last half second: \(String(describing: slow))")
    }

    @Test func aSampleCloserThanFourHundredMillisecondsAnswersNothingAndKeepsTheBaseline() {
        var meter = FrameRateMeter()
        _ = meter.sample(frames: 0, atNs: 0)

        let tooSoon = meter.sample(frames: 10, atNs: 300_000_000)
        let later = meter.sample(frames: 30, atNs: 500_000_000)

        #expect(tooSoon == nil)
        // Measured from the first sample, 30 frames in half a second; from the short one it would be 100.
        #expect(approximately(later, 60), "\(String(describing: later))")
    }

    @Test func aSpanOfFourHundredMillisecondsIsEnoughAndOneNanosecondLessIsNot() {
        #expect(FrameRateMeter.minimumSpanNs == 400_000_000)
        var enough = FrameRateMeter()
        _ = enough.sample(frames: 0, atNs: 10)
        var notQuite = FrameRateMeter()
        _ = notQuite.sample(frames: 0, atNs: 10)

        let atTheBoundary = enough.sample(frames: 24, atNs: 400_000_010)
        let oneShort = notQuite.sample(frames: 24, atNs: 400_000_009)

        #expect(approximately(atTheBoundary, 60), "\(String(describing: atTheBoundary))")
        #expect(oneShort == nil)
    }

    @Test func aCounterThatWentDownRestartsTheBaseline() {
        var meter = FrameRateMeter()
        _ = meter.sample(frames: 100, atNs: 0)

        let afterTheReset = meter.sample(frames: 10, atNs: 500_000_000)
        let next = meter.sample(frames: 40, atNs: 1_000_000_000)

        #expect(afterTheReset == nil)
        // From the 10 frames at half a second, not from the 100 before the reset.
        #expect(approximately(next, 60), "\(String(describing: next))")
    }

    @Test func aSpanThatDoesNotGoForwardRestartsTheBaseline() {
        var standingStill = FrameRateMeter()
        _ = standingStill.sample(frames: 0, atNs: 1_000_000_000)
        let sameTime = standingStill.sample(frames: 5, atNs: 1_000_000_000)
        let afterSameTime = standingStill.sample(frames: 35, atNs: 1_500_000_000)

        var goingBack = FrameRateMeter()
        _ = goingBack.sample(frames: 0, atNs: 1_000_000_000)
        let earlier = goingBack.sample(frames: 5, atNs: 500_000_000)
        let afterEarlier = goingBack.sample(frames: 35, atNs: 1_000_000_000)

        #expect(sameTime == nil)
        #expect(approximately(afterSameTime, 60), "\(String(describing: afterSameTime))")
        #expect(earlier == nil)
        #expect(approximately(afterEarlier, 60), "\(String(describing: afterEarlier))")
    }

    @Test func aSpanTooBigToMeasureDoesNotTrapAndTheMeterGoesOnFromThere() {
        var backwards = FrameRateMeter()
        _ = backwards.sample(frames: 0, atNs: Int64.max)
        var forwards = FrameRateMeter()
        _ = forwards.sample(frames: 0, atNs: Int64.min)

        let wentBack = backwards.sample(frames: 1, atNs: Int64.min)
        let leapt = forwards.sample(frames: 1, atNs: Int64.max)
        // Each meter started over at the time it was given last, and measures from there.
        let afterBack = backwards.sample(frames: 31, atNs: Int64.min + 500_000_000)

        #expect(wentBack == nil)
        #expect(leapt == nil)
        #expect(approximately(afterBack, 60), "\(String(describing: afterBack))")
    }

    @Test func restartingMakesTheNextSampleABaselineAgain() {
        var meter = FrameRateMeter()
        _ = meter.sample(frames: 0, atNs: 0)
        let before = meter.sample(frames: 30, atNs: 500_000_000)
        meter.restart()

        let first = meter.sample(frames: 60, atNs: 1_000_000_000)
        let second = meter.sample(frames: 90, atNs: 1_500_000_000)

        #expect(approximately(before, 60))
        #expect(first == nil)
        #expect(approximately(second, 60), "\(String(describing: second))")
    }

    @Test func aSpanOfMoreThanTwoSecondsIsNotTakenForTheRateOfTheFramesInIt() {
        // While the app is away the display link is stopped, so a long span holds frames for only part of its time.
        #expect(FrameRateMeter.maximumSpanNs == 2_000_000_000)
        var atTheLimit = FrameRateMeter()
        _ = atTheLimit.sample(frames: 0, atNs: 0)
        var overTheLimit = FrameRateMeter()
        _ = overTheLimit.sample(frames: 0, atNs: 0)

        let still = atTheLimit.sample(frames: 120, atNs: 2_000_000_000)
        let tooLong = overTheLimit.sample(frames: 120, atNs: 2_000_000_001)
        let afterwards = overTheLimit.sample(frames: 150, atNs: 2_500_000_001)

        #expect(approximately(still, 60), "\(String(describing: still))")
        #expect(tooLong == nil)
        #expect(approximately(afterwards, 60), "measured again after the long one: \(String(describing: afterwards))")
    }

    @Test(arguments: fpsCases)
    func theRateIsWrittenWithOneDecimal(fps: Double?, text: String) {
        #expect(FrameRateMeter.text(for: fps) == text)
    }

    // MARK: Hitches

    @Test(arguments: hitchCases)
    func theHitchesAreCountedWithTheirShareOfTheFrames(hitches: Int, frames: Int, text: String) {
        #expect(HitchRateText.text(hitches: hitches, frames: frames) == text)
    }

    // MARK: Drawing

    @Test func theDrawTimeIsTheMedianAndTheSlowestHundredth() {
        let drawn = PercentileSummary(count: 10, p50Ns: 1_200_000, p95Ns: 2_000_000, p99Ns: 3_400_000, clamped: 0)

        #expect(DrawTimeText.text(for: drawn) == "p50 1.20 ms, p99 3.40 ms")
    }

    @Test func drawTimesThatHadToBeClampedAreCounted() {
        let drawn = PercentileSummary(count: 10, p50Ns: 1_200_000, p95Ns: 2_000_000, p99Ns: 3_400_000, clamped: 2_048)

        #expect(DrawTimeText.text(for: drawn) == "p50 1.20 ms, p99 3.40 ms, clamped 2,048")
    }

    @Test func noDrawTimeIsADash() {
        let none = PercentileSummary(count: 0, p50Ns: nil, p95Ns: nil, p99Ns: nil, clamped: 0)
        let unreadable = PercentileSummary(count: 1, p50Ns: nil, p95Ns: nil, p99Ns: nil, clamped: 0)

        #expect(DrawTimeText.text(for: none) == "\u{2014}")
        // A summary that has samples but no percentile cannot happen; it does not trap and claims no number.
        #expect(DrawTimeText.text(for: unreadable) == "p50 \u{2014}, p99 \u{2014}")
    }
}

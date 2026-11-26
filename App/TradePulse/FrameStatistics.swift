import TradeCore

/// A rate of frames worked out from two looks at the counter of the pump.
///
/// The meter takes the times it is given and reads no clock, so a test can say what time each look was made at. A look
/// that comes too soon after the one before it, or too long after it, answers nothing, because the rate of a span that
/// short or that long would not say how fast the display runs.
struct FrameRateMeter {
    /// The least span between two looks that makes a rate: 400 ms. Closer than that a whole frame more or less is a
    /// swing of several frames per second, and a look that is too close leaves the baseline where it was, so the next
    /// one measures from it.
    static let minimumSpanNs: Int64 = 400_000_000
    /// The most span between two looks that makes a rate: two seconds. While the app is away the display link is
    /// stopped, so a longer span holds frames for only part of its time, and dividing by all of it would be a rate
    /// that nothing ran at.
    static let maximumSpanNs: Int64 = 2_000_000_000

    /// The counter and the time of the look the next rate is measured from; nil before the first look.
    private var baseline: (frames: Int, atNs: Int64)?

    /// Looks at the counter, which says `frames` at `atNs` nanoseconds on a clock that only the caller reads. It
    /// answers the frames per second since the look before, or nil when there is none to answer:
    ///
    /// - The first look is the baseline, and so is the first one after `restart()`.
    /// - A counter that went down (the statistics were reset), a span that is not positive (a clock that stood still
    ///   or went back) and one too big to measure start the baseline over at this look.
    /// - A span under `minimumSpanNs` answers nothing and keeps the baseline.
    /// - A span over `maximumSpanNs` answers nothing and starts the baseline over at this look.
    mutating func sample(frames: Int, atNs: Int64) -> Double? {
        guard let previous = baseline else {
            baseline = (frames, atNs)
            return nil
        }
        let (span, overflow) = atNs.subtractingReportingOverflow(previous.atNs)
        guard frames >= previous.frames, !overflow, span > 0 else {
            baseline = (frames, atNs)
            return nil
        }
        guard span >= Self.minimumSpanNs else { return nil }
        baseline = (frames, atNs)
        guard span <= Self.maximumSpanNs else { return nil }
        return (Double(frames) - Double(previous.frames)) / (Double(span) / 1_000_000_000)
    }

    /// Forgets the baseline: the next look is a baseline again. The statistics were started over, and the counter
    /// reading 0 is no sign of that when it read 0 before.
    mutating func restart() {
        baseline = nil
    }

    /// The words for `rate`: one decimal and the unit, `59.8 fps`, or a dash for a rate nobody measured or one that
    /// cannot be a rate (not a number, negative, or too large to write).
    static func text(for rate: Double?) -> String {
        guard let rate, let number = OneDecimal.text(rate) else { return LabLabels.noData }
        return "\(number) fps"
    }
}

/// Writes a number with one decimal, rounded half up, from whole tenths: no locale and no floating-point format.
enum OneDecimal {
    /// The largest number that is written. Beyond it a number is not a rate or a multiplier of anything.
    private static let limit = 1e12

    /// `value` with one decimal, or nil for one that is not a number, is negative or is beyond `limit`.
    static func text(_ value: Double) -> String? {
        guard value.isFinite, value >= 0, value < limit else { return nil }
        let tenths = Int64((value * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }
}

/// The words for how many of the frames hitched.
enum HitchRateText {
    /// `3 hitches (0.4%)`: the count, with a comma between groups of three digits, and its share of `frames` with one
    /// decimal, rounded half up in whole numbers. One is `1 hitch`. A dash when no frame was counted, because there is
    /// no rate of nothing. A count above the frames (which cannot happen) is shown as all of them, and a negative one
    /// as none.
    static func text(hitches: Int, frames: Int) -> String {
        guard frames > 0 else { return LabLabels.noData }
        let count = max(hitches, 0)
        let total = Int128(frames)
        let tenths = (Int128(min(count, frames)) * 1_000 + total / 2) / total
        let noun = count == 1 ? "hitch" : "hitches"
        return "\(CountText.grouped(count)) \(noun) (\(tenths / 10).\(tenths % 10)%)"
    }
}

/// The words for what drawing the chart cost.
enum DrawTimeText {
    /// `p50 1.20 ms, p99 3.40 ms`, with `, clamped n` after them when some of the times were out of range and had to be
    /// clamped, and a dash while nothing was drawn.
    static func text(for summary: PercentileSummary) -> String {
        guard summary.count > 0 else { return LabLabels.noData }
        let median = LatencyFormat.string(ns: summary.p50Ns)
        let slowest = LatencyFormat.string(ns: summary.p99Ns)
        var text = "p50 \(median), p99 \(slowest)"
        if summary.clamped > 0 {
            text += ", clamped \(CountText.grouped(summary.clamped))"
        }
        return text
    }
}

/// Counts display frames and the ones that hitched, from the interval between consecutive frames.
///
/// Feed it one call per display-link callback with the time since the previous frame and the frame budget
/// (16.7 ms at 60 Hz). A frame is a hitch when its interval is more than 1.5 times the budget, so a frame that
/// is exactly 1.5 times the budget is not one. The UI shows `hitches` out of `frames`.
///
/// What counts as a frame:
/// - The first `record` call is ignored whatever it holds (it counts in neither `frames` nor `hitches`): the first
///   display-link callback has no previous frame, so it has no interval to measure. It is the first CALL, not the
///   first call with usable numbers, so a first call with a zero interval still uses it up, and the second call is
///   a measured frame.
/// - After that, a call with a positive interval and a positive budget is a frame. A call with a zero or negative
///   interval or budget (a clock that did not advance or stepped back, a display with no refresh rate yet) is
///   ignored entirely and counts as nothing.
///
/// The test is `interval * 2 > expected * 3` in 128-bit integers, so no pair of `Int64` can overflow it and no
/// floating-point rounding can tip an exact 1.5 times. The two counters stop at `Int.max` instead of trapping.
public struct HitchDetector: Sendable {
    /// Frames measured so far, hitches included. The ignored first call is not one.
    public private(set) var frames = 0

    /// Frames whose interval was more than 1.5 times the budget.
    public private(set) var hitches = 0

    /// Whether the first call, which is never measured, has been made.
    private var sawFirstCall = false

    public init() {}

    /// A detector that has already seen its first call and holds the given counts, so a test can put the counters next
    /// to their limit without making 2^63 calls.
    init(frames: Int, hitches: Int) {
        self.frames = frames
        self.hitches = hitches
        sawFirstCall = true
    }

    /// Records one frame: `frameIntervalNs` since the previous frame, against a budget of `expectedNs`.
    public mutating func record(frameIntervalNs: Int64, expectedNs: Int64) {
        guard sawFirstCall else {
            sawFirstCall = true
            return
        }
        guard frameIntervalNs > 0, expectedNs > 0 else {
            return
        }
        frames = Self.incremented(frames)
        if Int128(frameIntervalNs) * 2 > Int128(expectedNs) * 3 {
            hitches = Self.incremented(hitches)
        }
    }

    /// `count + 1`, or `count` itself once it is `Int.max`.
    private static func incremented(_ count: Int) -> Int {
        count == Int.max ? count : count + 1
    }
}

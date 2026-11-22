/// How long to wait before the next reconnect attempt: exponential backoff with a cap and jitter.
///
/// The delay for attempt `n` (0 is the first retry) is `min(base * 2^n, cap)`, scaled by `0.5 + 0.5 * jitter`. So
/// with the defaults and a jitter of 1.0 the waits are 250 ms, 500 ms, 1 s, 2 s, 4 s, 8 s and then 10 s for ever, and
/// a jitter of 0.0 halves each of them. The caller supplies the jitter (a random number in 0...1), so this type is
/// pure and its answers are repeatable.
///
/// Everything is worked out in whole integer nanoseconds (in 128 bits), so the delays above are exact `Duration`s
/// and no attempt number can overflow:
/// - The doubling stops once it reaches the cap, so attempt 1000, or `Int.max`, is the cap. An attempt below 0 counts
///   as attempt 0.
/// - The jitter is clamped into 0...1 and counts to the millionth. A NaN jitter counts as 1.0, the full delay: not
///   knowing how long to wait, wait the whole time.
/// - The result is rounded down to a whole nanosecond, and any part of `base` or `cap` below a nanosecond is
///   dropped.
/// - A cap below the base wins from the first attempt: the delay never exceeds the cap.
/// - A `base` or `cap` of zero or less (or under 1 ns) leaves nothing to wait, so the delay is `.zero`. It is never
///   negative and never traps.
public struct ReconnectBackoff: Sendable {
    /// `base` and `cap` in whole nanoseconds.
    private let baseNs: Int128
    private let capNs: Int128

    public init(base: Duration = .milliseconds(250), cap: Duration = .seconds(10)) {
        baseNs = Self.nanoseconds(of: base)
        capNs = Self.nanoseconds(of: cap)
    }

    /// The wait before retry number `attempt` (0 for the first), with `jitter` in 0...1 (1.0 is the full delay,
    /// 0.0 half of it).
    public func delay(attempt: Int, jitter: Double) -> Duration {
        guard baseNs > 0, capNs > 0 else {
            return .zero
        }
        // Double the base per attempt, but never past the cap. The loop ends after at most about 100 doublings (the
        // base is at least 1 ns and the cap under 2^94 ns), and `nanos < capNs` keeps each doubling inside 128 bits.
        var nanos = baseNs
        var doublings = max(attempt, 0)
        while doublings > 0, nanos < capNs {
            nanos *= 2
            doublings -= 1
        }
        nanos = min(nanos, capNs)

        let fraction = jitter.isNaN ? 1.0 : min(max(jitter, 0), 1)
        let millionths = Int128((fraction * 1_000_000).rounded())
        // nanos * (0.5 + 0.5 * jitter), as nanos * (1_000_000 + millionths) / 2_000_000 in integers.
        return Self.duration(nanoseconds: nanos * (1_000_000 + millionths) / 2_000_000)
    }

    /// The whole nanoseconds in `duration`; the part below a nanosecond is dropped. A `Duration` is a count of
    /// seconds and attoseconds (1 ns = 10^9 as), both of the sign of the duration.
    private static func nanoseconds(of duration: Duration) -> Int128 {
        let (seconds, attoseconds) = duration.components
        return Int128(seconds) * 1_000_000_000 + Int128(attoseconds) / 1_000_000_000
    }

    /// The `Duration` of a count of nanoseconds that is not negative and came from a `Duration`, so its seconds fit.
    private static func duration(nanoseconds: Int128) -> Duration {
        Duration(
            secondsComponent: Int64(nanoseconds / 1_000_000_000),
            attosecondsComponent: Int64(nanoseconds % 1_000_000_000) * 1_000_000_000
        )
    }
}

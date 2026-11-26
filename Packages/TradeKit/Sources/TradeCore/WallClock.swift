import Darwin

/// The clock every latency timestamp is read from: the server stamps its frames with it and the clients stamp their
/// sends and receives with it, so one number means the same thing on both sides.
///
/// It is the wall clock (`CLOCK_REALTIME`), not a monotonic one, because a timestamp has to be comparable across
/// processes (the server's and the app's). The price is that a wall clock can step (a time sync) between two
/// readings; that is why `ClockOffsetEstimator` measures the offset between the two sides and why a negative latency
/// is clamped instead of trusted (`LatencyHistogram`).
public enum WallClock: Sendable {
    /// Now, in nanoseconds since the Unix epoch (1970-01-01T00:00:00Z).
    ///
    /// A plain function, with no `async`, `throws` or actor isolation, so `WallClock.nowNs` itself can be handed to a
    /// client as its clock, a `@Sendable () -> Int64`. The `UInt64` the system returns is clamped into `Int64` (which
    /// holds until the year 2262); the system returns 0 if the clock cannot be read, which `CLOCK_REALTIME` does not
    /// do in practice, and 0 is what this returns then.
    public static func nowNs() -> Int64 {
        Int64(clamping: clock_gettime_nsec_np(CLOCK_REALTIME))
    }
}

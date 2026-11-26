/// Estimates how far the server's clock is ahead of the client's, from request/response pings.
///
/// Each sample is a client send time, the server's timestamp and the client receive time (all wall-clock ns).
/// The server is assumed to have stamped halfway through the round trip, so for one sample
///
///     rtt    = clientRecvNs - clientSendNs
///     offset = serverNs - (clientSendNs + rtt / 2)
///
/// (the integer `rtt / 2` of an odd round trip rounds down, so the midpoint is half a nanosecond early at most). That
/// assumption is exact only on a symmetric path; on an uneven one the offset is wrong by up to half the round trip.
/// So the reported offset is the one from the sample with the SMALLEST round trip (there is the least room for
/// unevenness), and an equal round trip goes to the newer sample, the fresher reading of a clock that drifts. There
/// is no window: the best sample ever seen stays the best, and it takes a faster one to replace it.
///
/// A sample with a negative round trip (the client clock stepped backwards between send and receive) says nothing
/// true and is ignored. Every difference is formed in 128 bits, so no `Int64` input can overflow, and what is read
/// back is clamped to the `Int64` range. Subtract `offsetNs` from a server timestamp to get client time.
public struct ClockOffsetEstimator: Sendable {
    /// The best sample so far, kept at full 128-bit width so that two samples are compared by their true widths
    /// even when the clamped values reported would be equal.
    private struct Sample: Sendable {
        let rttNs: Int128
        let offsetNs: Int128
    }

    private var best: Sample?

    public init() {}

    /// Adds one ping. It becomes the reported sample if its round trip is no longer than the best so far.
    public mutating func add(clientSendNs: Int64, serverNs: Int64, clientRecvNs: Int64) {
        let rtt = Int128(clientRecvNs) - Int128(clientSendNs)
        guard rtt >= 0 else {
            return
        }
        if let best, rtt > best.rttNs {
            return
        }
        // The midpoint lies between send and receive, so it fits in an Int64; the difference below does not have to.
        let midpoint = Int128(clientSendNs) + rtt / 2
        best = Sample(rttNs: rtt, offsetNs: Int128(serverNs) - midpoint)
    }

    /// Server clock minus client clock, in ns, from the sample with the smallest round trip. 0 until a sample has
    /// been accepted. Clamped to the `Int64` range.
    public var offsetNs: Int64 {
        best.map { Int64(clamping: $0.offsetNs) } ?? 0
    }

    /// The smallest round trip accepted so far, in ns (clamped to `Int64.max`), or nil before any sample.
    public var bestRttNs: Int64? {
        best.map { Int64(clamping: $0.rttNs) }
    }
}

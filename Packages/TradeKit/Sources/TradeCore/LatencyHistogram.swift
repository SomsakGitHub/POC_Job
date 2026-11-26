/// A fixed-size histogram of latency samples in nanoseconds: record samples, read percentiles back.
///
/// Memory is fixed. The bucket counters (934 of them, about 7 KB) are allocated once by `init()` and `record` only
/// increments one, so memory depends on the layout and never on how many samples arrive. The counters are `Int`, which
/// cannot overflow in practice (it takes 2^63 samples).
///
/// Layout, log-linear as in an HdrHistogram: each value below 64 ns has a bucket of its own; from 64 ns up, every
/// power of two (64...127, 128...255, ...) is split into 32 equal buckets. Bucket width doubles with each octave and
/// is never more than 1/32 (3.125%) of the bucket's lower edge, well inside 5% for the buckets between 1 us and 10 s.
/// Samples under 1 us (0...999 ns) are legitimate and not clamped: they get the same buckets.
///
/// Range: 0 to 10 s. A negative sample is recorded as 0 and one over 10 s as 10 s. Both still count in `count`, and
/// both are also counted in `clampedCount`, so a clock-skew artefact stays visible and can never make a percentile
/// negative or beyond 10 s. Every `Int64`, including `.min` and `.max`, is a valid sample.
public struct LatencyHistogram: Sendable {
    /// The largest latency kept as measured: 10 s.
    private static let ceilingNs: Int64 = 10_000_000_000

    /// Each octave above 63 ns is split into 2^5 = 32 buckets.
    private static let subBucketBits = 5
    private static let subBucketCount = 1 << subBucketBits

    /// Values below 64 get a bucket each: the first octave split into buckets 1 ns wide.
    private static let exactLimit = 2 * subBucketCount

    /// Buckets from 0 ns to the one holding the ceiling.
    private static let bucketsInLayout = bucketIndex(of: ceilingNs) + 1

    private var buckets = [Int](repeating: 0, count: LatencyHistogram.bucketsInLayout)

    /// Samples recorded, the clamped ones included.
    public private(set) var count = 0

    /// Samples that were out of range (negative, or over 10 s) and so were clamped.
    public private(set) var clampedCount = 0

    public init() {}

    /// The number of buckets. It is fixed when the histogram is made; a test pins that recording never changes it.
    var bucketCount: Int {
        buckets.count
    }

    /// Records one latency in nanoseconds. A negative sample is recorded as 0 and one over 10 s as 10 s; either one is
    /// also counted in `clampedCount`.
    public mutating func record(nanos: Int64) {
        let sample: Int64
        if nanos < 0 {
            sample = 0
            clampedCount += 1
        } else if nanos > Self.ceilingNs {
            sample = Self.ceilingNs
            clampedCount += 1
        } else {
            sample = nanos
        }
        buckets[Self.bucketIndex(of: sample)] += 1
        count += 1
    }

    /// The p-th percentile in nanoseconds (`p` is a fraction: 0.5 is the median, 0.99 the 99th percentile), or nil
    /// when nothing has been recorded or `p` is NaN.
    ///
    /// Nearest rank: the smallest sample with at least a fraction `p` of all the samples at or below it. It picks
    /// one of the recorded samples (never an interpolation between two), and the result never decreases as `p`
    /// grows. A `p` outside 0...1 is clamped to the nearest end, so 0 (and anything below) is the minimum and 1 (and
    /// anything above, infinity included) the maximum.
    ///
    /// The rank, ceil(p * count), is worked out in integers on `p` rounded to the nearest millionth: in `Double`,
    /// 0.14 * 50 is 7.000000000000001, whose ceiling puts the 14th percentile of 50 samples at the 8th instead of the
    /// 7th.
    ///
    /// The reading is the LAST nanosecond of the bucket holding that sample (the top bucket reads as exactly 10 s): a
    /// latency is never reported as better than it was, and it is at most 1/32 too high, and exact below 64 ns.
    public func percentile(_ p: Double) -> Int64? {
        guard count > 0, !p.isNaN else {
            return nil
        }
        let millionths = Int128((min(max(p, 0), 1) * 1_000_000).rounded())
        let rank = max(1, (millionths * Int128(count) + 999_999) / 1_000_000)
        var seen: Int128 = 0
        for (index, inBucket) in buckets.enumerated() {
            seen += Int128(inBucket)
            if seen >= rank {
                return Self.upperEdge(ofBucket: index)
            }
        }
        // Not reachable: the buckets add up to `count`, and `rank` is at most `count`.
        return Self.ceilingNs
    }

    /// The count, the 50th, 95th and 99th percentiles and the clamped count, as one value. Percentiles are nil when
    /// the histogram is empty.
    public func summary() -> PercentileSummary {
        PercentileSummary(
            count: count,
            p50Ns: percentile(0.5),
            p95Ns: percentile(0.95),
            p99Ns: percentile(0.99),
            clamped: clampedCount
        )
    }

    /// The bucket for a latency in `0...ceilingNs`.
    private static func bucketIndex(of nanos: Int64) -> Int {
        let value = UInt64(nanos)
        if value < UInt64(exactLimit) {
            return Int(value)
        }
        // The octave is the position of the highest set bit (6 or more here); the 5 bits under it pick the bucket in
        // the octave, and the buckets of an octave are 2^(position - 5) wide.
        let topBit = UInt64.bitWidth - 1 - value.leadingZeroBitCount
        let subBucket = Int(value >> (topBit - subBucketBits)) - subBucketCount
        return exactLimit + (topBit - (subBucketBits + 1)) * subBucketCount + subBucket
    }

    /// The last nanosecond held by bucket `index`; for the top bucket, the ceiling itself.
    private static func upperEdge(ofBucket index: Int) -> Int64 {
        guard index >= exactLimit else {
            return Int64(index)
        }
        let position = index - exactLimit
        let shift = position / subBucketCount + 1
        let lowerEdge = Int64(subBucketCount + position % subBucketCount) << shift
        return min(lowerEdge + (Int64(1) << shift) - 1, ceilingNs)
    }
}

/// A set of percentiles of one metric, ready to show or to publish: how many samples there were, the 50th, 95th and
/// 99th percentiles in nanoseconds, and how many samples were clamped into range.
///
/// A percentile is nil when there are no samples, never zero, so the UI can show the no-data dash instead of a
/// made-up number (`LatencyFormat` does that for nil). In JSON an absent percentile is left out rather than written
/// as null. Build one from a histogram with `LatencyHistogram.summary()`.
public struct PercentileSummary: Sendable, Codable, Equatable {
    /// Samples recorded, the clamped ones included.
    public let count: Int
    public let p50Ns: Int64?
    public let p95Ns: Int64?
    public let p99Ns: Int64?
    /// Samples that were out of range (negative or over 10 s) and so were clamped.
    public let clamped: Int

    public init(count: Int, p50Ns: Int64?, p95Ns: Int64?, p99Ns: Int64?, clamped: Int) {
        self.count = count
        self.p50Ns = p50Ns
        self.p95Ns = p95Ns
        self.p99Ns = p99Ns
        self.clamped = clamped
    }
}

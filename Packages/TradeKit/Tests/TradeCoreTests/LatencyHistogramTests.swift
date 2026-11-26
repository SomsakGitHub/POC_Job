import Foundation
import Testing
// `@testable` only for `bucketCount`, which pins that the storage never grows.
@testable import TradeCore

private let microsecond: Int64 = 1_000
private let tenSeconds: Int64 = 10_000_000_000

private func recorded(_ samples: some Sequence<Int64>) -> LatencyHistogram {
    var histogram = LatencyHistogram()
    for sample in samples {
        histogram.record(nanos: sample)
    }
    return histogram
}

/// True when `value` is within 5% of `expected`, in integers: |value - expected| * 100 <= expected * 5.
private func isWithinFivePercent(_ value: Int64?, of expected: Int64) -> Bool {
    guard let value else {
        return false
    }
    return (Int128(value) - Int128(expected)).magnitude * 100 <= UInt128(expected) * 5
}

struct LatencyHistogramTests {
    // MARK: The reference cases

    @Test func percentilesOfOneToAThousandMicrosecondsAreWithinFivePercent() {
        let histogram = recorded((1...1000).map { Int64($0) * microsecond })
        #expect(histogram.count == 1000)
        #expect(histogram.clampedCount == 0)
        #expect(isWithinFivePercent(histogram.percentile(0.5), of: 500 * microsecond))
        #expect(isWithinFivePercent(histogram.percentile(0.99), of: 990 * microsecond))
    }

    @Test func anEmptyHistogramHasNoPercentiles() {
        let histogram = LatencyHistogram()
        #expect(histogram.count == 0)
        #expect(histogram.clampedCount == 0)
        #expect(histogram.percentile(0.5) == nil)
        #expect(histogram.percentile(0) == nil)
        #expect(histogram.percentile(1) == nil)
        #expect(histogram.percentile(.nan) == nil)
    }

    /// A million samples leave the bucket storage exactly as big as an empty histogram's: memory depends on the
    /// layout, never on how many samples arrive.
    @Test func aMillionRecordsDoNotGrowTheStorage() {
        var histogram = LatencyHistogram()
        let bucketsWhenEmpty = histogram.bucketCount
        for i in 0..<1_000_000 {
            histogram.record(nanos: Int64(1 + i % 20_000) * microsecond)
        }
        #expect(histogram.count == 1_000_000)
        #expect(histogram.clampedCount == 0)
        #expect(histogram.bucketCount == bucketsWhenEmpty)
        // The storage is all the histogram has, and it still answers: 1 us ... 20 ms evenly, so the median is 10 ms.
        #expect(isWithinFivePercent(histogram.percentile(0.5), of: 10_000 * microsecond))
    }

    // MARK: Clamping

    /// Clock skew can produce a negative latency and a stuck clock a huge one. Both are kept (the sample still
    /// counts) but pulled into range, and `clampedCount` says how many were: a negative becomes 0, anything over
    /// 10 s becomes 10 s. Neither can ever make a percentile negative or beyond 10 s.
    @Test(arguments: [
        (-5, 0),
        (-1, 0),
        (Int64.min, 0),
        (tenSeconds + 1, tenSeconds),
        (60_000_000_000, tenSeconds),
        (Int64.max, tenSeconds),
    ] as [(Int64, Int64)])
    func anOutOfRangeSampleIsClampedAndStillCounted(sample: Int64, reported: Int64) {
        var histogram = LatencyHistogram()
        histogram.record(nanos: sample)
        #expect(histogram.count == 1)
        #expect(histogram.clampedCount == 1)
        #expect(histogram.percentile(0.5) == reported)
    }

    /// The range is closed at both ends: 0 and exactly 10 s are real measurements, not clamped.
    @Test(arguments: [0, 1, 63, 64, 999, 1_000, tenSeconds - 1, tenSeconds] as [Int64])
    func aSampleInRangeIsNotClamped(sample: Int64) {
        var histogram = LatencyHistogram()
        histogram.record(nanos: sample)
        #expect(histogram.count == 1)
        #expect(histogram.clampedCount == 0)
    }

    /// A 60 s sample lands in the top bucket, the same one a 10 s sample does, so it reads back as 10 s.
    @Test func anOversizedSampleLandsInTheTopBucket() {
        let oversized = recorded([60_000_000_000])
        let exactlyTen = recorded([tenSeconds])
        #expect(oversized.percentile(1) == exactlyTen.percentile(1))
        #expect(oversized.clampedCount == 1)
        #expect(exactlyTen.clampedCount == 0)
    }

    @Test func anOutlierMovesTheTopPercentileButNotTheMedian() {
        var histogram = recorded(Array(repeating: 1_000_000, count: 999))
        histogram.record(nanos: 60_000_000_000)
        #expect(histogram.count == 1000)
        #expect(histogram.clampedCount == 1)
        #expect(isWithinFivePercent(histogram.percentile(0.5), of: 1_000_000))
        #expect(isWithinFivePercent(histogram.percentile(0.99), of: 1_000_000))
        #expect(histogram.percentile(1) == tenSeconds)
    }

    // MARK: Sub-microsecond samples

    /// Below 1 us is legitimate (a fast local call): it is not clamped, and it keeps its resolution. Every value
    /// below 64 ns has a bucket of its own, so 0 reads back as exactly 0 (this is also what a clamped negative
    /// reads as), and above that the reading is the last nanosecond of the bucket the sample fell in, at most
    /// 1/32 higher.
    @Test func sampleBelowAMicrosecondIsKeptNotClamped() {
        let histogram = recorded(0...999)
        #expect(histogram.count == 1000)
        #expect(histogram.clampedCount == 0)
        #expect(histogram.percentile(0) == 0)
        #expect(histogram.percentile(1) == 1007)
    }

    // MARK: What a reading is

    /// A percentile reads back as the LAST nanosecond of the bucket holding the sample (the top bucket as
    /// exactly 10 s), so a measured latency is never reported as better than it was, and it is at most 1/32
    /// too high. The buckets are 1 ns wide below 64 ns and double in width at every power of two from there.
    @Test(arguments: [
        (0, 0),
        (1, 1),
        (63, 63),                 // below 64 ns every value has its own bucket
        (64, 65),                 // 64...127 ns: buckets 2 ns wide
        (65, 65),
        (66, 67),
        (500, 503),               // 256...511 ns: 8 ns wide, this one is 496...503
        (999, 1007),              // 512...1023 ns: 16 ns wide, this one is 992...1007
        (1_000, 1007),
        (1_000_000, 1_015_807),   // 524_288...1_048_575 ns: 16_384 ns wide, this one is 999_424...1_015_807
        (tenSeconds, tenSeconds), // the top bucket reads back as exactly 10 s, not its own last nanosecond
    ] as [(Int64, Int64)])
    func aLoneSampleReadsBackAsTheLastNanosecondOfItsBucket(sample: Int64, reported: Int64) {
        let histogram = recorded([sample])
        #expect(histogram.percentile(0) == reported)
        #expect(histogram.percentile(0.5) == reported)
        #expect(histogram.percentile(1) == reported)
    }

    /// The accuracy promise for the whole range: for every sample from 0 to 10 s (every nanosecond up to 5 us,
    /// then a sweep 0.1% apart, and both sides of every power of two, where the bucket width changes) the reading is
    /// never below the sample, never more than 5% above it and in fact less than 1/32 above
    /// it, and exact below 64 ns.
    @Test func everySampleReadsBackWithinItsBucketWidth() {
        var samples: [Int64] = Array(0...5_000)
        var next: Int64 = 5_000
        while next < tenSeconds {
            next += next / 997 + 1
            samples.append(min(next, tenSeconds))
        }
        for power in 6...33 {
            let edge = Int64(1) << power
            samples += [edge - 1, edge, edge + 1]
        }
        samples += [tenSeconds - 1, tenSeconds]

        var failures: [Int64] = []
        for sample in samples {
            guard let reported = recorded([sample]).percentile(1) else {
                failures.append(sample)
                continue
            }
            let neverBelow = reported >= sample
            let withinFivePercent = reported * 100 <= sample * 105
            let withinBucketWidth = sample < 64 ? reported == sample : (reported - sample) * 32 < sample
            if !(neverBelow && withinFivePercent && withinBucketWidth) {
                failures.append(sample)
            }
        }
        #expect(failures.isEmpty, "samples read back out of bounds: \(failures.prefix(5))")
    }

    // MARK: Nearest rank

    /// Nearest rank: the p-th percentile is the smallest sample with at least p of all the samples at or below it,
    /// so it is always one of the recorded samples, never an interpolation. For 1...50 ns, p = 0.03 is rank
    /// ceil(1.5) = 2 and p = 0.51 is rank ceil(25.5) = 26. A rank below 1 is raised to 1, so p = 0 is the minimum.
    @Test(arguments: [
        (0, 1),
        (0.01, 1),
        (0.02, 1),
        (0.03, 2),
        (0.5, 25),
        (0.51, 26),
        (0.98, 49),
        (0.99, 50),
        (1, 50),
    ] as [(Double, Int64)])
    func percentileIsTheNearestRankSample(p: Double, expected: Int64) {
        let histogram = recorded((1...50).map { Int64($0) })
        #expect(histogram.percentile(p) == expected)
    }

    @Test func theMedianOfTwoSamplesIsTheLowerOne() {
        let histogram = recorded([10, 20])
        #expect(histogram.percentile(0.5) == 10)
        #expect(histogram.percentile(0.51) == 20)
    }

    /// In Double, 0.14 * 50 is 7.000000000000001, whose ceiling is 8: the naive rank is one too high. The rank is
    /// worked out in integers from p rounded to the nearest millionth, so 14% of 50 samples is the 7th, exactly.
    @Test func rankIsExactWhereDoubleArithmeticRoundsUp() {
        #expect(recorded((1...50).map { Int64($0) }).percentile(0.14) == 7)
        #expect(recorded((1...25).map { Int64($0) }).percentile(0.28) == 7)
    }

    /// Every whole percent of every sample count from 1 to 63 (1...63 ns each have a bucket of their own, so the
    /// reading is the rank itself) agrees with exact integer arithmetic. Naive Double ceilings get 290 of the
    /// 202,000 cases up to 2000 samples wrong.
    @Test func everyWholePercentIsTheExactNearestRank() {
        var mismatches: [String] = []
        for count in 1...63 {
            let histogram = recorded((1...count).map { Int64($0) })
            for percent in 0...100 {
                let rank = max(1, (percent * count + 99) / 100)
                let reported = histogram.percentile(Double(percent) / 100)
                if reported != Int64(rank) {
                    mismatches.append("\(count) samples, \(percent)%: got \(reported ?? -1), want \(rank)")
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
    }

    @Test func percentileNeverDecreasesAsPGrows() {
        let histogram = recorded((1...300).map { Int64($0 * $0) * 100 })
        var previous: Int64 = -1
        var decreases = 0
        for step in 0...1000 {
            let reported = histogram.percentile(Double(step) / 1000)
            if let reported, reported >= previous {
                previous = reported
            } else {
                decreases += 1
            }
        }
        #expect(decreases == 0)
    }

    // MARK: Out-of-range p

    /// p is a fraction. Outside 0...1 it is clamped to the nearest end (so p = 2 is the maximum and p = -1 the
    /// minimum, whatever the size of the mistake), and a NaN p has no meaning, so it has no answer: nil, for an
    /// empty and a populated histogram alike.
    @Test(arguments: [-1, -0.0, -1e300, -Double.infinity, -Double.leastNonzeroMagnitude] as [Double])
    func aPBelowZeroIsTheMinimum(p: Double) {
        #expect(recorded((1...50).map { Int64($0) }).percentile(p) == 1)
    }

    @Test(arguments: [1.5, 2, 1e300, Double.infinity, Double.greatestFiniteMagnitude] as [Double])
    func aPAboveOneIsTheMaximum(p: Double) {
        #expect(recorded((1...50).map { Int64($0) }).percentile(p) == 50)
    }

    @Test func aNaNPHasNoAnswer() {
        #expect(recorded([1_000, 2_000]).percentile(.nan) == nil)
        #expect(LatencyHistogram().percentile(.nan) == nil)
    }

    /// p only counts to the millionth, so a p below half a millionth is the same rank 1 as 0.
    @Test func aTinyPositivePIsTheMinimum() {
        #expect(recorded((1...50).map { Int64($0) }).percentile(1e-9) == 1)
    }
}

private let emptySummary = PercentileSummary(count: 0, p50Ns: nil, p95Ns: nil, p99Ns: nil, clamped: 0)

/// A summary with every field set; a test changes one field to see that it matters.
private func summary(
    count: Int = 80_000,
    p50: Int64? = 1_015_807,
    p95: Int64? = 5_000_000,
    p99: Int64? = 10_000_000_000,
    clamped: Int = 3
) -> PercentileSummary {
    PercentileSummary(count: count, p50Ns: p50, p95Ns: p95, p99Ns: p99, clamped: clamped)
}

struct PercentileSummaryTests {
    @Test func summaryOfAnEmptyHistogramHasNoPercentiles() {
        #expect(LatencyHistogram().summary() == emptySummary)
    }

    /// The summary is the histogram's own count, its three percentiles and its clamped count, so anything that
    /// holds a histogram (the recorder, the app's frame meter) builds the same numbers the same way.
    @Test func summaryReportsCountThePercentilesAndClamped() {
        var histogram = recorded((1...1000).map { Int64($0) * microsecond })
        histogram.record(nanos: -1)
        histogram.record(nanos: 60_000_000_000)
        let summary = histogram.summary()
        #expect(summary.count == 1002)
        #expect(summary.clamped == 2)
        #expect(summary.p50Ns == histogram.percentile(0.5))
        #expect(summary.p95Ns == histogram.percentile(0.95))
        #expect(summary.p99Ns == histogram.percentile(0.99))
        #expect(isWithinFivePercent(summary.p50Ns, of: 500 * microsecond))
        #expect(isWithinFivePercent(summary.p95Ns, of: 950 * microsecond))
        #expect(isWithinFivePercent(summary.p99Ns, of: 990 * microsecond))
    }

    /// The public init takes the fields by the labels the properties have.
    @Test func initKeepsEachFieldWhereItsLabelSays() {
        let made = PercentileSummary(count: 7, p50Ns: 1, p95Ns: 2, p99Ns: 3, clamped: 4)
        #expect(made.count == 7)
        #expect(made.p50Ns == 1)
        #expect(made.p95Ns == 2)
        #expect(made.p99Ns == 3)
        #expect(made.clamped == 4)
    }

    @Test func summariesAreEqualOnlyWhenEveryFieldIs() {
        #expect(summary() == summary())
        #expect(summary() != summary(count: 80_001))
        #expect(summary() != summary(p50: 1_015_808))
        #expect(summary() != summary(p95: 5_000_001))
        #expect(summary() != summary(p99: nil))
        #expect(summary() != summary(clamped: 4))
    }

    // MARK: Codable (JSONEncoder is used here only: the library itself stays free of Foundation)

    @Test(arguments: [summary(), emptySummary, summary(p50: nil, p95: 5_000_000, p99: nil)])
    func summarySurvivesAJSONRoundTrip(original: PercentileSummary) throws {
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(PercentileSummary.self, from: data) == original)
    }

    /// A percentile that does not exist is left out of the JSON rather than written as null, so a reader looks
    /// for the key (an empty run has no `p50Ns`, not a `p50Ns` of zero).
    @Test func anAbsentPercentileIsLeftOutOfTheJSON() throws {
        let data = try JSONEncoder().encode(emptySummary)
        let keys = try JSONDecoder().decode([String: Int].self, from: data)
        #expect(keys == ["count": 0, "clamped": 0])
    }
}

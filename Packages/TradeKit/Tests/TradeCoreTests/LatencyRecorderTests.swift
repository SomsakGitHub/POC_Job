import Foundation
import Testing
import TradeCore

private let microsecond: Int64 = 1_000

struct LatencyRecorderTests {
    @Test func everyMetricStartsEmpty() {
        let recorder = LatencyRecorder()
        for metric in LatencyMetric.allCases {
            let summary = recorder.summary(metric)
            #expect(summary.count == 0)
            #expect(summary.p50Ns == nil)
            #expect(summary.p95Ns == nil)
            #expect(summary.p99Ns == nil)
            #expect(summary.clamped == 0)
        }
    }

    /// The snapshot always has an entry for each of the six metrics, one that was never recorded included
    /// (empty), so a screen can show all six rows without checking which exist.
    @Test func snapshotHasAllSixMetricsEvenWhenNothingWasRecorded() {
        let recorder = LatencyRecorder()
        let empty = recorder.snapshot()
        #expect(empty.count == 6)
        #expect(Set(empty.keys) == Set(LatencyMetric.allCases))
        #expect(empty.values.allSatisfy { $0.count == 0 })

        recorder.record(.orderSubmitToAck, nanos: 3 * microsecond)
        let one = recorder.snapshot()
        #expect(one.count == 6)
        #expect(one[.orderSubmitToAck]?.count == 1)
        #expect(one[.tickToApp]?.count == 0)
    }

    @Test func eachMetricKeepsItsOwnSamples() {
        let recorder = LatencyRecorder()
        for _ in 0..<3 {
            recorder.record(.orderSubmitToAck, nanos: 2_000_000)
        }
        recorder.record(.tickToRender, nanos: 10_000_000)
        #expect(recorder.summary(.orderSubmitToAck).count == 3)
        #expect(recorder.summary(.tickToRender).count == 1)
        for metric in LatencyMetric.allCases where metric != .orderSubmitToAck && metric != .tickToRender {
            #expect(recorder.summary(metric).count == 0)
        }
        #expect(recorder.snapshot()[.tickToRender] == recorder.summary(.tickToRender))
    }

    /// The recorder's summary is the histogram's own summary: the same numbers however they are asked for.
    @Test func summaryIsTheHistogramSummaryOfTheSameSamples() {
        let recorder = LatencyRecorder()
        var histogram = LatencyHistogram()
        for i in 1...1000 {
            recorder.record(.tickToApp, nanos: Int64(i) * microsecond)
            histogram.record(nanos: Int64(i) * microsecond)
        }
        #expect(recorder.summary(.tickToApp) == histogram.summary())
        #expect(recorder.summary(.tickToApp).count == 1000)
    }

    /// A sample from a skewed clock must not leak into the numbers as a negative or an absurd latency: it is
    /// clamped (and counted as clamped) by the histogram underneath.
    @Test func clockSkewSamplesAreClampedNotPassedThrough() {
        let recorder = LatencyRecorder()
        recorder.record(.tickToApp, nanos: -2_500_000)
        recorder.record(.tickToApp, nanos: .max)
        let summary = recorder.summary(.tickToApp)
        #expect(summary.count == 2)
        #expect(summary.clamped == 2)
        #expect(summary.p50Ns == 0)
        #expect(summary.p99Ns == 10_000_000_000)
    }

    @Test func resetEmptiesEveryMetric() {
        let recorder = LatencyRecorder()
        for metric in LatencyMetric.allCases {
            recorder.record(metric, nanos: 5 * microsecond)
            recorder.record(metric, nanos: -1)
        }
        #expect(recorder.summary(.tickToRender).count == 2)

        recorder.reset()
        for metric in LatencyMetric.allCases {
            let summary = recorder.summary(metric)
            #expect(summary.count == 0)
            #expect(summary.clamped == 0)
            #expect(summary.p50Ns == nil)
        }
        let snapshot = recorder.snapshot()
        #expect(snapshot.count == 6)
        #expect(snapshot.values.allSatisfy { $0.count == 0 && $0.p99Ns == nil })
    }

    /// After a reset nothing of the earlier samples is left: the 9 ms one does not show in the 99th percentile.
    @Test func recordingAfterAResetStartsFromNothing() {
        let recorder = LatencyRecorder()
        recorder.record(.tickToApplied, nanos: 9_000_000)
        recorder.reset()
        recorder.record(.tickToApplied, nanos: 1_000_000)
        let summary = recorder.summary(.tickToApplied)
        #expect(summary.count == 1)
        #expect(summary.p99Ns == 1_015_807)
    }

    // MARK: Many tasks at once

    /// Eight tasks record 10,000 samples each into the same metric; none may be lost. The count is exact
    /// whatever the interleaving, so the test cannot flake, and a missing lock would show as a short count.
    @Test func concurrentRecordsAreAllCounted() async {
        let recorder = LatencyRecorder()
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for i in 0..<10_000 {
                        recorder.record(.tickToRender, nanos: Int64(worker + 1) * microsecond + Int64(i))
                    }
                }
            }
        }
        let summary = recorder.summary(.tickToRender)
        #expect(summary.count == 80_000)
        #expect(summary.clamped == 0)
    }

    /// Every metric is written by its own task while two more tasks read `snapshot()` and `summary(_:)`
    /// throughout. Each read must be a whole state (a count that never exceeds what is written and percentiles
    /// inside the range written), and in the end every metric holds exactly what was written to it.
    @Test func everyMetricCanBeWrittenAndReadAtTheSameTime() async {
        let recorder = LatencyRecorder()
        let perMetric = 5_000
        await withTaskGroup(of: Void.self) { group in
            for metric in LatencyMetric.allCases {
                group.addTask {
                    for i in 0..<perMetric {
                        recorder.record(metric, nanos: microsecond + Int64(i))
                    }
                }
            }
            for _ in 0..<2 {
                group.addTask {
                    for _ in 0..<200 {
                        for (_, summary) in recorder.snapshot() {
                            #expect(summary.count <= perMetric)
                            #expect(summary.clamped == 0)
                            if let p50 = summary.p50Ns, let p99 = summary.p99Ns {
                                #expect(p50 >= microsecond && p50 <= p99 && p99 <= 7 * microsecond)
                            }
                        }
                        #expect(recorder.summary(.tickToApp).count <= perMetric)
                    }
                }
            }
        }
        for metric in LatencyMetric.allCases {
            #expect(recorder.summary(metric).count == perMetric)
        }
    }
}

struct LatencyMetricTests {
    @Test func hasTheSixMetricsInTheBriefsOrder() {
        #expect(LatencyMetric.allCases == [
            .tickToApp, .tickToApplied, .tickToRender, .orderSubmitToAck, .orderServerProcessing, .orderSubmitToFill,
        ])
    }

    /// The raw values are the case names (the default for a String enum), which is what a results file and a
    /// dictionary key in JSON carry.
    @Test(arguments: [
        (LatencyMetric.tickToApp, "tickToApp"),
        (.tickToApplied, "tickToApplied"),
        (.tickToRender, "tickToRender"),
        (.orderSubmitToAck, "orderSubmitToAck"),
        (.orderServerProcessing, "orderServerProcessing"),
        (.orderSubmitToFill, "orderSubmitToFill"),
    ] as [(LatencyMetric, String)])
    func rawValueIsTheCaseName(metric: LatencyMetric, name: String) {
        #expect(metric.rawValue == name)
        #expect(LatencyMetric(rawValue: name) == metric)
    }

    @Test func anUnknownRawValueIsNil() {
        #expect(LatencyMetric(rawValue: "tickToNowhere") == nil)
        #expect(LatencyMetric(rawValue: "") == nil)
    }

    @Test(arguments: LatencyMetric.allCases)
    func survivesAJSONRoundTrip(metric: LatencyMetric) throws {
        let data = try JSONEncoder().encode([metric])
        #expect(try JSONDecoder().decode([LatencyMetric].self, from: data) == [metric])
    }
}

struct WallClockTests {
    /// 2024-01-01T00:00:00Z as nanoseconds since the Unix epoch.
    private static let startOf2024: Int64 = 1_704_067_200_000_000_000

    @Test func nowIsNanosecondsSinceTheUnixEpoch() {
        #expect(WallClock.nowNs() > Self.startOf2024)
    }

    @Test func twoConsecutiveCallsAreWithinOneSecond() {
        let first = WallClock.nowNs()
        let second = WallClock.nowNs()
        #expect(abs(second - first) < 1_000_000_000)
    }

    /// A plain function: no `async`, `throws` or actor isolation, so it can be handed to a client as its
    /// clock, a `@Sendable () -> Int64`.
    @Test func canBePassedAroundAsAClosure() {
        let clock: @Sendable () -> Int64 = WallClock.nowNs
        #expect(clock() > Self.startOf2024)
    }
}

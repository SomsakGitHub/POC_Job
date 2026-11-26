import Testing
import TradeCore
@testable import TradePulse

/// The words of the latency chip: the time from a tick to the screen, as the middle and the 99th percentile of what the
/// recorder measured, with the samples that had to be clamped never left out.
@Suite(.timeLimit(.minutes(1)))
struct LatencyChipTests {
    @Test func anEmptySummaryShowsDashesInPlaceOfNumbers() {
        let empty = PercentileSummary(count: 0, p50Ns: nil, p95Ns: nil, p99Ns: nil, clamped: 0)
        #expect(LatencyChip.text(for: empty) == "tick\u{2192}screen p50 \u{2014} \u{00B7} p99 \u{2014}")
    }

    @Test func aSummaryShowsItsMedianAndItsNinetyNinthPercentile() {
        // The two numbers differ and the 95th is a third one, so a chip that shows the wrong one is caught.
        let summary = PercentileSummary(count: 100, p50Ns: 1_230_000, p95Ns: 3_000_000, p99Ns: 4_560_000, clamped: 0)
        #expect(LatencyChip.text(for: summary) == "tick\u{2192}screen p50 1.23 ms \u{00B7} p99 4.56 ms")
    }

    @Test func clampedSamplesAreNeverHidden() {
        let clamped = PercentileSummary(count: 100, p50Ns: 1_230_000, p95Ns: 3_000_000, p99Ns: 4_560_000, clamped: 7)
        let shown = LatencyChip.text(for: clamped)
        #expect(shown == "tick\u{2192}screen p50 1.23 ms \u{00B7} p99 4.56 ms \u{00B7} clamped 7")

        let one = PercentileSummary(count: 100, p50Ns: 1_230_000, p95Ns: 3_000_000, p99Ns: 4_560_000, clamped: 1)
        #expect(LatencyChip.text(for: one).hasSuffix(" \u{00B7} clamped 1"))

        // Samples that were all clamped leave the percentiles empty: the clamped count still shows.
        let onlyClamped = PercentileSummary(count: 3, p50Ns: nil, p95Ns: nil, p99Ns: nil, clamped: 3)
        let shownOnlyClamped = LatencyChip.text(for: onlyClamped)
        #expect(shownOnlyClamped == "tick\u{2192}screen p50 \u{2014} \u{00B7} p99 \u{2014} \u{00B7} clamped 3")

        let none = PercentileSummary(count: 100, p50Ns: 1_230_000, p95Ns: 3_000_000, p99Ns: 4_560_000, clamped: 0)
        #expect(!LatencyChip.text(for: none).contains("clamped"))
    }

    @Test func theChipReadsTheTickToRenderMetricAndNoOther() {
        let latency = LatencyRecorder()
        #expect(LatencyChip.text(of: latency) == LatencyChip.text(for: summary(of: [])))

        let screen: [Int64] = [2_000_000, 2_000_000, 2_000_000]
        let network: [Int64] = [9_000_000, 9_000_000, 9_000_000]
        #expect(screen.count == 3)
        #expect(network.count == 3)
        for sample in screen {
            latency.record(.tickToRender, nanos: sample)
        }
        for sample in network {
            latency.record(.tickToApp, nanos: sample)
        }

        let text = LatencyChip.text(of: latency)
        #expect(text == LatencyChip.text(for: summary(of: screen)))
        #expect(text != LatencyChip.text(for: summary(of: network)))
        #expect(text != LatencyChip.text(for: summary(of: [])))
    }
}

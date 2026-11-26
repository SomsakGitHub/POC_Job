import SwiftUI
import TradeCore

/// A small label that says how long a price takes from the server's tick to the screen, as the median and the 99th
/// percentile of what the app measured. It is the number the app is judged by, so it is on the chart's screen.
///
/// The text is rebuilt twice a second from the recorder and not on every price: a number that changes at the pace of
/// the market cannot be read, and rebuilding it per tick would cost a view update for nothing.
struct LatencyChip: View {
    /// What the app measured.
    let latency: LatencyRecorder

    /// The words for `summary`: `tick→screen p50 <median> · p99 <99th percentile>`, with a dash for a percentile that
    /// has no sample behind it. Samples that were out of range and had to be clamped are counted at the end, so the
    /// numbers before them are never taken for the whole truth.
    nonisolated static func text(for summary: PercentileSummary) -> String {
        let median = LatencyFormat.string(ns: summary.p50Ns)
        let slowest = LatencyFormat.string(ns: summary.p99Ns)
        var text = "tick\u{2192}screen p50 \(median) \u{00B7} p99 \(slowest)"
        if summary.clamped > 0 {
            text += " \u{00B7} clamped \(summary.clamped)"
        }
        return text
    }

    /// The words for the time from a tick to the screen, as `latency` has it now.
    nonisolated static func text(of latency: LatencyRecorder) -> String {
        text(for: latency.summary(.tickToRender))
    }

    /// The label, read again every half second.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text(Self.text(of: latency))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
        }
    }
}

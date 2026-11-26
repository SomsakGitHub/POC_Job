import TradeCore

/// The line the app prints for the measurement script: the six latency metrics, the frames and the hitches, as one line
/// of JSON.
///
/// The line is built by hand and not with `JSONEncoder`. A dictionary keyed by an enum encodes as an array, the order
/// of the keys of an encoded object is not fixed, and a script that compares two lines needs the same bytes for the
/// same numbers. Every number is an integer written in plain decimal, with no exponent and no grouping, whatever the
/// locale of the device.
struct LatencyReporter {
    /// What a metric reads as when the dictionary has nothing for it: no sample, no percentile, nothing clamped.
    private static let empty = PercentileSummary(count: 0, p50Ns: nil, p95Ns: nil, p99Ns: nil, clamped: 0)

    /// The line for `metrics` at `timestampMs` milliseconds since the Unix epoch, with the frames and the hitches
    /// the display counted:
    ///
    ///     {"t":<ms>,"metrics":{<six entries>},"frames":<n>,"hitches":<n>}
    ///
    /// The six entries follow `LatencyMetric.allCases`, each as `"<name>":{"count":<n>,"p50Ns":<n or null>,
    /// "p95Ns":<n or null>,"p99Ns":<n or null>,"clamped":<n>}`, with the name the metric's raw value. A metric the
    /// dictionary does not have reads as an empty one, and a percentile that is missing or negative is `null`, so a
    /// minus sign never appears in the line. The line has no space and no newline: the caller ends it.
    static func jsonLine(
        timestampMs: Int64, metrics: [LatencyMetric: PercentileSummary], frames: Int, hitches: Int
    ) -> String {
        let entries = LatencyMetric.allCases.map { metric in
            "\"\(metric.rawValue)\":" + object(for: metrics[metric] ?? empty)
        }
        return "{\"t\":\(timestampMs),\"metrics\":{\(entries.joined(separator: ","))},"
            + "\"frames\":\(frames),\"hitches\":\(hitches)}"
    }

    /// The object of one metric: its fields in the fixed order.
    private static func object(for summary: PercentileSummary) -> String {
        "{\"count\":\(summary.count),\"p50Ns\":\(nanoseconds(summary.p50Ns)),"
            + "\"p95Ns\":\(nanoseconds(summary.p95Ns)),\"p99Ns\":\(nanoseconds(summary.p99Ns)),"
            + "\"clamped\":\(summary.clamped)}"
    }

    /// A percentile as the number it is, or `null` for one that is missing or negative.
    private static func nanoseconds(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "null" }
        return String(value)
    }
}

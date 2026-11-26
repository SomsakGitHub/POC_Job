import Contracts
import TradeCore
import TradeNetworking

/// One row of the latency table: a metric and what was measured for it, and the words for each column.
///
/// A row is made from the summary of its metric and nothing else, so the same summary always gives the same words. A
/// figure nobody measured is a dash, and a clamped count is always shown when there is one, so the percentiles before
/// it are never taken for the whole truth.
struct LatencyTableRow: Equatable, Identifiable {
    /// The metric this row is about.
    let metric: LatencyMetric
    /// What was measured for it.
    let summary: PercentileSummary

    /// The row's identity: the metric's raw value, which is the name the measurement script knows it by.
    var id: String { metric.rawValue }

    /// The metric's name as the table writes it, with an arrow for "to".
    var title: String {
        switch metric {
        case .tickToApp: "Tick \u{2192} app"
        case .tickToApplied: "Tick \u{2192} applied"
        case .tickToRender: "Tick \u{2192} screen"
        case .orderSubmitToAck: "Order \u{2192} ack"
        case .orderServerProcessing: "Server processing"
        case .orderSubmitToFill: "Order \u{2192} fill"
        }
    }

    /// The metric's name as VoiceOver says it: no arrow and no abbreviation.
    var spokenTitle: String {
        switch metric {
        case .tickToApp: "Tick to app"
        case .tickToApplied: "Tick to applied"
        case .tickToRender: "Tick to screen"
        case .orderSubmitToAck: "Order to acknowledgement"
        case .orderServerProcessing: "Server processing"
        case .orderSubmitToFill: "Order to fill"
        }
    }

    /// How many samples there are, with a comma between groups of three digits; a dash when there are none.
    var countText: String {
        summary.count > 0 ? CountText.grouped(summary.count) : LabLabels.noData
    }

    /// The median, or a dash.
    var p50Text: String { LatencyFormat.string(ns: summary.p50Ns) }

    /// The 95th percentile, or a dash.
    var p95Text: String { LatencyFormat.string(ns: summary.p95Ns) }

    /// The 99th percentile, or a dash.
    var p99Text: String { LatencyFormat.string(ns: summary.p99Ns) }

    /// `clamped 7`, when some samples were out of range and had to be clamped; nil when none were.
    var clampedText: String? {
        summary.clamped > 0 ? "clamped \(CountText.grouped(summary.clamped))" : nil
    }

    /// The row as one sentence for VoiceOver: the metric, the samples and each percentile in words, and the clamped
    /// samples when there are some. A percentile nobody measured is "not available", so no dash is read out.
    var accessibilityText: String {
        guard summary.count > 0 else { return "\(spokenTitle): no samples" }
        let samples = summary.count == 1 ? "1 sample" : "\(CountText.grouped(summary.count)) samples"
        var text = "\(spokenTitle): \(samples), median \(spoken(summary.p50Ns)), "
        text += "95th percentile \(spoken(summary.p95Ns)), 99th percentile \(spoken(summary.p99Ns))"
        if summary.clamped > 0 {
            text += ", \(CountText.grouped(summary.clamped)) clamped"
        }
        return text
    }

    /// The rows for `snapshot`, one for each metric in `LatencyMetric.allCases` order. A metric the snapshot does not
    /// have is an empty row.
    static func rows(from snapshot: [LatencyMetric: PercentileSummary]) -> [LatencyTableRow] {
        let empty = PercentileSummary(count: 0, p50Ns: nil, p95Ns: nil, p99Ns: nil, clamped: 0)
        return LatencyMetric.allCases.map { LatencyTableRow(metric: $0, summary: snapshot[$0] ?? empty) }
    }

    /// A latency in words, or "not available" for one that is missing or negative.
    private func spoken(_ nanoseconds: Int64?) -> String {
        guard let nanoseconds, nanoseconds >= 0 else { return "not available" }
        return LatencyFormat.string(ns: nanoseconds)
    }
}

/// The words for the state of a connection.
enum ConnectionText {
    /// `Connected`, `Connecting…`, `Reconnecting, attempt 2` or `Stopped`.
    static func text(for state: ConnectionState) -> String {
        switch state {
        case .connected: "Connected"
        case .connecting: "Connecting\u{2026}"
        case .reconnecting(let attempt): "Reconnecting, attempt \(CountText.grouped(attempt))"
        case .stopped: "Stopped"
        }
    }
}

/// The words for what the last probe of the REST API found.
enum RestStatusText {
    /// `REST: checking…` before the first answer, `REST: reachable, 3.21 ms` with the round trip of the probe, or
    /// `REST: unreachable`.
    static func text(for status: RestStatus) -> String {
        switch status {
        case .unknown: "REST: checking\u{2026}"
        case .reachable(let rttNs): "REST: reachable, \(LatencyFormat.string(ns: rttNs))"
        case .unreachable: "REST: unreachable"
        }
    }
}

/// The words for the comparison of the app's account with the server's.
enum AccountCheckText {
    /// What the comparison found, and for the two cases that are not a verdict, why there is none.
    static func text(for reconciliation: Reconciliation) -> String {
        switch reconciliation {
        case .consistent: "Consistent"
        case .inFlight: "In flight: events still arriving or an order is unanswered"
        case .drift(let detail): "Drift: \(detail)"
        }
    }
}

/// The choices of a segmented control for a setting the server holds.
enum LabChoices {
    /// `base` and `current` together, in ascending order and with no duplicate: the value the server holds always
    /// shows, even when somebody set it to one that the control does not offer.
    static func choices(_ base: [Int], including current: Int) -> [Int] {
        Array(Set(base).union([current])).sorted()
    }
}

/// The words for the rate multiplier.
enum RateText {
    /// `2.5×` with one decimal, or a dash for a rate that is not a number, is negative or is absurdly large.
    static func text(for rate: Double) -> String {
        OneDecimal.text(rate).map { "\($0)\u{00D7}" } ?? LabLabels.noData
    }
}

/// The words for a count.
enum CountText {
    /// `count` in plain decimal with a comma between groups of three digits, whatever the locale of the device, and a
    /// minus sign for a negative one.
    static func grouped(_ count: Int) -> String {
        let digits = String(count.magnitude)
        var text = count < 0 ? "-" : ""
        for (offset, digit) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { text.append(",") }
            text.append(digit)
        }
        return text
    }
}

/// How many gaps in the sequence numbers of the market feed the app has seen.
enum GapCount {
    /// The gaps of all of `symbols` added up. `snapshot` gives the state of one symbol by its id; a symbol it has
    /// nothing for adds none, and a sum too big for an `Int` stays at `Int.max`.
    static func total(of symbols: [SymbolDTO], snapshot: (UInt32) -> SymbolSnapshot?) -> Int {
        var total = 0
        for symbol in symbols {
            let (sum, overflow) = total.addingReportingOverflow(snapshot(symbol.id)?.gapCount ?? 0)
            total = overflow ? Int.max : sum
        }
        return total
    }

    /// The line that says what the count is: `Sequence gaps seen on this connection: 3`.
    static func text(for total: Int) -> String {
        "Sequence gaps seen on this connection: \(CountText.grouped(total))"
    }
}

import SwiftUI

/// The table of the six latency metrics: for each one how many samples there are and its median, 95th and 99th
/// percentile, and how many samples were clamped when some were.
///
/// At the regular text size it is a table with a heading, one line for each metric, and the figures of a column under
/// one another. The clamped count, when there is one, goes on a second line under the metric's name and nowhere else,
/// so no other column moves. When the columns do not fit side by side, because the text is larger or a figure is
/// longer, each metric is a group of its own, with its name, its clamped count and one labelled line for each figure.
/// Which of the two is shown is for `ViewThatFits` to say, from what the figures need, and not from a size set here, so
/// no figure is ever broken or cut.
///
/// VoiceOver reads one sentence for each metric. The table takes the rows it is given and nothing else, so it reads
/// nothing that changes while the screen is open.
struct LatencyHUD: View {
    /// The six rows, in the order they are shown.
    let rows: [LatencyTableRow]

    /// The table when it fits, and the groups when it does not.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            table
            groups
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: The table

    /// A heading and a line for each metric, in columns that are as wide as their widest figure.
    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
            GridRow(alignment: .firstTextBaseline) {
                heading("Metric").gridColumnAlignment(.leading)
                heading("Count").gridColumnAlignment(.trailing)
                heading("p50").gridColumnAlignment(.trailing)
                heading("p95").gridColumnAlignment(.trailing)
                heading("p99").gridColumnAlignment(.trailing)
            }
            Divider()
            ForEach(rows) { row in
                GridRow(alignment: .firstTextBaseline) {
                    name(of: row)
                    figure(row.countText)
                    figure(row.p50Text)
                    figure(row.p95Text)
                    figure(row.p99Text)
                }
            }
        }
    }

    /// The heading of a column. VoiceOver skips it: each row says what its figures are.
    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityHidden(true)
    }

    /// The name of a metric with its clamped count under it, which is also what VoiceOver reads for the whole row.
    private func name(of row: LatencyTableRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(row.title)
                .font(.caption)
                .lineLimit(1)
            if let clamped = row.clampedText {
                Text(clamped)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityText)
    }

    /// One figure of the table, in digits of one width, which the row's sentence already says.
    private func figure(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .amountOnOneLine()
            .accessibilityHidden(true)
    }

    // MARK: The groups

    /// A group for each metric: its name, its clamped count and a labelled line for each figure.
    private var groups: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                    if let clamped = row.clampedText {
                        Text(clamped)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    LabValueRow(title: "Count", value: row.countText)
                    LabValueRow(title: "p50", value: row.p50Text)
                    LabValueRow(title: "p95", value: row.p95Text)
                    LabValueRow(title: "p99", value: row.p99Text)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityText)
                Divider()
            }
        }
    }
}

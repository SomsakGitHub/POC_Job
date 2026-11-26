import SwiftUI

/// The table of the six latency metrics: for each one how many samples there are and its median, 95th and 99th
/// percentile, and how many samples were clamped when some were.
///
/// Up to the regular text size it is a table with a heading, one line for each metric, and the figures of a column
/// under one another. The clamped count, when there is one, goes on a second line under the metric's name and nowhere
/// else, so no other column moves. From the next size up each metric is a group of its own, with its name, its clamped
/// count and one labelled line for each figure: the columns of a table would not fit beside the names on the narrowest
/// phone. Which of the two is shown depends on the text size and on nothing else, so the layout never changes while
/// the figures do.
///
/// The columns are as wide as a template figure, which is the widest figure that is likely, and not as wide as the
/// figures that are on show. A figure that is longer shrinks inside its column, and so no figure is broken or cut. What
/// is left of the width goes to the names, which wrap to a second line when they must.
///
/// VoiceOver reads one sentence for each metric. The table takes the rows it is given and the text size, and reads
/// nothing else that changes while the screen is open.
struct LatencyHUD: View {
    /// How the six metrics are laid out.
    enum Shape: Equatable {
        /// A heading and a line for each metric.
        case table
        /// A group of lines for each metric.
        case groups
    }

    /// The widest count a column holds at full size: six digits, and a seven-digit count shrinks to fit.
    static let countTemplate = "888,888"
    /// The widest latency under ten seconds a column holds at full size: `999.99 ms` is as wide as this in digits of
    /// one width, and the figures in microseconds and in seconds are narrower.
    static let percentileTemplate = "888.88 ms"
    /// The space between two columns of the table.
    static let columnSpacing: CGFloat = 6

    /// The six rows, in the order they are shown.
    let rows: [LatencyTableRow]
    /// The text size, which decides between the table and the groups.
    @Environment(\.dynamicTypeSize) private var typeSize

    /// How the metrics are laid out at `typeSize`: the table up to the regular size, which it holds on every phone the
    /// app supports, and the groups above it.
    static func shape(at typeSize: DynamicTypeSize) -> Shape {
        typeSize <= .large ? .table : .groups
    }

    /// The table or the groups, as far down as they need and never cut.
    var body: some View {
        Group {
            switch Self.shape(at: typeSize) {
            case .table: table
            case .groups: groups
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: The table

    /// A heading and a line for each metric, in columns of the width of their template figure.
    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: Self.columnSpacing, verticalSpacing: 4) {
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
                    figure(row.countText, template: Self.countTemplate)
                    figure(row.p50Text, template: Self.percentileTemplate)
                    figure(row.p95Text, template: Self.percentileTemplate)
                    figure(row.p99Text, template: Self.percentileTemplate)
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

    /// The name of a metric, on two lines if it has to be, with its clamped count under it, which is also what
    /// VoiceOver reads for the whole row.
    private func name(of row: LatencyTableRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(row.title)
                .font(.caption)
                .lineLimit(2)
            if let clamped = row.clampedText {
                Text(clamped)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .amountOnOneLine()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityText)
    }

    /// One figure of the table, in digits of one width, which the row's sentence already says. The cell is as wide as
    /// `template`, hidden, with the figure over it at the right edge: the figure shrinks to the cell if it is longer
    /// and never makes the column wider.
    private func figure(_ text: String, template: String) -> some View {
        Text(template)
            .font(.caption.monospacedDigit())
            .fixedSize()
            .hidden()
            .overlay(alignment: .trailing) {
                Text(text)
                    .font(.caption.monospacedDigit())
                    .amountOnOneLine()
            }
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

import SwiftUI

/// The Market tab: one row per symbol, each with its last price and its move from the reference price. A row opens the
/// symbol's detail screen.
///
/// The list is redrawn when `pump.tick` changes, which happens at most once per display frame however many updates
/// the feed delivered. The body reads nothing else that changes with the feed: in particular it never reads the
/// pump's frame and hitch counters, which change on every frame and would redraw the list at the display's pace even
/// when no price moved.
struct MarketListView: View {
    /// The app's environment, put in place by the root view.
    @Environment(AppEnvironment.self) private var environment
    /// The detail screens that are open, by symbol id: a symbol is not hashable, and an id says which one without
    /// holding on to it.
    @State private var path: [UInt32] = []
    /// What the launch arguments ask to open, until it has been opened.
    @State private var launch = LaunchRequest(arguments: CommandLine.arguments)

    /// The list, or a progress view until the server has given its symbols.
    var body: some View {
        let rows = Self.rows(in: environment)
        NavigationStack(path: $path) {
            Group {
                if rows.isEmpty {
                    ProgressView("Loading market\u{2026}")
                } else {
                    List(rows) { row in
                        NavigationLink(value: row.id) { MarketRow(model: row) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Market")
            .navigationDestination(for: UInt32.self) { id in
                detail(of: id)
            }
        }
        .onChange(of: environment.symbols.count, initial: true) {
            if let id = launch.take(from: environment.symbols) {
                path.append(id)
            }
        }
    }

    /// The detail screen of the symbol with `id`; nothing for an id that is not in the list.
    @ViewBuilder
    private func detail(of id: UInt32) -> some View {
        if let symbol = environment.symbols.first(where: { $0.id == id }) {
            StockDetailView(symbol: symbol)
        }
    }

    /// The rows of the list: one per symbol, in the server's order, each with the newest price the feed has given for
    /// it.
    ///
    /// This is everything the list reads from the environment, so evaluating it inside observation tracking shows what
    /// makes the list draw again: the symbols arriving, and the tick of a frame that carried new prices. The tick is
    /// read because the snapshots themselves are not observable.
    @MainActor
    static func rows(in environment: AppEnvironment) -> [MarketRowModel] {
        _ = environment.pump.tick
        return environment.symbols.map { symbol in
            MarketRowModel(symbol: symbol, snapshot: environment.marketState.snapshot(symbol.id))
        }
    }
}

/// One row of the list. The ticker and the Thai name stand on the left and the price and its move on the right; when
/// they do not fit side by side (a large text size), the same four lines are stacked and nothing is cut off.
private struct MarketRow: View {
    /// The words and the direction of the row.
    let model: MarketRowModel

    /// The row, side by side when it fits and stacked when it does not.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                names(lineLimit: 1)
                Spacer(minLength: 8)
                prices(alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                names(lineLimit: nil)
                prices(alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.accessibilityText)
    }

    /// The ticker over the Thai name. `lineLimit` is how many lines the name may take; nil lets it wrap.
    private func names(lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.ticker)
                .font(.headline)
            Text(model.nameTh)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
        }
    }

    /// The last price over the move, whose glyph and colour tell the direction.
    private func prices(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(model.lastText)
                .font(.headline)
                .monospacedDigit()
            HStack(spacing: 4) {
                Image(systemName: style.symbolName)
                Text(model.changeText)
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(style.color)
        }
    }

    /// The glyph and the colour of the row's direction.
    private var style: DirectionStyle {
        DirectionStyle(model.direction)
    }
}

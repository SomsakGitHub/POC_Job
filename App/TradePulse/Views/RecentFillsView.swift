import SwiftUI

/// The newest fills of one symbol, under its buy and sell buttons: when each happened, what was bought or sold and what
/// it did to the cash. A placeholder says so while there are none.
///
/// It reads the trading state in its own body, so that a fill evaluates this view and not the screen around it.
struct RecentFillsView: View {
    /// The symbol whose fills are shown.
    let symbolId: UInt32
    /// The app's environment.
    let environment: AppEnvironment

    /// The title over the fills, or over the placeholder.
    var body: some View {
        let fills = RecentFills.latest(in: environment.trading.state.ledger, symbolId: symbolId)
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent fills")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if fills.isEmpty {
                Text("No fills yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fills) { fill in
                    TransactionRowView(
                        model: TransactionRowModel(row: fill, ticker: environment.symbols.ticker(for: fill.symbolId))
                    )
                    Divider()
                }
            }
        }
    }
}

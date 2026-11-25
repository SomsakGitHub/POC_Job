import SwiftUI
import TradeNetworking

/// The transactions of the account, newest first: the first page the server's REST API gives, merged with the fills the
/// app has seen live.
///
/// The page is asked for when the section appears, again when the trading connection comes back (what happened while it
/// was down is on the server and may not be in the app's ledger) and again when the server started over. The rows are
/// the model's, so a fill that arrives shows at once, and a page that belongs to an epoch the server has left is not
/// shown. The body reads the trading state and the trading connection, never a price.
struct TransactionsSection: View {
    /// What asks for a page again: the number of times the server started over, and the taps on Retry and
    /// the returns of the connection so far.
    private struct LoadTrigger: Equatable {
        /// How many times the trading state has counted a server that started over.
        let epochChanges: Int
        /// How many times the page has been asked for again by Retry or by a connection that came back.
        let reloads: Int
    }

    /// The app's environment.
    let environment: AppEnvironment
    /// The rows, made once for the section.
    @State private var model: TransactionsModel
    /// How many times the page has been asked for again by Retry or by a connection that came back.
    @State private var reloads = 0

    /// The section over the environment's REST API and trading store.
    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: TransactionsModel(rest: environment.rest, trading: environment.trading))
    }

    /// The title, the notice when the page could not be loaded, and the rows or a note that there are none.
    var body: some View {
        let rows = model.rows
        VStack(alignment: .leading, spacing: 8) {
            Text("Transactions")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if model.loadFailed {
                HStack {
                    Label("The transactions could not be loaded.", systemImage: "exclamationmark.triangle")
                    Spacer(minLength: 8)
                    Button("Retry") { reloads += 1 }
                }
                .font(.footnote)
            }
            if rows.isEmpty {
                Text("No transactions yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        TransactionRowView(
                            model: TransactionRowModel(row: row, ticker: environment.symbols.ticker(for: row.symbolId))
                        )
                        Divider()
                    }
                }
            }
        }
        .task(id: LoadTrigger(epochChanges: environment.trading.state.epochChanges, reloads: reloads)) {
            await model.load()
        }
        .onChange(of: environment.tradingConnection) { old, new in
            if shouldReloadOnConnection(from: old, to: new) {
                reloads += 1
            }
        }
    }
}

/// One transaction: what was bought or sold and when on the left, what it did to the cash and what it cost on the
/// right. The two halves are stacked when they do not fit side by side.
struct TransactionRowView: View {
    /// The words of the row.
    let model: TransactionRowModel

    /// The row, read by VoiceOver as one sentence.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                what
                Spacer(minLength: 8)
                money(alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                what
                money(alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityText)
    }

    /// The side, the shares and the ticker over the time and the price.
    private var what: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(model.sideText) \(model.sharesText) \(model.ticker)")
                .font(.subheadline.weight(.semibold))
            Text("\(model.timeText) \u{00B7} at \(model.priceText)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// The change in cash over the commission.
    private func money(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(model.cashChangeText)
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text("commission \(model.commissionText)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

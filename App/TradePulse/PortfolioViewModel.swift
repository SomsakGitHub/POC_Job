import Contracts
import TradeCore
import TradeNetworking

/// One position on the Portfolio screen: the shares held in one symbol and what they are worth now.
struct PositionRow: Identifiable, Equatable {
    /// The symbol's id.
    let id: UInt32
    /// The symbol's ticker, or "#" and the id when the symbol list does not have it.
    let ticker: String
    /// The shares held; always above 0.
    let quantity: Quantity
    /// The last price the market feed gave for the symbol; nil while there is none or it is not above 0.
    let last: Price?
    /// `quantity` times `last` in satang, held to the range of `Int64`; nil without a price.
    let marketValueSatang: Int64?
}

/// What the Portfolio screen shows of the account: the cash, the equity and the positions.
///
/// It is a value made from a copy of the trading state, a way to look prices up and the symbol list, so the same inputs
/// always give the same words. A position the market feed has no price for makes the equity unknown: a total that
/// left a position out would be a number that is false, so the equity is a dash and the positions that wait for a
/// price are counted. No profit or loss is shown: the app does not know what a position cost.
@MainActor
struct PortfolioViewModel {
    /// The positions, ordered by ticker.
    let rows: [PositionRow]
    /// How many positions have no price yet.
    let unpricedCount: Int
    /// The cash in satang.
    private let cash: Int64
    /// The cash and the value of every position in satang, held to the range of `Int64`; nil while a position has no
    /// price.
    private let equity: Int64?

    /// The portfolio of `state`, priced with the last prices `snapshots` gives and named from `symbols`.
    init(state: TradingState, snapshots: (UInt32) -> SymbolSnapshot?, symbols: [SymbolDTO]) {
        var rows: [PositionRow] = []
        var total = Int128(state.cash)
        var unpriced = 0
        for (id, quantity) in state.positions where quantity > 0 {
            let last = snapshots(id).map(\.last).flatMap { $0.satang > 0 ? $0 : nil }
            let value = last.map { Int64(clamping: Int128(quantity) * Int128($0.satang)) }
            if let value {
                total += Int128(value)
            } else {
                unpriced += 1
            }
            rows.append(
                PositionRow(
                    id: id, ticker: symbols.ticker(for: id), quantity: quantity, last: last, marketValueSatang: value
                )
            )
        }
        // The state keeps a dictionary, so the order is made here; the id settles two positions of one ticker.
        self.rows = rows.sorted { ($0.ticker, $0.id) < ($1.ticker, $1.id) }
        unpricedCount = unpriced
        cash = state.cash
        equity = unpriced == 0 ? Int64(clamping: total) : nil
    }

    /// The cash as money.
    var cashText: String {
        MoneyFormat.baht(satang: cash)
    }

    /// The cash and the value of every position as money, or a dash while any position has no price.
    var equityText: String {
        equity.map { MoneyFormat.baht(satang: $0) } ?? "—"
    }

    /// The line that says how many positions wait for a price; nil when none does.
    var waitingText: String? {
        switch unpricedCount {
        case 0: nil
        case 1: "Waiting for the price of 1 position"
        default: "Waiting for prices of \(unpricedCount) positions"
        }
    }
}

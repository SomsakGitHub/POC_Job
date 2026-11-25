import Contracts
import Observation
import TradeCore
import TradeNetworking

/// The transactions the Portfolio screen lists: the first page the server's REST API gives, merged with the fills the
/// trading state has seen live.
///
/// The REST page covers what the live ledger cannot (fills from before the app learned of the server's log, for
/// example after it started over from the account). It belongs to the server epoch it was loaded in, and the live
/// ledger is emptied when the server starts a new one, so a page is never shown beside the ledger of another epoch:
/// an answer that arrives after the epoch changed is dropped, and a page that is already held stops being shown
/// as soon as the state's epoch count has moved on.
@MainActor
@Observable
final class TransactionsModel {
    /// How many transactions a request for the first page asks for.
    static let pageSize = 50

    /// Whether the last request that could be applied failed. The rows stay as they were.
    private(set) var loadFailed = false

    /// The rows of the last page that was applied, newest first.
    private var page: [LedgerRow] = []
    /// The number of epoch changes the trading state had counted when the page was asked for; nil before a page was
    /// applied. The page is shown only while the state still counts the same.
    private var pageEpochChanges: Int?
    /// How many times `load()` has been called: the number of the newest request.
    @ObservationIgnored private var generation = 0

    /// The REST, which the page comes from.
    private let rest: any RestAPI
    /// The trading store, whose ledger and epoch count the page is merged with and judged by.
    private let trading: TradingStore

    /// A model that loads from `rest` and merges with the ledger of `trading`.
    init(rest: any RestAPI, trading: TradingStore) {
        self.rest = rest
        self.trading = trading
    }

    /// The transactions to show, newest first: the live ledger and, while it still belongs to the same server epoch,
    /// the loaded page. A fill that is in both is the live row.
    var rows: [LedgerRow] {
        let state = trading.state
        var byId: [UInt64: LedgerRow] = [:]
        if pageEpochChanges == state.epochChanges {
            for row in page {
                byId[row.id] = row
            }
        }
        for row in state.ledger {
            byId[row.id] = row
        }
        return byId.values.sorted { $0.id > $1.id }
    }

    /// Asks for the first page and, when the answer may still be used, keeps it. An answer is used only if the call was
    /// not cancelled, no newer call has been made since and the server is still in the epoch the call began in. A call
    /// that fails changes nothing but `loadFailed`, under the same conditions on cancellation and on newer calls.
    func load() async {
        generation += 1
        let mine = generation
        let epochChanges = trading.state.epochChanges
        do {
            let answer = try await rest.transactions(cursor: nil, limit: Self.pageSize)
            guard !Task.isCancelled, mine == generation, trading.state.epochChanges == epochChanges else { return }
            page = answer.items.compactMap(Self.ledgerRow)
            pageEpochChanges = epochChanges
            loadFailed = false
        } catch {
            guard !Task.isCancelled, mine == generation else { return }
            loadFailed = true
        }
    }

    /// The ledger row of a transaction the REST API listed, or nil when its side is neither "buy" nor "sell": such a
    /// row is dropped and never guessed at.
    private static func ledgerRow(_ transaction: TransactionDTO) -> LedgerRow? {
        let side: Side
        switch transaction.side {
        case "buy": side = .buy
        case "sell": side = .sell
        default: return nil
        }
        return LedgerRow(
            id: transaction.ledgerSeq, orderId: transaction.orderId, symbolId: transaction.symbolId, side: side,
            quantity: transaction.quantity, price: Price(satang: transaction.price),
            commission: transaction.commission, cashDelta: transaction.cashDelta, tsNs: transaction.tsNs
        )
    }
}

import TradeCore
import TradeNetworking

/// Which fills the "Recent fills" area of a symbol's screen shows.
enum RecentFills {
    /// How many fills the area shows at most.
    static let defaultLimit = 5

    /// The newest `limit` fills of the symbol `symbolId` in `ledger`, newest first. Fills of other symbols are left
    /// out, a ledger with fewer fills gives all of them, and a limit of 0 or less gives none.
    static func latest(in ledger: [LedgerRow], symbolId: UInt32, limit: Int = RecentFills.defaultLimit) -> [LedgerRow] {
        guard limit > 0 else { return [] }
        let ours = ledger.filter { $0.symbolId == symbolId }
        return Array(ours.sorted { $0.id > $1.id }.prefix(limit))
    }
}

import Contracts
import TradeCore

// The values of the trading reducer: the order the app submits, the rows and numbers the order screens show, and the
// actions that change them. All plain value types, so a state can be copied, compared and handed to another task.

/// An order the app is about to send: what it knows about the order before the server has answered.
///
/// The app chooses the client order id. The server repeats it in its answer, so the id is how the answer finds the
/// order's row again, and it is what lets a retry be told from a second order.
public struct OrderDraft: Sendable, Equatable {
    /// The id the app gave the order. Unique among the orders of an account, and the `id` of the row made from it.
    public let clientOrderId: String
    /// The symbol to trade, by the id the symbol list uses.
    public let symbolId: UInt32
    /// Buy or sell.
    public let side: Side
    /// Market or limit.
    public let type: OrderType
    /// The shares to trade.
    public let quantity: Quantity
    /// The limit price of a limit order; nil for a market order.
    public let limitPrice: Price?

    /// A draft of one order; `limitPrice` is left out for a market order.
    public init(
        clientOrderId: String, symbolId: UInt32, side: Side, type: OrderType, quantity: Quantity,
        limitPrice: Price? = nil
    ) {
        self.clientOrderId = clientOrderId
        self.symbolId = symbolId
        self.side = side
        self.type = type
        self.quantity = quantity
        self.limitPrice = limitPrice
    }
}

/// One order as the order screens show it: what was asked, how far it got and why it ended.
///
/// A row is identified by the client order id, the one id the app has from the moment it submits, so the same row
/// carries the order from `.pending` to its last status. `orderId` is the server's own id, known once the server has
/// accepted the order, and the key that every fill and cancel finds the row by.
///
/// Two rows are equal when every public property is equal. The exact notional behind `averageFillPrice` is kept for
/// the next fill and is left out of the comparison: a row built by hand, which cannot know it, still equals the row
/// the reducer built.
public struct OrderRow: Identifiable, Sendable, Equatable {
    /// The client order id: unique among the rows of a state.
    public let id: String
    /// The server's id for the order; nil until the server has accepted it.
    public var orderId: String?
    /// The symbol traded, by the id the symbol list uses.
    public var symbolId: UInt32
    /// Buy or sell.
    public var side: Side
    /// Market or limit.
    public var type: OrderType
    /// The shares asked for.
    public var quantity: Quantity
    /// The limit price; nil for a market order, and when the server reports none.
    public var limitPrice: Price?
    /// The shares filled so far, summed over all fills (saturating at `Int64.max`).
    public var filledQuantity: Quantity
    /// The volume-weighted average price of all fills so far, rounded half up to a whole satang; nil before the first.
    public var averageFillPrice: Price?
    /// Where the order is in its life: `.pending` until the server answers, `.unknown` when the answer was lost, then
    /// `.accepted` and `.partiallyFilled`; `.filled`, `.cancelled` and `.rejected` are the ends and never change.
    public var status: OrderStatus
    /// Why the order ended early: the reason of a rejection, or of a cancel the engine made itself (for example
    /// `.noLiquidity` for what a market order could not fill). Nil for every other status and for an ordinary cancel.
    public var rejectReason: RejectReason?
    /// When the row was created, in nanoseconds: the app's clock for an order it submitted, the server's clock for an
    /// order it learned of from the event log.
    public var createdNs: Int64
    /// The exact sum of `price * quantity` over all fills, in satang. The average is worked out from it and never from
    /// the rounded `averageFillPrice`, which would drift with every fill. 128 bits hold the sum of any `Int64` fills.
    var filledNotional: Int128

    /// A row. Everything but the client order id, the symbol, the side, the type and the quantity has a default: a
    /// row that has not been answered (`.pending`, no server id, nothing filled).
    ///
    /// The exact notional is started from `averageFillPrice * filledQuantity` (0 without an average), so that a row
    /// built by hand carries on from its average when the next fill arrives.
    public init(
        id: String, orderId: String? = nil, symbolId: UInt32, side: Side, type: OrderType, quantity: Quantity,
        limitPrice: Price? = nil, filledQuantity: Quantity = 0, averageFillPrice: Price? = nil,
        status: OrderStatus = .pending, rejectReason: RejectReason? = nil, createdNs: Int64 = 0
    ) {
        self.id = id
        self.orderId = orderId
        self.symbolId = symbolId
        self.side = side
        self.type = type
        self.quantity = quantity
        self.limitPrice = limitPrice
        self.filledQuantity = filledQuantity
        self.averageFillPrice = averageFillPrice
        self.status = status
        self.rejectReason = rejectReason
        self.createdNs = createdNs
        filledNotional = averageFillPrice.map { Int128($0.satang) * Int128(filledQuantity) } ?? 0
    }

    /// Equal when every public property is equal; see the note on the exact notional above.
    public static func == (lhs: OrderRow, rhs: OrderRow) -> Bool {
        lhs.id == rhs.id && lhs.orderId == rhs.orderId && lhs.symbolId == rhs.symbolId && lhs.side == rhs.side
            && lhs.type == rhs.type && lhs.quantity == rhs.quantity && lhs.limitPrice == rhs.limitPrice
            && lhs.filledQuantity == rhs.filledQuantity && lhs.averageFillPrice == rhs.averageFillPrice
            && lhs.status == rhs.status && lhs.rejectReason == rhs.rejectReason && lhs.createdNs == rhs.createdNs
    }
}

/// One fill in the ledger: the shares that changed hands, at what price, and what it did to cash.
///
/// A row is identified by the server's ledger sequence number (1 for the first fill of the account, then 2, 3 and so
/// on with no gap), so a fill that is delivered twice is still one row.
public struct LedgerRow: Identifiable, Sendable, Equatable {
    /// The ledger sequence number: unique among the rows of a state.
    public var id: UInt64
    /// The server's id of the order that was filled.
    public let orderId: String
    /// The symbol that was filled.
    public let symbolId: UInt32
    /// Buy or sell.
    public let side: Side
    /// The shares in this fill.
    public let quantity: Quantity
    /// The price of one share in this fill.
    public let price: Price
    /// The commission charged for this fill, in satang.
    public let commission: Int64
    /// What the fill did to cash, in satang: negative for a buy, with the commission already in it.
    public let cashDelta: Int64
    /// When the fill happened, in nanoseconds since the Unix epoch, on the server's clock.
    public let tsNs: Int64

    /// A ledger row with every field given.
    public init(
        id: UInt64, orderId: String, symbolId: UInt32, side: Side, quantity: Quantity, price: Price, commission: Int64,
        cashDelta: Int64, tsNs: Int64
    ) {
        self.id = id
        self.orderId = orderId
        self.symbolId = symbolId
        self.side = side
        self.quantity = quantity
        self.price = price
        self.commission = commission
        self.cashDelta = cashDelta
        self.tsNs = tsNs
    }
}

/// Everything the order screens show as of the last action reduced: the orders, the ledger, cash and positions, plus
/// the bookkeeping that tells a repeated event from a new one. A fresh state is what the app has at launch.
public struct TradingState: Sendable, Equatable {
    /// The epoch of the server whose events and snapshots this state holds; nil until the first one arrives. A server
    /// that restarts or resets starts a new epoch and numbers its events from 1 again.
    public var epoch: String?
    /// The number of the newest event applied in `epoch`; 0 when there is none. An event numbered at or below it is a
    /// repeat of one already applied.
    public var lastEventSeq: UInt64
    /// How many times a server epoch different from the one held has been seen; the first epoch is not counted. It
    /// never goes down, not even through `.clear`, so a screen that remembers the value it last drew can tell with one
    /// comparison that every row it drew is gone.
    public var epochChanges: Int
    /// The orders, newest first. Each client order id appears once.
    public var orders: [OrderRow]
    /// The fills, newest first. Each ledger sequence number appears once.
    public var ledger: [LedgerRow]
    /// Cash in satang, as of the newest ledger entry or account snapshot.
    public var cash: Int64
    /// The shares held per symbol. A symbol with no shares has no entry.
    public var positions: [UInt32: Quantity]

    /// The state of a fresh launch: no epoch, sequence 0, no epoch changes, no rows, no cash and no positions.
    public init() {
        epoch = nil
        lastEventSeq = 0
        epochChanges = 0
        orders = []
        ledger = []
        cash = 0
        positions = [:]
    }
}

/// A change to a `TradingState`: something the app did, something the server said, or a reset.
public enum TradingAction: Sendable {
    /// The app is sending `draft`: a row appears as `.pending`, stamped `createdNs` (the app's clock). A draft whose id
    /// already has a row is ignored.
    case localSubmitted(OrderDraft, createdNs: Int64)
    /// The server answered the submit with a refusal (the response of the order call, before the event log says so).
    case submitRejected(clientOrderId: String, reason: RejectReason)
    /// The submit got no answer (a timeout or a dropped connection): the order may or may not exist, so its row is
    /// `.unknown` until the event log settles it.
    case submitUnconfirmed(clientOrderId: String)
    /// One event of the server's order log, live or replayed from sequence 0 after a relaunch.
    case event(Tp_OrderEvent)
    /// A snapshot of the account. With `adoptEventSeq` the state also takes the snapshot's event sequence as its own,
    /// so the log is followed from there (recovery after the server could not resend what was missed). Without it the
    /// sequence stays where it is, and the log is replayed from there to rebuild the order rows.
    case account(AccountDTO, adoptEventSeq: Bool)
    /// Forget everything and start as at launch (for example after the server was reset on the user's request): no
    /// rows, cash 0, no positions, no epoch and sequence 0. The one thing kept is `epochChanges`, so that it never goes
    /// down for a screen that compares it with the value it last saw.
    case clear
}

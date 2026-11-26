import Contracts
import Testing
import TradeCore
import TradeNetworking

// Events, drafts, accounts and states for the trading reducer tests. Every protobuf message is built by assigning its
// properties, never through a memberwise initialiser. The defaults describe one order: client id "C-1", server id
// "O-000001", symbol 1, a market buy of 200 shares, in epoch "E1".

/// An event of `epoch` numbered `seq` and stamped `tsNs` that carries no payload yet.
func orderEvent(_ seq: UInt64, epoch: String = "E1", tsNs: Int64 = 1_000) -> Tp_OrderEvent {
    var event = Tp_OrderEvent()
    event.eventSeq = seq
    event.serverEpoch = epoch
    event.serverTsNs = tsNs
    return event
}

/// The server accepted order `order`, which the app knows as `client`. A `limitPrice` of 0 is what the wire says for
/// "no limit price".
func acceptedEvent(
    _ seq: UInt64, epoch: String = "E1", tsNs: Int64 = 1_000, client: String = "C-1", order: String = "O-000001",
    symbol: UInt32 = 1, side: Tp_Side = .buy, type: Tp_OrderType = .market, quantity: Int64 = 200,
    limitPrice: Int64 = 0
) -> Tp_OrderEvent {
    var payload = Tp_OrderAccepted()
    payload.orderID = order
    payload.clientOrderID = client
    payload.symbolID = symbol
    payload.side = side
    payload.type = type
    payload.quantity = quantity
    payload.limitPrice = limitPrice
    var event = orderEvent(seq, epoch: epoch, tsNs: tsNs)
    event.accepted = payload
    return event
}

/// The server refused the submit of `client`.
func rejectedEvent(
    _ seq: UInt64, epoch: String = "E1", tsNs: Int64 = 1_000, client: String = "C-1",
    reason: Tp_RejectReason = .insufficientFunds
) -> Tp_OrderEvent {
    var payload = Tp_OrderRejected()
    payload.clientOrderID = client
    payload.reason = reason
    var event = orderEvent(seq, epoch: epoch, tsNs: tsNs)
    event.rejected = payload
    return event
}

/// A fill of `quantity` shares at `price`, leaving `remaining` shares of the order unfilled.
func fillEvent(
    _ seq: UInt64, epoch: String = "E1", tsNs: Int64 = 1_000, order: String = "O-000001", symbol: UInt32 = 1,
    side: Tp_Side = .buy, quantity: Int64, price: Int64, remaining: Int64
) -> Tp_OrderEvent {
    var payload = Tp_OrderFill()
    payload.orderID = order
    payload.symbolID = symbol
    payload.side = side
    payload.quantity = quantity
    payload.price = price
    payload.remaining = remaining
    var event = orderEvent(seq, epoch: epoch, tsNs: tsNs)
    event.fill = payload
    return event
}

/// `order` was cancelled with `remaining` shares unfilled; `reason` is unspecified for an ordinary cancel.
func cancelledEvent(
    _ seq: UInt64, epoch: String = "E1", tsNs: Int64 = 1_000, order: String = "O-000001", remaining: Int64 = 0,
    reason: Tp_RejectReason = .unspecified
) -> Tp_OrderEvent {
    var payload = Tp_OrderCancelled()
    payload.orderID = order
    payload.remaining = remaining
    payload.reason = reason
    var event = orderEvent(seq, epoch: epoch, tsNs: tsNs)
    event.cancelled = payload
    return event
}

/// Ledger entry `ledgerSeq`: the fill of `quantity` shares at `price`, with the absolute cash and position after it.
func ledgerEvent(
    _ seq: UInt64, epoch: String = "E1", tsNs: Int64 = 1_000, ledgerSeq: UInt64, order: String = "O-000001",
    symbol: UInt32 = 1, side: Tp_Side = .buy, quantity: Int64, price: Int64, commission: Int64 = 0,
    cashDelta: Int64 = 0, cashAfter: Int64, positionAfter: Int64
) -> Tp_OrderEvent {
    var payload = Tp_LedgerEntry()
    payload.ledgerSeq = ledgerSeq
    payload.orderID = order
    payload.symbolID = symbol
    payload.side = side
    payload.quantity = quantity
    payload.price = price
    payload.commission = commission
    payload.cashDelta = cashDelta
    payload.cashAfter = cashAfter
    payload.positionAfter = positionAfter
    payload.tsNs = tsNs
    var event = orderEvent(seq, epoch: epoch, tsNs: tsNs)
    event.ledgerEntry = payload
    return event
}

/// An order the app is about to send; `limit` is the limit price in satang.
func draft(
    _ client: String = "C-1", symbol: UInt32 = 1, side: Side = .buy, type: OrderType = .market,
    quantity: Quantity = 200, limit: Int64? = nil
) -> OrderDraft {
    OrderDraft(
        clientOrderId: client, symbolId: symbol, side: side, type: type, quantity: quantity,
        limitPrice: limit.map { Price(satang: $0) }
    )
}

/// An account snapshot; `positions` are (symbol, shares) pairs, kept in the order given.
func accountSnapshot(
    epoch: String = "E1", cash: Int64 = 0, positions: [(UInt32, Int64)] = [], lastEventSeq: UInt64 = 0,
    lastLedgerSeq: UInt64 = 0
) -> AccountDTO {
    AccountDTO(
        epoch: epoch, cash: cash, positions: positions.map { PositionDTO(symbolId: $0.0, quantity: $0.1) },
        lastEventSeq: lastEventSeq, lastLedgerSeq: lastLedgerSeq
    )
}

/// `state` after each of `actions`, applied in order.
func reduced(_ actions: [TradingAction], from state: TradingState = TradingState()) -> TradingState {
    var state = state
    for action in actions {
        TradingReducer.reduce(&state, action)
    }
    return state
}

/// `state` after each of `events`, applied in order.
func reduced(events: [Tp_OrderEvent], from state: TradingState = TradingState()) -> TradingState {
    reduced(events.map { TradingAction.event($0) }, from: state)
}

/// A state with one row in every status, in epoch "E1" at event 7, newest first: "C-cancelled" (server id
/// "O-000004"), "C-filled" ("O-000003"), "C-part" (partially filled, "O-000002"), "C-open" (accepted, "O-000001"),
/// "C-unknown", "C-pending" and "C-rejected". Each order is for 200 shares except "C-filled" and "C-cancelled" (100).
func stateWithEveryStatus() -> TradingState {
    let local = reduced([
        .localSubmitted(draft("C-rejected"), createdNs: 10),
        .submitRejected(clientOrderId: "C-rejected", reason: .invalidLot),
        .localSubmitted(draft("C-pending"), createdNs: 20),
        .localSubmitted(draft("C-unknown"), createdNs: 30),
        .submitUnconfirmed(clientOrderId: "C-unknown"),
    ])
    return reduced(
        events: [
            acceptedEvent(1, client: "C-open", order: "O-000001", quantity: 200),
            acceptedEvent(2, client: "C-part", order: "O-000002", quantity: 200),
            fillEvent(3, order: "O-000002", quantity: 100, price: 3_425, remaining: 100),
            acceptedEvent(4, client: "C-filled", order: "O-000003", quantity: 100),
            fillEvent(5, order: "O-000003", quantity: 100, price: 3_430, remaining: 0),
            acceptedEvent(6, client: "C-cancelled", order: "O-000004", quantity: 100),
            cancelledEvent(7, order: "O-000004", remaining: 100),
        ], from: local)
}

extension TradingState {
    /// The row whose client order id is `id`.
    func order(_ id: String) -> OrderRow? {
        orders.first { $0.id == id }
    }

    /// This state with `change` applied to the row `id`: the state a test expects when an action changes that row and
    /// nothing else. Fails the test if there is no such row.
    func editing(_ id: String, _ change: (inout OrderRow) -> Void) throws -> TradingState {
        var copy = self
        let index = try #require(copy.orders.firstIndex { $0.id == id })
        change(&copy.orders[index])
        return copy
    }
}

/// The order log of an exchange server, written the way the real one writes it: events numbered 1, 2, 3 ... within
/// the epoch, order ids "O-000001", "O-000002" ..., ledger numbers 1, 2, 3 ... with no gap, and for every fill a
/// `fill` event followed by its `ledgerEntry` at the same instant. `cashAfter` and `positionAfter` are absolute. A
/// commission is a thousandth of the fill's value, rounded down.
struct ServerLog {
    let epoch: String
    private(set) var events: [Tp_OrderEvent] = []
    /// The cash the server holds after the last fill.
    private(set) var cash: Int64
    /// The shares the server holds after the last fill, per symbol; a symbol with none has no entry.
    private(set) var positions: [UInt32: Int64] = [:]
    private var orders: [String: (symbol: UInt32, side: Tp_Side)] = [:]
    private var ledgerCount: UInt64 = 0
    private var clockNs: Int64

    init(epoch: String = "E1", cash: Int64 = 100_000_000, startNs: Int64 = 1_000_000_000) {
        self.epoch = epoch
        self.cash = cash
        clockNs = startNs
    }

    /// The number and the time of the next event; the clock moves a microsecond per event.
    private mutating func stamp() -> (seq: UInt64, tsNs: Int64) {
        clockNs += 1_000
        return (UInt64(events.count) + 1, clockNs)
    }

    /// The server refuses a submit: one `rejected` event and never an `accepted`.
    mutating func refuse(client: String, reason: Tp_RejectReason) {
        let (seq, tsNs) = stamp()
        events.append(rejectedEvent(seq, epoch: epoch, tsNs: tsNs, client: client, reason: reason))
    }

    /// The server accepts a submit; returns the id it gave the order.
    @discardableResult
    mutating func accept(
        client: String, symbol: UInt32 = 1, side: Tp_Side = .buy, type: Tp_OrderType = .market, quantity: Int64,
        limitPrice: Int64 = 0
    ) -> String {
        let digits = String(orders.count + 1)
        let order = "O-" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
        orders[order] = (symbol, side)
        let (seq, tsNs) = stamp()
        events.append(
            acceptedEvent(
                seq, epoch: epoch, tsNs: tsNs, client: client, order: order, symbol: symbol, side: side, type: type,
                quantity: quantity, limitPrice: limitPrice
            )
        )
        return order
    }

    /// `order` fills `quantity` shares at `price` and `remaining` shares are left: a `fill` event, then its ledger
    /// entry.
    mutating func fill(_ order: String, quantity: Int64, price: Int64, remaining: Int64) {
        guard let book = orders[order] else {
            Issue.record("the log has no order \(order)")
            return
        }
        let (seq, tsNs) = stamp()
        events.append(
            fillEvent(
                seq, epoch: epoch, tsNs: tsNs, order: order, symbol: book.symbol, side: book.side, quantity: quantity,
                price: price, remaining: remaining
            )
        )
        let value = price * quantity
        let commission = value / 1_000
        let delta = book.side == .buy ? -(value + commission) : value - commission
        cash += delta
        let held = (positions[book.symbol] ?? 0) + (book.side == .buy ? quantity : -quantity)
        positions[book.symbol] = held > 0 ? held : nil
        ledgerCount += 1
        events.append(
            ledgerEvent(
                seq + 1, epoch: epoch, tsNs: tsNs, ledgerSeq: ledgerCount, order: order, symbol: book.symbol,
                side: book.side, quantity: quantity, price: price, commission: commission, cashDelta: delta,
                cashAfter: cash, positionAfter: max(held, 0)
            )
        )
    }

    /// `order` is cancelled with `remaining` shares unfilled; `reason` is unspecified for an ordinary cancel.
    mutating func cancel(_ order: String, remaining: Int64 = 0, reason: Tp_RejectReason = .unspecified) {
        let (seq, tsNs) = stamp()
        events.append(cancelledEvent(seq, epoch: epoch, tsNs: tsNs, order: order, remaining: remaining, reason: reason))
    }
}

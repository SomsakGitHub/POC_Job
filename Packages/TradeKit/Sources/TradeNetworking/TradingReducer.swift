import Contracts
import TradeCore

/// The rules that turn what the app does and what the server says into a `TradingState`: the app's own submissions,
/// the server's order events and account snapshots.
///
/// `reduce` is a pure function of its two arguments: no I/O, clock, randomness, global state or logging, so the same
/// actions give the same state wherever and whenever they are applied. No input makes it trap: sums saturate, nothing
/// divides by a number that can be 0 or negative, and nothing is force-unwrapped or indexed unchecked. In short:
///
/// - **Events.** An event numbered 0 or with an empty epoch is malformed and changes nothing. An event of the state's
///   epoch (or of any epoch while the state has none) that is not numbered above `lastEventSeq` is a repeat or a late
///   arrival and changes nothing, not even the epoch. An event of a different epoch is an epoch change (below) and is
///   then applied to the emptied state. Any other event sets `lastEventSeq` to its own number, across a jump too
///   (ledger entries carry absolute cash and positions, so the state heals), and is then applied. An event with no
///   payload, or one the rules below cannot use, changes nothing else.
/// - **Epoch change.** Orders, ledger and positions are emptied, `lastEventSeq` goes back to 0, `epochChanges` goes up
///   and the epoch is the new one. Cash stays, because a state has no "unknown cash" and the next ledger entry or
///   account sets it. The first epoch the state sees is adopted without any of this.
/// - **Orders.** A submit makes a `.pending` row at the front; a second submit with the same client order id is
///   ignored. `submitRejected` and the `rejected` event end a `.pending` or `.unknown` row as `.rejected`;
///   `submitUnconfirmed` turns a `.pending` row `.unknown`. The `accepted` event takes such a row (found by client
///   order id) to `.accepted` with the server's id and fields (a limit price of 0 on the wire means none), and makes a
///   row of its own for an order the app never saw, which is how a relaunch rebuilds the list from the replayed log.
///   A `.filled`, `.cancelled` or `.rejected` row never changes again.
/// - **Fills.** A `fill` event (found by server order id) adds its shares to an `.accepted` or `.partiallyFilled`
///   row and sets the average price to the half-up volume-weighted mean of all its fills, worked out from the exact
///   total; the server's `remaining` decides between `.partiallyFilled` and `.filled`. A fill of no shares or at a
///   negative price is ignored. A `cancelled` event ends such a row as `.cancelled`, keeping what it filled; the reason
///   it carries, if any, becomes the row's `rejectReason`.
/// - **Ledger.** A `ledgerEntry` event sets cash and the position of its symbol to the absolute numbers it carries (a
///   position of 0 or less removes the entry) and adds a ledger row at the front, once per ledger sequence number.
/// - **Accounts.** A snapshot with no epoch is ignored, and so is one of the state's epoch that is older than the
///   state (its `lastEventSeq` is lower). One of a different epoch is an epoch change. Otherwise cash and positions
///   are replaced (only quantities above 0 are kept) and, with `adoptEventSeq`, so is `lastEventSeq`. The orders and
///   the ledger of the same epoch are never touched; a snapshot of another epoch empties them first.
/// - **Clear.** Everything is emptied as at launch, except that `epochChanges` is kept.
public enum TradingReducer {
    /// Applies `action` to `state`.
    public static func reduce(_ state: inout TradingState, _ action: TradingAction) {
        switch action {
        case .localSubmitted(let draft, let createdNs):
            state.submit(draft, createdNs: createdNs)
        case .submitRejected(let clientOrderId, let reason):
            state.reject(clientOrderId: clientOrderId, reason: reason)
        case .submitUnconfirmed(let clientOrderId):
            state.changeRow(clientOrderId: clientOrderId) { row in
                if row.status == .pending { row.status = .unknown }
            }
        case .event(let event):
            state.applyEvent(event)
        case .account(let account, let adoptEventSeq):
            state.applyAccount(account, adoptEventSeq: adoptEventSeq)
        case .clear:
            let changes = state.epochChanges
            state = TradingState()
            state.epochChanges = changes
        }
    }
}

private extension TradingState {
    // MARK: Rows

    /// Applies `change` to the row whose client order id is `clientOrderId`; false if there is no such row.
    @discardableResult
    mutating func changeRow(clientOrderId: String, _ change: (inout OrderRow) -> Void) -> Bool {
        guard let index = orders.firstIndex(where: { $0.id == clientOrderId }) else { return false }
        change(&orders[index])
        return true
    }

    /// Applies `change` to the row the server knows as `orderId`, if there is one.
    mutating func changeRow(orderId: String, _ change: (inout OrderRow) -> Void) {
        guard let index = orders.firstIndex(where: { $0.orderId == orderId }) else { return }
        change(&orders[index])
    }

    /// A second submit of one id is ignored: two rows with one id would break a list that is keyed by it.
    mutating func submit(_ draft: OrderDraft, createdNs: Int64) {
        guard !orders.contains(where: { $0.id == draft.clientOrderId }) else { return }
        let row = OrderRow(
            id: draft.clientOrderId, symbolId: draft.symbolId, side: draft.side, type: draft.type,
            quantity: draft.quantity, limitPrice: draft.limitPrice, createdNs: createdNs)
        orders.insert(row, at: 0)
    }

    /// Ends a row that is still waiting for its answer as `.rejected`.
    mutating func reject(clientOrderId: String, reason: RejectReason?) {
        changeRow(clientOrderId: clientOrderId) { row in
            guard row.isUnanswered else { return }
            row.status = .rejected
            row.rejectReason = reason
        }
    }

    // MARK: Epochs

    /// Forgets what belongs to the epoch the state holds, because the server has started another: the rows, the ledger,
    /// the positions and the sequence go, and the change is counted. Cash stays, since a state has no "unknown cash"
    /// and the next ledger entry or snapshot sets it. The caller, which has checked that the new epoch is not empty
    /// and differs from the held one, then takes the new epoch.
    mutating func leaveEpoch() {
        orders = []
        ledger = []
        positions = [:]
        lastEventSeq = 0
        epochChanges = saturatingSum(epochChanges, 1)
    }

    // MARK: Events

    /// The gate every event passes (see the rules above), then the payload.
    mutating func applyEvent(_ event: Tp_OrderEvent) {
        guard event.eventSeq != 0, !event.serverEpoch.isEmpty else { return }
        let isNewEpoch = epoch != nil && epoch != event.serverEpoch
        // Judged before anything changes, so that an event that is turned away leaves not even the epoch behind.
        guard isNewEpoch || event.eventSeq > lastEventSeq else { return }
        if isNewEpoch { leaveEpoch() }
        epoch = event.serverEpoch
        lastEventSeq = event.eventSeq
        switch event.event {
        case .accepted(let accepted)?:
            applyAccepted(accepted, atNs: event.serverTsNs)
        case .rejected(let rejected)?:
            reject(clientOrderId: rejected.clientOrderID, reason: RejectReason(wire: rejected.reason))
        case .fill(let fill)?:
            applyFill(fill)
        case .cancelled(let cancelled)?:
            applyCancelled(cancelled)
        case .ledgerEntry(let entry)?:
            applyLedgerEntry(entry)
        case nil:
            break
        }
    }

    /// The server accepted an order: it takes the row of the same client order id that is waiting for it, or makes a
    /// row when the app has none, stamped with the server's time. Without a server id the order could never be found
    /// again by its fills, so the event is of no use.
    mutating func applyAccepted(_ accepted: Tp_OrderAccepted, atNs timestamp: Int64) {
        guard !accepted.orderID.isEmpty else { return }
        let mappedSide = Side(wire: accepted.side)
        let mappedType = OrderType(wire: accepted.type)
        let limitPrice = accepted.limitPrice == 0 ? nil : Price(satang: accepted.limitPrice)
        let found = changeRow(clientOrderId: accepted.clientOrderID) { row in
            guard row.isUnanswered else { return }
            row.orderId = accepted.orderID
            row.status = .accepted
            row.symbolId = accepted.symbolID
            row.side = mappedSide ?? row.side
            row.type = mappedType ?? row.type
            row.quantity = accepted.quantity
            row.limitPrice = limitPrice
        }
        guard !found, !accepted.clientOrderID.isEmpty, let side = mappedSide, let type = mappedType else { return }
        let row = OrderRow(
            id: accepted.clientOrderID, orderId: accepted.orderID, symbolId: accepted.symbolID, side: side, type: type,
            quantity: accepted.quantity, limitPrice: limitPrice, status: .accepted, createdNs: timestamp)
        orders.insert(row, at: 0)
    }

    /// A fill with no shares or a negative price is malformed and leaves the row alone, and one for an order that is
    /// not open is ignored. Cash and positions do not come from here: the ledger entry that follows a fill sets them.
    mutating func applyFill(_ fill: Tp_OrderFill) {
        guard fill.quantity > 0, fill.price >= 0 else { return }
        changeRow(orderId: fill.orderID) { row in
            guard row.isOpen else { return }
            row.addFill(quantity: fill.quantity, price: fill.price)
            row.status = fill.remaining <= 0 ? .filled : .partiallyFilled
        }
    }

    /// Only an open order can be cancelled, and what it filled stays. The reason is the engine's when it cancelled the
    /// rest itself (no liquidity, say) and nil for an ordinary cancel.
    mutating func applyCancelled(_ cancelled: Tp_OrderCancelled) {
        changeRow(orderId: cancelled.orderID) { row in
            guard row.isOpen else { return }
            row.status = .cancelled
            row.rejectReason = RejectReason(wire: cancelled.reason)
        }
    }

    /// Cash and the position are the absolute numbers after the fill, so they are set, never added to.
    mutating func applyLedgerEntry(_ entry: Tp_LedgerEntry) {
        cash = entry.cashAfter
        positions[entry.symbolID] = entry.positionAfter > 0 ? entry.positionAfter : nil
        guard let side = Side(wire: entry.side), !ledger.contains(where: { $0.id == entry.ledgerSeq }) else { return }
        let row = LedgerRow(
            id: entry.ledgerSeq, orderId: entry.orderID, symbolId: entry.symbolID, side: side,
            quantity: entry.quantity, price: Price(satang: entry.price), commission: entry.commission,
            cashDelta: entry.cashDelta, tsNs: entry.tsNs)
        ledger.insert(row, at: 0)
    }

    // MARK: Accounts

    /// A snapshot replaces cash and positions, and leaves the orders and the ledger to the event log. The orders and
    /// the ledger of the same epoch are never touched; a snapshot of another epoch empties them first.
    mutating func applyAccount(_ account: AccountDTO, adoptEventSeq: Bool) {
        guard !account.epoch.isEmpty else { return }
        let isNewEpoch = epoch != nil && epoch != account.epoch
        // A snapshot older than the state would undo newer events, and adopting its number would replay them.
        guard isNewEpoch || account.lastEventSeq >= lastEventSeq else { return }
        if isNewEpoch { leaveEpoch() }
        epoch = account.epoch
        cash = account.cash
        positions = [:]
        for position in account.positions where position.quantity > 0 {
            positions[position.symbolId] = position.quantity
        }
        if adoptEventSeq { lastEventSeq = account.lastEventSeq }
    }
}

private extension OrderRow {
    /// Waiting for the server's answer: `.pending`, or `.unknown` when the answer was lost.
    var isUnanswered: Bool {
        status == .pending || status == .unknown
    }

    /// Accepted and not over: it can still be filled or cancelled.
    var isOpen: Bool {
        status == .accepted || status == .partiallyFilled
    }

    /// Adds one fill of `quantity` shares at `price` (both checked by the caller). The average is worked out from the
    /// exact total of all fills, so it does not drift with every rounding.
    mutating func addFill(quantity: Quantity, price: Int64) {
        filledQuantity = saturatingSum(filledQuantity, quantity)
        filledNotional = saturatingSum(filledNotional, Int128(price) * Int128(quantity))
        averageFillPrice = Self.average(notional: filledNotional, shares: filledQuantity)
    }

    /// `notional / shares` rounded half up to a whole satang (and clamped to `Int64`), or nil without shares to divide
    /// by. It is `(2 * notional + shares) / (2 * shares)` worked out as a quotient and a remainder, so that doubling a
    /// notional near the top of its 128 bits cannot overflow. Fills never make a negative notional; a row built by
    /// hand with a negative average can, and then the quotient is rounded toward zero.
    static func average(notional: Int128, shares: Quantity) -> Price? {
        guard shares > 0 else { return nil }
        let divisor = Int128(shares)
        let (whole, rest) = notional.quotientAndRemainder(dividingBy: divisor)
        return Price(satang: Int64(clamping: rest * 2 >= divisor ? whole + 1 : whole))
    }
}

/// `lhs + rhs`, or the largest value of the type when the sum does not fit. Every sum in this file adds a number that
/// is not negative, so there is no lower bound to saturate at.
private func saturatingSum<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : sum
}

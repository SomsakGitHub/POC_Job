import Contracts
import ExchangeCore
import GRPCCore
import TradeCore

// The order service's conversions between the engine's values and the `tp` wire messages. The enum mappings are the
// shared ones of `Contracts` (`init?(wire:)`, `wire`). Every message is built by property assignment, so a field added
// to the proto never shifts a positional argument.

extension OrderRequest {
    /// The longest client order id accepted, in UTF-8 bytes. The engine remembers every client order id of an epoch,
    /// without bound, so the size of each key is bounded here.
    static let maxClientOrderIdBytes = 64

    /// The engine's order for a `SubmitOrder` request. A `limit_price` of 0 means "no price" and becomes nil: a market
    /// order ignores it and the engine refuses a limit order without one (`.invalidTick`).
    ///
    /// Throws `invalidArgument` only for a request that is malformed rather than against the rules: a side or type that
    /// is unspecified or unknown to this build, or a client order id that is empty or longer than 64 UTF-8 bytes.
    /// Every other fault (quantity, lot, tick, band, symbol, funds) is the engine's business reject.
    init(wire: Tp_SubmitOrderRequest) throws(RPCError) {
        guard let side = Side(wire: wire.side) else {
            throw RPCError(code: .invalidArgument, message: "side must be SIDE_BUY or SIDE_SELL")
        }
        guard let type = OrderType(wire: wire.type) else {
            throw RPCError(code: .invalidArgument, message: "type must be ORDER_TYPE_MARKET or ORDER_TYPE_LIMIT")
        }
        let idBytes = wire.clientOrderID.utf8.count
        guard (1...Self.maxClientOrderIdBytes).contains(idBytes) else {
            throw RPCError(
                code: .invalidArgument,
                message: "client_order_id must be 1 to \(Self.maxClientOrderIdBytes) UTF-8 bytes, got \(idBytes)"
            )
        }
        self.init(
            clientOrderId: wire.clientOrderID, symbolId: wire.symbolID, side: side, type: type,
            quantity: wire.quantity, limitPrice: wire.limitPrice == 0 ? nil : Price(satang: wire.limitPrice)
        )
    }
}

extension Tp_SubmitOrderResponse {
    /// The answer to `SubmitOrder` for the engine's outcome: accepted with the order id, or refused with the reason and
    /// no id. Both carry the engine's timing, which for a repeated client order id is the stored one.
    init(outcome: SubmitOutcome) {
        self.init()
        switch outcome {
        case .accepted(let orderId, let timing):
            accepted = true
            orderID = orderId
            self.timing = Tp_ServerTiming(timing: timing)
        case .rejected(let reason, let timing):
            accepted = false
            rejectReason = reason.wire
            self.timing = Tp_ServerTiming(timing: timing)
        }
    }
}

extension Tp_ServerTiming {
    /// The engine's receive and answer times, in nanoseconds since the Unix epoch.
    init(timing: ServerTimingNs) {
        self.init()
        recvNs = timing.recvNs
        ackNs = timing.ackNs
    }
}

extension RPCError {
    /// The status for an event stream the log can no longer serve: `outOfRange`, with the oldest event still kept, so
    /// a client knows it missed events and must reload its state instead of resuming.
    init(eventLogError: EventLogError) {
        switch eventLogError {
        case .outOfRange(let oldestRetained):
            self.init(
                code: .outOfRange,
                message: "the events asked for are no longer kept; the oldest kept is event_seq \(oldestRetained)"
            )
        }
    }
}

extension Tp_OrderEvent {
    /// The wire form of one logged event: its place, epoch and time, and the payload in the matching `oneof` case.
    /// A cancel with no reason (the client asked for it) carries `REJECT_REASON_UNSPECIFIED`; an order without a limit
    /// price carries 0.
    public init(record: OrderEventRecord) {
        self.init()
        eventSeq = record.seq
        serverEpoch = record.epoch
        serverTsNs = record.tsNs
        switch record.payload {
        case .accepted(let orderId, let clientOrderId, let symbolId, let side, let type, let quantity, let limitPrice):
            var message = Tp_OrderAccepted()
            message.orderID = orderId
            message.clientOrderID = clientOrderId
            message.symbolID = symbolId
            message.side = side.wire
            message.type = type.wire
            message.quantity = quantity
            message.limitPrice = limitPrice?.satang ?? 0
            event = .accepted(message)
        case .rejected(let clientOrderId, let reason):
            var message = Tp_OrderRejected()
            message.clientOrderID = clientOrderId
            message.reason = reason.wire
            event = .rejected(message)
        case .fill(let orderId, let symbolId, let side, let quantity, let price, let remaining):
            var message = Tp_OrderFill()
            message.orderID = orderId
            message.symbolID = symbolId
            message.side = side.wire
            message.quantity = quantity
            message.price = price.satang
            message.remaining = remaining
            event = .fill(message)
        case .cancelled(let orderId, let remaining, let reason):
            var message = Tp_OrderCancelled()
            message.orderID = orderId
            message.remaining = remaining
            message.reason = reason?.wire ?? .unspecified
            event = .cancelled(message)
        case .ledger(let entry):
            event = .ledgerEntry(Tp_LedgerEntry(entry: entry))
        }
    }
}

extension Tp_LedgerEntry {
    /// Every field of a ledger entry, amounts in satang.
    init(entry: LedgerEntry) {
        self.init()
        ledgerSeq = entry.ledgerSeq
        orderID = entry.orderId
        symbolID = entry.symbolId
        side = entry.side.wire
        quantity = entry.quantity
        price = entry.price.satang
        commission = entry.commission
        cashDelta = entry.cashDelta
        cashAfter = entry.cashAfter
        positionAfter = entry.positionAfter
        tsNs = entry.tsNs
    }
}

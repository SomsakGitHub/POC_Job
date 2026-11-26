import TradeCore

/// What happened to an order or to the account, as the exchange engine reports it to its clients. All of it is
/// simulated.
public enum OrderEventPayload: Sendable, Equatable {
    /// The order passed every check, got `orderId` and, for a buy, reserved its cash (a sell, its shares). It comes
    /// before every fill of the order.
    case accepted(
        orderId: String, clientOrderId: String, symbolId: UInt32, side: Side, type: OrderType, quantity: Quantity,
        limitPrice: Price?
    )
    /// The order was refused and got no id; nothing was reserved and the ledger is unchanged.
    case rejected(clientOrderId: String, reason: RejectReason)
    /// Part or all of the order traded: `quantity` shares at `price`. `remaining` is what the order still wants after
    /// this fill; 0 means it is complete and no further event of it follows. The next record is always this fill's
    /// `ledger` event.
    case fill(orderId: String, symbolId: UInt32, side: Side, quantity: Quantity, price: Price, remaining: Quantity)
    /// The order stopped with `remaining` shares unfilled and its reservation released. `reason` is nil for a cancel
    /// the client asked for, `.noLiquidity` for the part of a market order the book could not fill, and
    /// `.insufficientFunds` or `.insufficientPosition` when the ledger refused a fill.
    case cancelled(orderId: String, remaining: Quantity, reason: RejectReason?)
    /// The ledger entry a fill made: the cash and position after it.
    case ledger(LedgerEntry)
}

/// One event in the log: its place (`seq`), the epoch it belongs to, when it happened and what it was.
public struct OrderEventRecord: Sendable, Equatable {
    /// 1 for the first event of an epoch, then 2, 3 and so on with no gap.
    public let seq: UInt64
    /// The engine's epoch when the event was logged. A client that holds another epoch's `seq` must start over.
    public let epoch: String
    /// When the event happened, in nanoseconds since the Unix epoch, from the engine's clock.
    public let tsNs: Int64
    public let payload: OrderEventPayload

    public init(seq: UInt64, epoch: String, tsNs: Int64, payload: OrderEventPayload) {
        self.seq = seq
        self.epoch = epoch
        self.tsNs = tsNs
        self.payload = payload
    }
}

/// Why `EventLog.events(after:)` could not answer.
public enum EventLogError: Error, Equatable {
    /// The first record asked for is no longer kept; `oldestRetained` is the oldest `seq` the log still has. A client
    /// that gets this has missed events and must reload its state instead of resuming.
    case outOfRange(oldestRetained: UInt64)
}

/// The engine's log of order events: the newest `capacity` records, numbered without a gap, so that a client that
/// reconnects can ask for everything after the last `seq` it saw.
///
/// A value type kept in a `RingBuffer`, so appending is O(1) and the oldest record is dropped once the log is full;
/// `seq` keeps counting regardless, so a dropped record is never renumbered.
public struct EventLog: Sendable {
    private var records: RingBuffer<OrderEventRecord>

    /// The `seq` of the newest record; 0 before the first append.
    public private(set) var lastSeq: UInt64 = 0

    /// An empty log that keeps the newest `capacity` records. A capacity below 1 is taken as 1.
    public init(capacity: Int = 10_000) {
        records = RingBuffer(capacity: capacity)
    }

    /// Appends `p` as the next record (`lastSeq + 1`), dropping the oldest when the log is full, and returns it.
    public mutating func append(_ p: OrderEventPayload, epoch: String, tsNs: Int64) -> OrderEventRecord {
        lastSeq += 1
        let record = OrderEventRecord(seq: lastSeq, epoch: epoch, tsNs: tsNs, payload: p)
        records.append(record)
        return record
    }

    /// The records with a `seq` greater than `seq`, oldest first: `[]` when `seq` is `lastSeq` or later (an empty log
    /// included). Throws `.outOfRange` exactly when the first record wanted, `seq + 1`, has been dropped, since an
    /// answer without it would hide a gap.
    public func events(after seq: UInt64) throws(EventLogError) -> [OrderEventRecord] {
        guard seq < lastSeq else { return [] }
        let oldestRetained = lastSeq - UInt64(records.count) + 1
        guard seq + 1 >= oldestRetained else { throw .outOfRange(oldestRetained: oldestRetained) }
        let first = Int(seq + 1 - oldestRetained)
        return (first..<records.count).map { records[$0] }
    }
}

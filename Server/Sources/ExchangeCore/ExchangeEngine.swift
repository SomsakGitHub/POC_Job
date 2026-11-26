import struct Foundation.UUID
import TradeCore

/// An order as a client sends it. `clientOrderId` is the client's own key for it: sending the same request again with
/// the same key returns the first answer instead of placing a second order.
public struct OrderRequest: Sendable, Equatable {
    public let clientOrderId: String
    public let symbolId: UInt32
    public let side: Side
    public let type: OrderType
    public let quantity: Quantity
    /// The worst price a limit order accepts; a market order ignores it.
    public let limitPrice: Price?

    public init(
        clientOrderId: String, symbolId: UInt32, side: Side, type: OrderType, quantity: Quantity, limitPrice: Price?
    ) {
        self.clientOrderId = clientOrderId
        self.symbolId = symbolId
        self.side = side
        self.type = type
        self.quantity = quantity
        self.limitPrice = limitPrice
    }
}

/// When the engine received an order and when it had answered it, in nanoseconds since the Unix epoch, from the
/// engine's clock. The span covers only the engine's own work on the order inside the actor, immediate fills included,
/// and not the wait for the actor or any network time: it is the server's part of a round trip, never the whole of it.
public struct ServerTimingNs: Sendable, Equatable {
    public let recvNs: Int64
    public let ackNs: Int64

    public init(recvNs: Int64, ackNs: Int64) {
        self.recvNs = recvNs
        self.ackNs = ackNs
    }
}

/// The engine's answer to an order: accepted under a new order id, or rejected with a reason.
public enum SubmitOutcome: Sendable, Equatable {
    case accepted(orderId: String, timing: ServerTimingNs)
    case rejected(RejectReason, timing: ServerTimingNs)
}

/// The account at one moment: the epoch, cash in satang, shares per symbol (no zero entries), and the `seq` of the
/// newest event and of the newest ledger entry (0 when there is none), all read together.
public struct AccountSnapshot: Sendable, Equatable {
    public let epoch: String
    public let cash: Int64
    public let positions: [UInt32: Quantity]
    public let lastEventSeq: UInt64
    public let lastLedgerSeq: UInt64

    public init(
        epoch: String, cash: Int64, positions: [UInt32: Quantity], lastEventSeq: UInt64, lastLedgerSeq: UInt64
    ) {
        self.epoch = epoch
        self.cash = cash
        self.positions = positions
        self.lastEventSeq = lastEventSeq
        self.lastLedgerSeq = lastLedgerSeq
    }
}

/// A limit order waiting in the order table for the market to reach its price.
private struct RestingOrder {
    let orderId: String
    let symbolId: UInt32
    let side: Side
    let limit: Price
    var remaining: Quantity
}

/// The mock exchange: one simulated market, one demo account (`Ledger`), the event log and the table of resting orders,
/// all owned by one actor. Every method is synchronous inside the actor, so each call is atomic: no other call sees a
/// half-placed order or a half-applied fill. Everything it trades is simulated.
///
/// **Orders.** `submit` checks an order in a fixed order (duplicate client id, unknown symbol, quantity, lot, tick,
/// band, then funds or shares) and the first failure rejects it with one `rejected` event and no ledger change; a
/// rejection takes no order id, so ids run `O-000001`, `O-000002`, ... without a gap. An id names one order for the
/// whole life of the engine, across resets, because a cancel names its order by id alone. A market order
/// sweeps the book at once, reserving the swept shares at the worst price it reaches, and the part the book could not
/// fill is cancelled with `.noLiquidity`. A limit order reserves at its limit, sweeps whatever of the book is inside
/// it, and rests with the rest. Resting orders fill on `advance`, at their limit, against the best level of the quote.
/// A fill's book liquidity comes out of the simulated book; a resting fill takes nothing from it.
///
/// **Events.** Every record carries the current epoch. `accepted` comes before an order's fills; every `fill` is
/// followed at once by its `ledger` event.
///
/// **Epoch.** A random id drawn at start and at every `reset()`, never derived from the seed or the clock, so a
/// restarted server is a new epoch even with the same seed. A client that holds another epoch's `seq` replays from the
/// start.
///
/// **Clock.** `nowNs` is the only clock read: once at start (the market starts at that time), once per event, once
/// per fill (shared by the fill event, its ledger entry and the ledger event), and twice per order for its timing.
public actor ExchangeEngine {
    private let nowNs: @Sendable () -> Int64
    private let eventLogCapacity: Int
    private let startingCash: Int64
    private let commissionBps: Int
    /// The symbols the market serves, in the order given; the first of any id wins, as in the market.
    private let servedSymbols: [SymbolInfo]
    private let referenceById: [UInt32: Price]

    private var market: SimulatedMarket
    private var ledger: Ledger
    private var log: EventLog
    /// Live resting orders in order of acceptance, which is the order `advance` serves them in.
    private var resting: [RestingOrder] = []
    /// Every request of this epoch by client order id, with its first outcome. It grows for the whole epoch, without
    /// bound, and only `reset()` clears it: a retry is recognised however late it comes.
    private var submitted: [String: (request: OrderRequest, outcome: SubmitOutcome)] = [:]
    /// The number of the next accepted order. `reset()` leaves it alone, so an id from before a reset never names a
    /// new order and a late cancel of it cannot touch one.
    private var nextOrderNumber = 1
    private var streams: [Int: AsyncStream<OrderEventRecord>.Continuation] = [:]
    private var nextStreamId = 0

    /// The current epoch: a random UUID string, new at every `reset()`.
    public private(set) var epoch: String

    /// An engine over `symbols` (a symbol the market cannot serve is left out), with a market seeded by `seed` and
    /// started at the clock's current time. `startingCash` and `commissionBps` go to the ledger as they are.
    public init(
        symbols: [SymbolInfo], seed: UInt64, nowNs: @escaping @Sendable () -> Int64, eventLogCapacity: Int = 10_000,
        startingCash: Int64 = 100_000_000, commissionBps: Int = 15
    ) {
        let market = SimulatedMarket(symbols: symbols, seed: seed, startMs: nowNs() / 1_000_000)
        var served: [SymbolInfo] = []
        var referenceById: [UInt32: Price] = [:]
        for info in symbols where referenceById[info.id] == nil && market.quote(info.id) != nil {
            served.append(info)
            referenceById[info.id] = info.reference
        }
        self.market = market
        self.nowNs = nowNs
        self.eventLogCapacity = eventLogCapacity
        self.startingCash = startingCash
        self.commissionBps = commissionBps
        servedSymbols = served
        self.referenceById = referenceById
        ledger = Ledger(startingCash: startingCash, commissionBps: commissionBps)
        log = EventLog(capacity: eventLogCapacity)
        epoch = UUID().uuidString
    }

    /// Moves the market to `toMs`, then serves the resting orders once each, oldest first, and returns the quotes the
    /// market changed (in catalog order). A resting order fills at its limit for at most what the quote's best level
    /// shows, less what older resting orders on that symbol already took from it in this call, so two orders never
    /// fill the same shares; it fills at most once per call.
    public func advance(toMs: Int64, updatesPerSymbolPerSecond: Double) -> [SymbolQuote] {
        let changed = market.advance(toMs: toMs, updatesPerSymbolPerSecond: updatesPerSymbolPerSecond)
        var takenFromAsk: [UInt32: Quantity] = [:]
        var takenFromBid: [UInt32: Quantity] = [:]
        var stillResting: [RestingOrder] = []
        for var order in resting {
            guard var quote = market.quote(order.symbolId) else {
                stillResting.append(order)
                continue
            }
            switch order.side {
            case .buy: quote.askQty -= takenFromAsk[order.symbolId, default: 0]
            case .sell: quote.bidQty -= takenFromBid[order.symbolId, default: 0]
            }
            if let fill = Matching.restingFill(
                side: order.side, limit: order.limit, remaining: order.remaining, quote: quote
            ) {
                switch order.side {
                case .buy: takenFromAsk[order.symbolId, default: 0] += fill.quantity
                case .sell: takenFromBid[order.symbolId, default: 0] += fill.quantity
                }
                let left = record(fill, of: order.orderId, symbolId: order.symbolId, side: order.side,
                                  remaining: order.remaining)
                order.remaining = left ?? 0
            }
            if order.remaining > 0 { stillResting.append(order) }
        }
        resting = stillResting
        return changed
    }

    /// The current quote of every symbol, in catalog order.
    public func quotes() -> [SymbolQuote] {
        servedSymbols.compactMap { market.quote($0.id) }
    }

    /// The newest `limit` candles of a symbol, oldest first, as the market keeps them.
    public func candles(symbolId: UInt32, interval: CandleInterval, limit: Int) -> [Candle] {
        market.history(symbolId: symbolId, interval: interval, limit: limit)
    }

    /// The symbols the engine trades, in catalog order.
    public func symbols() -> [SymbolInfo] {
        servedSymbols
    }

    /// Checks, places and, as far as the book allows, fills an order; see the type's notes for the rules.
    ///
    /// The same `clientOrderId` with an equal request returns the stored outcome, its timing included, and changes
    /// nothing; with a different request it is rejected with `.invalidDuplicate` (one `rejected` event) and the stored
    /// outcome stays. Every client order id of the epoch is remembered, without bound, until `reset()`. The timing is
    /// the first and the last clock reading of the call.
    public func submit(_ r: OrderRequest) -> SubmitOutcome {
        let recvNs = nowNs()
        if let earlier = submitted[r.clientOrderId] {
            if earlier.request == r { return earlier.outcome }
            return reject(r, .invalidDuplicate, recvNs: recvNs)
        }
        let outcome = place(r, recvNs: recvNs)
        submitted[r.clientOrderId] = (r, outcome)
        return outcome
    }

    /// Cancels a live resting order: its reservation is released and a `cancelled` event with no reason is logged.
    /// False, with nothing logged, for an id that is unknown, finished, already cancelled or a market order.
    public func cancel(orderId: String) -> Bool {
        guard let index = resting.firstIndex(where: { $0.orderId == orderId }) else { return false }
        let order = resting.remove(at: index)
        ledger.release(orderId: orderId)
        append(.cancelled(orderId: orderId, remaining: order.remaining, reason: nil))
        return true
    }

    private func place(_ r: OrderRequest, recvNs: Int64) -> SubmitOutcome {
        guard let reference = referenceById[r.symbolId], let depth = market.depth(r.symbolId) else {
            return reject(r, .unknownSymbol, recvNs: recvNs)
        }
        let reason = TickRules.validate(type: r.type, quantity: r.quantity, limit: r.limitPrice, reference: reference)
        if let reason {
            return reject(r, reason, recvNs: recvNs)
        }
        // Before any sweep, so the reason does not depend on how deep the book is.
        if r.side == .sell && ledger.availableQuantity(symbolId: r.symbolId) < r.quantity {
            return reject(r, .insufficientPosition, recvNs: recvNs)
        }
        let limit = r.type == .limit ? r.limitPrice : nil
        let sweep = Matching.sweep(side: r.side, quantity: r.quantity, limit: limit, depth: depth)
        let orderId = Self.orderId(nextOrderNumber)
        let reservation: (quantity: Quantity, price: Price)?
        if let limit {
            reservation = (r.quantity, limit)
        } else {
            // A market order reserves what it sweeps at the worst price it reaches; an empty side reserves nothing.
            reservation = sweep.fills.last.map { (r.quantity - sweep.remaining, $0.price) }
        }
        if let reservation, !ledger.reserve(
            orderId: orderId, side: r.side, symbolId: r.symbolId, quantity: reservation.quantity,
            price: reservation.price
        ) {
            return reject(r, r.side == .buy ? .insufficientFunds : .insufficientPosition, recvNs: recvNs)
        }
        nextOrderNumber += 1
        append(.accepted(
            orderId: orderId, clientOrderId: r.clientOrderId, symbolId: r.symbolId, side: r.side, type: r.type,
            quantity: r.quantity, limitPrice: r.limitPrice
        ))
        var remaining: Quantity? = r.quantity
        var taken: [Fill] = []
        for fill in sweep.fills {
            guard let left = remaining else { break }
            remaining = record(fill, of: orderId, symbolId: r.symbolId, side: r.side, remaining: left)
            if remaining != nil { taken.append(fill) }
        }
        if !taken.isEmpty {
            market.updateDepth(r.symbolId) { $0.consume(side: r.side, fills: taken) }
        }
        if let remaining, remaining > 0 {
            if let limit {
                resting.append(RestingOrder(
                    orderId: orderId, symbolId: r.symbolId, side: r.side, limit: limit, remaining: remaining
                ))
            } else {
                append(.cancelled(orderId: orderId, remaining: remaining, reason: .noLiquidity))
            }
        }
        return .accepted(orderId: orderId, timing: ServerTimingNs(recvNs: recvNs, ackNs: nowNs()))
    }

    /// Logs one `rejected` event and returns the rejection; nothing else changes.
    private func reject(_ r: OrderRequest, _ reason: RejectReason, recvNs: Int64) -> SubmitOutcome {
        append(.rejected(clientOrderId: r.clientOrderId, reason: reason))
        return .rejected(reason, timing: ServerTimingNs(recvNs: recvNs, ackNs: nowNs()))
    }

    /// Applies one fill of an order with `remaining` shares to the ledger and logs its `fill` and `ledger` events, one
    /// clock reading for all three. Returns what the order has left, or nil when the ledger refused the fill: the
    /// order is then stopped, its reservation released and a `cancelled` event logged. That happens only when an
    /// amount would not fit in an `Int64`, which no real price and size comes near.
    private func record(
        _ fill: Fill, of orderId: String, symbolId: UInt32, side: Side, remaining: Quantity
    ) -> Quantity? {
        let tsNs = nowNs()
        guard let entry = ledger.applyFill(
            orderId: orderId, symbolId: symbolId, side: side, quantity: fill.quantity, price: fill.price, tsNs: tsNs
        ) else {
            ledger.release(orderId: orderId)
            let reason: RejectReason = side == .buy ? .insufficientFunds : .insufficientPosition
            append(.cancelled(orderId: orderId, remaining: remaining, reason: reason))
            return nil
        }
        let left = remaining - fill.quantity
        append(.fill(
            orderId: orderId, symbolId: symbolId, side: side, quantity: fill.quantity, price: fill.price,
            remaining: left
        ), tsNs: tsNs)
        append(.ledger(entry), tsNs: tsNs)
        return left
    }

    /// `O-` and the number in at least six digits: `O-000001`.
    private static func orderId(_ number: Int) -> String {
        let digits = String(number)
        return "O-" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    /// The events after `seq`, then every new event as it is logged, until the stream is finished by `reset()` or
    /// `dropStreams()` or the consumer stops. The buffer is unbounded, so no event is dropped or reordered.
    ///
    /// When `clientEpoch` is the current epoch the replay starts after `seq`; when it is nil or another epoch, `seq`
    /// belongs to no event of this epoch and the replay starts from the first event. Throws `.outOfRange` when the
    /// first event wanted is no longer in the log. The replay and the registration for live events happen in one
    /// actor turn, so the client sees no gap and no duplicate.
    public func eventStream(after seq: UInt64, clientEpoch: String?) throws(EventLogError)
        -> AsyncStream<OrderEventRecord> {
        let replay = try log.events(after: clientEpoch == epoch ? seq : 0)
        let (stream, continuation) = AsyncStream.makeStream(of: OrderEventRecord.self, bufferingPolicy: .unbounded)
        for replayed in replay {
            continuation.yield(replayed)
        }
        let id = nextStreamId
        nextStreamId += 1
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStream(id) }
        }
        streams[id] = continuation
        return stream
    }

    /// Finishes every live event stream without changing anything else; clients reconnect and resume.
    public func dropStreams() {
        let finishing = streams.values
        streams.removeAll()
        finishing.forEach { $0.finish() }
    }

    /// Starts a new epoch: a new epoch id, the account back to its starting cash, and no orders, events, remembered
    /// client order ids or live streams. Order ids keep counting, so no id is ever reused: a cancel names its order by
    /// id alone and an id from before the reset matches nothing. The simulated market carries on.
    public func reset() {
        dropStreams()
        epoch = UUID().uuidString
        ledger = Ledger(startingCash: startingCash, commissionBps: commissionBps)
        log = EventLog(capacity: eventLogCapacity)
        resting.removeAll()
        submitted.removeAll()
    }

    private func append(_ payload: OrderEventPayload, tsNs: Int64? = nil) {
        let logged = log.append(payload, epoch: epoch, tsNs: tsNs ?? nowNs())
        for continuation in streams.values {
            continuation.yield(logged)
        }
    }

    private func removeStream(_ id: Int) {
        streams[id] = nil
    }

    /// The account as of now, read in one turn.
    public func account() -> AccountSnapshot {
        AccountSnapshot(
            epoch: epoch, cash: ledger.cash, positions: ledger.positions, lastEventSeq: log.lastSeq,
            lastLedgerSeq: ledger.entries.last?.ledgerSeq ?? 0
        )
    }

    /// Up to `limit` ledger entries, newest first, starting below `before` (`ledgerSeq < before`) or from the newest
    /// when `before` is nil. A `limit` of 0 or less gives none.
    public func transactions(before ledgerSeq: UInt64?, limit: Int) -> [LedgerEntry] {
        guard limit > 0 else { return [] }
        let entries = ledger.entries
        // Entry i has ledgerSeq i + 1, so the entries below `before` are the first `before - 1`.
        let end = ledgerSeq.map { Int(clamping: min($0, UInt64(entries.count) + 1)) - 1 } ?? entries.count
        return Array(entries[..<max(end, 0)].suffix(limit).reversed())
    }

    /// A copy of the ledger, for tests.
    func ledgerSnapshot() -> Ledger {
        ledger
    }

    /// The streams still registered, for tests.
    var liveStreamCount: Int {
        streams.count
    }
}

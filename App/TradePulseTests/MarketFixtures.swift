import Contracts
import Synchronization
import Testing
import TradeCore
import TradeNetworking

// Frames, order events, snapshots, clocks and symbols for the app's tests. Every protobuf message is built by
// assigning its properties, never through a memberwise initialiser.

/// A switch that one task flips and another reads.
final class Flag: Sendable {
    /// Whether the flag has been set.
    private let value = Mutex(false)

    /// Flips the switch; it stays flipped.
    func set() {
        value.withLock { $0 = true }
    }

    /// Whether `set()` has been called.
    var isSet: Bool {
        value.withLock { $0 }
    }
}

/// A clock in nanoseconds that a test moves by hand.
final class ManualClock: Sendable {
    /// The time the clock reads now.
    private let now: Mutex<Int64>

    /// A clock that reads `start` until it is set.
    init(_ start: Int64) {
        now = Mutex(start)
    }

    /// Makes the clock read `value`.
    func set(_ value: Int64) {
        now.withLock { $0 = value }
    }

    /// The time the clock reads.
    func read() -> Int64 {
        now.withLock { $0 }
    }
}

/// The display's media clock in seconds, which a test moves by hand.
final class ManualMedia: Sendable {
    /// The time the clock reads now.
    private let now: Mutex<Double>

    /// A clock that reads `start` until it is set.
    init(_ start: Double) {
        now = Mutex(start)
    }

    /// Makes the clock read `value`.
    func set(_ value: Double) {
        now.withLock { $0 = value }
    }

    /// The time the clock reads.
    func read() -> Double {
        now.withLock { $0 }
    }
}

/// Waits until `condition` holds, yielding between looks, and says whether it did. The wait is bounded by a number of
/// looks and never by time: the work these tests wait for runs on the main actor, so every look gives it a turn, and
/// a condition that never comes true ends the wait after `rounds` looks instead of hanging the test.
@MainActor
func settle(rounds: Int = 100_000, _ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<rounds {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

/// Waits for `condition` like `settle`, and records a failure at the caller's line, saying what it waited for, when it
/// never holds.
@MainActor
func waitFor(
    _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: @MainActor () -> Bool
) async {
    let reached = await settle(condition)
    #expect(reached, "gave up waiting until \(what)", sourceLocation: sourceLocation)
}

/// Three symbols in an order that is neither by id nor by ticker, so that a list kept in the server's order can be
/// told from a sorted one.
let sampleSymbols: [SymbolDTO] = [
    SymbolDTO(id: 4, ticker: "PTT", nameTh: "ปตท.", nameEn: "PTT Public Company", reference: 3_425, lot: 100),
    SymbolDTO(
        id: 2, ticker: "AOT", nameTh: "ท่าอากาศยานไทย", nameEn: "Airports of Thailand", reference: 5_800, lot: 100
    ),
    SymbolDTO(id: 9, ticker: "CPALL", nameTh: "ซีพี ออลล์", nameEn: "CP ALL", reference: 5_000, lot: 100),
]

/// A wire candle whose four prices are all `price`.
private func wireCandle(openTimeMs: Int64, price: Int64) -> Tp_Candle {
    var candle = Tp_Candle()
    candle.openTimeMs = openTimeMs
    candle.open = price
    candle.high = price
    candle.low = price
    candle.close = price
    return candle
}

/// A full update for `symbol`: `last` is the price and the bid and ask sit 25 satang either side of it.
func symbolUpdate(symbol: UInt32 = 4, seq: UInt64, last: Int64 = 3_425) -> Tp_SymbolUpdate {
    var update = Tp_SymbolUpdate()
    update.symbolID = symbol
    update.seq = seq
    update.last = last
    update.bid = last - 25
    update.ask = last + 25
    update.bidQty = 1_000
    update.askQty = 2_000
    update.dayVolume = 10_000
    update.candle1S = wireCandle(openTimeMs: 1_000, price: last)
    update.candle1M = wireCandle(openTimeMs: 60_000, price: last)
    update.candle5M = wireCandle(openTimeMs: 300_000, price: last)
    return update
}

/// A frame stamped `sendNs` (0 is unstamped) that carries `updates`; no updates make a heartbeat.
func marketFrame(sendNs: Int64, updates: [Tp_SymbolUpdate]) -> Tp_MarketFrame {
    var frame = Tp_MarketFrame()
    frame.serverSendNs = sendNs
    frame.frameSeq = 1
    frame.updates = updates
    return frame
}

/// An order event of epoch `epoch`, numbered `seq`, that carries nothing yet.
private func orderEvent(_ seq: UInt64, epoch: String) -> Tp_OrderEvent {
    var event = Tp_OrderEvent()
    event.eventSeq = seq
    event.serverEpoch = epoch
    event.serverTsNs = 1_000
    return event
}

/// The server accepting the market order of 100 shares that the app sent as `client` and the server calls `order`.
func acceptedEvent(_ seq: UInt64, client: String, order: String, epoch: String = "E1") -> Tp_OrderEvent {
    var accepted = Tp_OrderAccepted()
    accepted.orderID = order
    accepted.clientOrderID = client
    accepted.symbolID = 4
    accepted.side = .buy
    accepted.type = .market
    accepted.quantity = 100
    var event = orderEvent(seq, epoch: epoch)
    event.accepted = accepted
    return event
}

/// The order `order` filling completely: 100 shares at 34.25.
func fillEvent(_ seq: UInt64, order: String, epoch: String = "E1") -> Tp_OrderEvent {
    var fill = Tp_OrderFill()
    fill.orderID = order
    fill.symbolID = 4
    fill.side = .buy
    fill.quantity = 100
    fill.price = 3_425
    fill.remaining = 0
    var event = orderEvent(seq, epoch: epoch)
    event.fill = fill
    return event
}

/// A snapshot whose last price is `last` satang and that has seen `gaps` gaps in the sequence; every other number is a
/// placeholder.
func snapshot(symbol: UInt32 = 4, last: Int64, gaps: Int = 0) -> SymbolSnapshot {
    let price = Price(satang: last)
    let candle = Candle(openTimeMs: 0, open: price, high: price, low: price, close: price, volume: 0)
    return SymbolSnapshot(
        symbolId: symbol, seq: 1, last: price, bid: price, ask: price, bidQty: 0, askQty: 0, dayVolume: 0,
        candle1s: candle, candle1m: candle, candle5m: candle, appliedAtNs: 0, gapCount: gaps
    )
}

/// The summary a recorder gives for exactly these samples: what a test compares a recorded metric against, because
/// the recorder keeps buckets and not the raw values.
func summary(of samples: [Int64]) -> PercentileSummary {
    var histogram = LatencyHistogram()
    for sample in samples {
        histogram.record(nanos: sample)
    }
    return histogram.summary()
}

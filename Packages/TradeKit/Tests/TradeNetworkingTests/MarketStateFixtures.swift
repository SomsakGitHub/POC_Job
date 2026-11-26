import Contracts
import Synchronization
import TradeCore
import TradeNetworking

// Frames, updates and a wired-up state for the market state tests. Every protobuf message is built by assigning its
// properties, never through a memberwise initialiser.

/// A wire candle whose four prices are all `price`, so a test can read a whole candle as one number.
func wireCandle(openTimeMs: Int64, price: Int64, volume: Int64 = 0) -> Tp_Candle {
    var candle = Tp_Candle()
    candle.openTimeMs = openTimeMs
    candle.open = price
    candle.high = price
    candle.low = price
    candle.close = price
    candle.volume = volume
    return candle
}

/// A full update for `symbol`: `last` is the price, the bid and ask sit 25 satang either side of it and the three
/// current candles close at it. The quantities and the volume follow `seq`, so two updates differ in every field.
/// With `candles` false the update carries no candle at all (the fields are unset, not zero).
func symbolUpdate(symbol: UInt32 = 1, seq: UInt64, last: Int64 = 3_425, candles: Bool = true) -> Tp_SymbolUpdate {
    let step = Int64(truncatingIfNeeded: seq)
    var update = Tp_SymbolUpdate()
    update.symbolID = symbol
    update.seq = seq
    update.last = last
    update.bid = last - 25
    update.ask = last + 25
    update.bidQty = 1_000 &+ step
    update.askQty = 2_000 &+ step
    update.dayVolume = 10_000 &+ step
    if candles {
        update.candle1S = wireCandle(openTimeMs: 1_000, price: last, volume: 1)
        update.candle1M = wireCandle(openTimeMs: 60_000, price: last, volume: 2)
        update.candle5M = wireCandle(openTimeMs: 300_000, price: last, volume: 3)
    }
    update.eventNs = 42
    return update
}

/// A frame stamped `sendNs` (0 is unstamped) that carries `updates`; no updates make a heartbeat.
func marketFrame(sendNs: Int64 = 1_000, frameSeq: UInt64 = 1, updates: [Tp_SymbolUpdate]) -> Tp_MarketFrame {
    var frame = Tp_MarketFrame()
    frame.serverSendNs = sendNs
    frame.frameSeq = frameSeq
    frame.updates = updates
    return frame
}

/// A clock a test moves by hand.
final class ManualClock: Sendable {
    private let now = Mutex<Int64>(0)

    func set(_ value: Int64) {
        now.withLock { $0 = value }
    }

    func read() -> Int64 {
        now.withLock { $0 }
    }
}

/// A market state over a recorder the test reads and a clock the test sets. The clock starts at 2,000 ns, a little
/// after the default receive time of a frame, so an applied sample is positive unless a test says otherwise.
struct StateRig {
    let latency = LatencyRecorder()
    let clock = ManualClock()
    let state: MarketState

    init() {
        let clock = clock
        clock.set(2_000)
        state = MarketState(latency: latency, nowNs: { clock.read() })
    }

    /// Applies one frame stamped `sendNs` and received at `receivedAtNs` that carries `updates` (none: a heartbeat);
    /// returns the symbols whose numbering jumped.
    @discardableResult
    func apply(_ updates: Tp_SymbolUpdate..., sendNs: Int64 = 1_000, receivedAtNs: Int64 = 1_500) -> [UInt32] {
        state.apply(frame: marketFrame(sendNs: sendNs, updates: updates), receivedAtNs: receivedAtNs)
    }

    /// How many samples the recorder holds for `metric`.
    func count(_ metric: LatencyMetric) -> Int {
        latency.summary(metric).count
    }
}

/// The summary a recorder gives for exactly these samples of `metric`: what a test compares a recorder against.
func summary(of samples: [Int64], metric: LatencyMetric = .tickToApp) -> PercentileSummary {
    let recorder = LatencyRecorder()
    for sample in samples {
        recorder.record(metric, nanos: sample)
    }
    return recorder.summary(metric)
}

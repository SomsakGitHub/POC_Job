import Contracts
import Synchronization
import TradeCore
import TradeNetworking
@testable import TradePulse

// Candles, a market state to feed and a rig around the detail screen's model, for the chart tests. Every protobuf
// message is built by assigning its properties, never through a memberwise initialiser.

/// A price in satang.
func satang(_ value: Int64) -> Price {
    Price(satang: value)
}

/// `count` candles of `interval`, ascending and one interval apart, the newest last. Each one is different from the
/// others in every field, so a test can tell which one it is looking at. The first opens at `firstOpenMs`, which is a
/// multiple of every interval's width.
func history(count: Int, interval: CandleInterval = .m1, firstOpenMs: Int64 = 600_000) -> [Candle] {
    (0..<count).map { index in
        let step = Int64(index)
        let base: Int64 = 3_400 + step
        return Candle(
            openTimeMs: firstOpenMs + step * Int64(interval.seconds) * 1_000, open: satang(base),
            high: satang(base + 5), low: satang(base - 5), close: satang(base + 1), volume: 100 + step
        )
    }
}

/// A candle that opens at `openTimeMs` and closes at `close`, with the other prices around 34.00.
func candle(openTimeMs: Int64, close: Int64 = 3_410, volume: Int64 = 50) -> Candle {
    Candle(
        openTimeMs: openTimeMs, open: satang(3_400), high: satang(max(3_420, close)), low: satang(min(3_390, close)),
        close: satang(close), volume: volume
    )
}

/// The candle the feed has not sent yet: every field 0.
let noCandle = Candle(openTimeMs: 0, open: satang(0), high: satang(0), low: satang(0), close: satang(0), volume: 0)

/// A real market state that a test feeds with updates, the way the market client does with frames. It numbers the
/// updates of each symbol by itself, so a test says only what changed and, when it wants a gap, how many updates the
/// client missed.
final class FakeMarketState: Sendable {
    /// The state under test: the same class the app reads its prices from.
    let state: MarketState
    /// The sequence number of the last update of each symbol.
    private let sequences = Mutex<[UInt32: UInt64]>([:])

    /// A market state with no snapshot yet.
    init() {
        state = MarketState(latency: LatencyRecorder())
    }

    /// Applies one update of `symbol` that carries the candles given, as a frame with one update. A candle that is nil
    /// is left out of the update, which says nothing about it. The update is numbered `missed + 1` after the last one
    /// of the symbol, so a `missed` of 1 or more is a gap; `seq` numbers it by hand (and so can repeat a number).
    /// Returns the symbols whose numbering jumped.
    @discardableResult
    func feed(
        symbol: UInt32 = 4, last: Int64 = 3_425, missed: UInt64 = 0, seq: UInt64? = nil, candle1s: Candle? = nil,
        candle1m: Candle? = nil, candle5m: Candle? = nil
    ) -> [UInt32] {
        let number = seq ?? sequences.withLock { sequences in (sequences[symbol] ?? 0) + 1 + missed }
        sequences.withLock { $0[symbol] = number }
        var update = Tp_SymbolUpdate()
        update.symbolID = symbol
        update.seq = number
        update.last = last
        update.bid = last - 25
        update.ask = last + 25
        update.bidQty = 1_000
        update.askQty = 2_000
        update.dayVolume = 10_000
        if let candle1s { update.candle1S = candle1s.wire }
        if let candle1m { update.candle1M = candle1m.wire }
        if let candle5m { update.candle5M = candle5m.wire }
        return state.apply(frame: marketFrame(sendNs: 0, updates: [update]), receivedAtNs: 1_000)
    }

    /// Starts a new connection: the gap counts begin again from 0 and the next update of each symbol is a baseline.
    func beginConnection() {
        sequences.withLock { $0.removeAll() }
        state.beginConnection()
    }
}

/// A detail screen's model over a fake REST API and a market state the test feeds, with a clock the test sets. The
/// clock starts at 10 seconds.
@MainActor
struct ModelRig {
    /// The REST API the model asks for its history.
    let rest: FakeRest
    /// The market the model reads its live candle from.
    let market = FakeMarketState()
    /// The clock the model decides its gap reloads by, in nanoseconds.
    let clock = ManualClock(10_000_000_000)
    /// The model under test.
    let model: StockDetailViewModel

    /// A model of PTT (id 4) for `interval`, over `rest`.
    init(interval: CandleInterval = .m1, rest: FakeRest = FakeRest()) {
        self.rest = rest
        let market = market
        let clock = clock
        model = StockDetailViewModel(
            symbol: sampleSymbols[0], interval: interval, rest: rest, marketState: market.state,
            now: { clock.read() }
        )
    }

    /// Moves the model's clock forward by `ns` nanoseconds.
    func advance(byNs ns: Int64) {
        clock.set(clock.read() + ns)
    }
}

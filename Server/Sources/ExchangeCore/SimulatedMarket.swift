import TradeCore

/// The latest and earliest times the market represents, in milliseconds: the range whose nanoseconds fit an `Int64`
/// (the years 1677 to 2262). A time outside it is clamped into it, so no conversion to nanoseconds can overflow.
private let timeLimitMs = Int64.max / 1_000_000

private func clampedTime(_ ms: Int64) -> Int64 {
    min(max(ms, -timeLimitMs), timeLimitMs)
}

/// A simulated stock market: twelve symbols (or whatever it is given), each a random walk with changing volatility,
/// with a five-level book, a last price, day volume, and 1-second, 1-minute and 5-minute candles built by
/// `CandleAggregator`. Everything it shows is invented; none of it is a quote.
///
/// It is a pure value: it never reads a clock (the caller passes the times) and draws every random number from a
/// seeded generator, one stream per symbol, so a market is a function of its seed, its start time and the calls made
/// on it. A copy is independent of the original.
///
/// The model, per symbol:
/// - **Price.** The best bid walks a whole number of ticks per trade (never a fraction of a tick), clamped inside a
///   range that keeps every level of the book inside the +/-30% band, and pulled back toward the reference. The ask
///   is the bid plus a spread of one to three ticks that changes now and then. Each trade prints at the bid or the
///   ask, with the side persisting, so `bid <= last <= ask`.
/// - **Trades.** They arrive as a Poisson process at the rate passed to `advance`, so their number and times follow
///   the rate whatever the step. A trade is a positive number of board lots, adds to the day volume (which starts at
///   an invented base) and goes to all three candle aggregators.
/// - **Book.** After a call with trades, the book is rebuilt around the new best bid: five levels a side, quantities
///   carried by price and moved toward a target size. The same rebuild repairs a book that `updateDepth` thinned.
/// - **History.** At construction, 1,000 closed candles and the current one are synthesised for each interval by
///   walking backwards from the start price in a few big steps per candle (the work is per candle, not per trade), so
///   every candle opens at the previous close and the last close is the last price.
public struct SimulatedMarket: Sendable {
    /// The most ticks one call generates for one symbol. A call that spans more time than that (a Mac waking from
    /// sleep) generates only the last stretch of it, as long as this many ticks take at the given rate, and skips the
    /// rest.
    static let maxTicksPerCall = 20_000

    private var states: [SymbolState]
    private let indexByID: [UInt32: Int]
    /// The simulated time every symbol has reached, in milliseconds since the Unix epoch.
    private var currentMs: Int64

    /// The ticks generated since construction, counted before they are conflated into quotes. Ticks that a long jump
    /// skips are not generated and not counted.
    public private(set) var generatedUpdates = 0

    /// A market of `symbols` starting at `startMs` (milliseconds since the Unix epoch). A time outside the range whose
    /// nanoseconds fit an `Int64` is clamped into it.
    ///
    /// A symbol is left out, as if it was never given, when its id was already used (the first one wins) or when its
    /// price band is too narrow to hold a five-level book (a reference under 17 satang, or not positive).
    public init(symbols: [SymbolInfo], seed: UInt64, startMs: Int64) {
        let start = clampedTime(startMs)
        var states: [SymbolState] = []
        var indexByID: [UInt32: Int] = [:]
        for info in symbols where indexByID[info.id] == nil {
            guard let state = SymbolState(info: info, seed: seed, startMs: start) else { continue }
            indexByID[info.id] = states.count
            states.append(state)
        }
        self.states = states
        self.indexByID = indexByID
        currentMs = start
    }

    /// Moves the market to `toMs` and returns the quote of each symbol that changed, once, in the order of the symbols
    /// given at construction (a symbol that ticked several times returns its latest state, not each tick).
    ///
    /// A `toMs` that is not later than the market's time returns `[]` and changes nothing. A rate that is not positive
    /// and finite makes no ticks, but the clock still moves. Each symbol's book is repaired if `updateDepth` thinned
    /// it, whether or not a tick came, and that repaired quote is returned too.
    public mutating func advance(toMs: Int64, updatesPerSymbolPerSecond: Double) -> [SymbolQuote] {
        let target = clampedTime(toMs)
        guard target > currentMs else { return [] }
        var changed: [SymbolQuote] = []
        for index in states.indices {
            let before = states[index].quote
            generatedUpdates += states[index].advance(
                fromMs: currentMs, toMs: target, rate: updatesPerSymbolPerSecond
            )
            if states[index].quote != before {
                changed.append(states[index].quote)
            }
        }
        currentMs = target
        return changed
    }

    public func quote(_ id: UInt32) -> SymbolQuote? {
        indexByID[id].map { states[$0].quote }
    }

    public func depth(_ id: UInt32) -> BookDepth? {
        indexByID[id].map { states[$0].depth }
    }

    /// Lets the caller change a symbol's book (an order takes liquidity). Levels left with no quantity are dropped, the
    /// quote is re-derived from the new best levels at once (a side left empty keeps its price with a quantity of 0),
    /// and the next `advance` that moves the clock rebuilds the book. The closure should keep each side best first. An
    /// unknown id does nothing.
    public mutating func updateDepth(_ id: UInt32, _ body: (inout BookDepth) -> Void) {
        guard let index = indexByID[id] else { return }
        body(&states[index].depth)
        states[index].depth.dropEmptyLevels()
        states[index].needsRefill = true
        states[index].syncQuote()
    }

    /// The newest `limit` candles of `interval`, oldest first and one interval apart, the last being the one in
    /// progress: the bucket of the symbol's last trade, which a quiet symbol leaves behind the clock until its next
    /// trade. `min(limit, available)` of them (1,001 once the market is built: 1,000 closed and the current); `[]` for
    /// a limit that is not positive or an unknown symbol. A bucket in which nothing traded is a flat candle with no
    /// volume, so the series has no holes.
    ///
    /// A live candle keeps `CandleAggregator` semantics: it opens at the first trade of its bucket, so it can open a
    /// tick or two away from the previous close, like a gap on a real feed. Only the history synthesised at
    /// construction and the flat zero-volume gap candles chain open = previous close.
    public func history(symbolId: UInt32, interval: CandleInterval, limit: Int) -> [Candle] {
        guard limit > 0, let index = indexByID[symbolId] else { return [] }
        return states[index].history(interval, limit: limit)
    }

    /// The regime each symbol is in now. For tests: it is the only view of the volatility.
    var currentRegimes: [UInt32: Regime] {
        Dictionary(uniqueKeysWithValues: states.map { ($0.info.id, $0.regime) })
    }
}

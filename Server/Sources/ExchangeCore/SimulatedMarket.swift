import Foundation
import TradeCore

/// How hard the price is being shaken. A symbol moves between regimes at random times, so its charts have calm
/// stretches and busy ones.
enum Regime: CaseIterable, Sendable {
    case calm
    case normal
    case volatile

    /// The most ticks one step may move the price; a bigger draw is cut to this.
    static let maxStepTicks = 64
    /// The average time a regime lasts, in simulated seconds (the real length is exponential around it).
    static let meanDwellSeconds = 20.0

    /// The spread of one trade's move, in ticks, before it is rounded to a whole number of ticks. Rounding makes a
    /// calm price move on about 2% of trades, a normal one on 10% and a volatile one on 30%.
    var sigma: Double {
        switch self {
        case .calm: 0.22
        case .normal: 0.30
        case .volatile: 0.50
        }
    }

    /// How likely the regime is to be picked next: calm half the time, volatile one time in seven.
    private var weight: Double {
        switch self {
        case .calm: 0.50
        case .normal: 0.35
        case .volatile: 0.15
        }
    }

    /// The regime after `current` (any regime, when there is none yet): a different one, chosen by weight.
    static func next(after current: Regime?, using generator: inout SeededGenerator) -> Regime {
        let candidates = allCases.filter { $0 != current }
        var pick = generator.unit() * candidates.reduce(0) { $0 + $1.weight }
        for candidate in candidates {
            pick -= candidate.weight
            if pick < 0 { return candidate }
        }
        return candidates.last ?? .normal
    }

    /// One step of the walk, in whole ticks (positive is up): a normal draw of this regime's spread, plus the pull back
    /// toward `reference` (the gap measured in ticks at the current price), rounded and cut to `maxStepTicks`.
    func step(
        from price: Price, toward reference: Price, scale: StepScale, using generator: inout SeededGenerator
    ) -> Int {
        let tick = Double(TickRules.tickSize(at: price).satang)
        let pull = scale.pull * (Double(reference.satang) - Double(price.satang)) / tick
        let move = (pull + sigma * scale.spread * generator.normal()).rounded()
        guard move.isFinite else { return 0 }
        return Int(min(max(move, -Double(Self.maxStepTicks)), Double(Self.maxStepTicks)))
    }
}

/// How far one step of the walk reaches. The walk is an Ornstein-Uhlenbeck process in discrete time: each trade
/// pulls the price 0.2% of the way back toward the reference and shakes it by the regime's spread. A step that spans
/// several trades (one slice of a historical candle) takes the exact multi-trade pull and spread, not a repeat of the
/// single-trade ones.
struct StepScale: Sendable {
    /// The fraction of the gap to the reference that the step closes.
    let pull: Double
    /// The factor on the regime's spread: 1 for one trade, growing toward a ceiling as the span lengthens.
    let spread: Double

    init(pull: Double, spread: Double) {
        self.pull = pull
        self.spread = spread
    }

    init(ticks: Double) {
        let reversion = 0.002
        self.init(
            pull: 1 - exp(-reversion * ticks),
            spread: ((1 - exp(-2 * reversion * ticks)) / (2 * reversion)).squareRoot()
        )
    }

    static let perTick = StepScale(ticks: 1)
}

/// The latest and earliest times the market represents, in milliseconds: the range whose nanoseconds fit an `Int64`
/// (the years 1677 to 2262). A time outside it is clamped into it, so no conversion to nanoseconds can overflow.
private let timeLimitMs = Int64.max / 1_000_000

private func clampedTime(_ ms: Int64) -> Int64 {
    min(max(ms, -timeLimitMs), timeLimitMs)
}

/// A span in seconds as nanoseconds, cut to `0...Int64.max`; NaN and a span that is not positive are 0.
private func nanoseconds(seconds: Double) -> Int64 {
    guard seconds > 0 else { return 0 }
    let nanoseconds = seconds * 1e9
    return nanoseconds >= 9.2e18 ? .max : Int64(nanoseconds)
}

private func saturatingSum(_ a: Int64, _ b: Int64) -> Int64 {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? (b > 0 ? .max : .min) : sum
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
    public func history(symbolId: UInt32, interval: CandleInterval, limit: Int) -> [Candle] {
        guard limit > 0, let index = indexByID[symbolId] else { return [] }
        return states[index].history(interval, limit: limit)
    }

    /// The regime each symbol is in now. For tests: it is the only view of the volatility.
    var currentRegimes: [UInt32: Regime] {
        Dictionary(uniqueKeysWithValues: states.map { ($0.info.id, $0.regime) })
    }
}

/// Everything the market keeps for one symbol.
private struct SymbolState: Sendable {
    /// The trades per second the history is made to look like, and the shares a trade averages (the mean of the lots
    /// drawn in `tick`, 4.7 lots), which sets the size of a historical candle's volume.
    private static let typicalRate = 20.0
    private static let averageTradeShares = 470.0
    /// Slices a historical candle is walked in.
    private static let historySlices = 8
    private static let closedCandlesKept = 1000

    let info: SymbolInfo
    /// The prices the best bid may take: every level of the book then stays on tick and inside the price band.
    private let walk: ClosedRange<Price>
    private let baseQuantity: Quantity
    private var generator: SeededGenerator
    private(set) var regime: Regime
    private var regimeEndsNs: Int64
    private var bestBid: Price
    private var spreadTicks: Int
    private var buyAggressor = false
    var depth: BookDepth
    private(set) var quote: SymbolQuote
    /// Set by `updateDepth`; the next advance that moves the clock rebuilds the book.
    var needsRefill = false
    /// One aggregator and one store of closed candles for each interval, in the order of `CandleInterval.allCases`.
    private var aggregators: [CandleAggregator] = []
    private var closedCandles: [RingBuffer<Candle>] = []

    /// A symbol whose band cannot hold a book is nil. The walk range keeps the best bid four ticks above the lowest
    /// price of the band (four levels sit below it) and seven below the highest (a spread of three ticks, then four
    /// levels).
    init?(info: SymbolInfo, seed: UInt64, startMs: Int64) {
        let band = TickRules.band(reference: info.reference)
        let low = PriceGrid.up(PriceGrid.snappedUp(band.lowerBound), ticks: 4)
        let high = PriceGrid.down(PriceGrid.snappedDown(band.upperBound), ticks: 7)
        guard info.reference.satang > 0, low <= high else { return nil }

        self.info = info
        walk = low...high
        var generator = SeededGenerator(seed: seed, stream: info.id)
        baseQuantity = Quantity(20 + generator.below(181)) * TickRules.boardLot
        regime = Regime.next(after: nil, using: &generator)
        regimeEndsNs = saturatingSum(
            startMs * 1_000_000, nanoseconds(seconds: Regime.meanDwellSeconds * generator.exponential())
        )
        spreadTicks = 1 + generator.below(3)
        bestBid = PriceGrid.moved(
            PriceGrid.snappedDown(info.reference), byTicks: generator.below(13) - 6, within: low...high
        )

        let dayVolume = Int64(1 + generator.below(400)) * 100_000
        var candles: [Candle] = []
        for interval in CandleInterval.allCases {
            let history = Self.synthesise(
                interval, closingAt: bestBid, startMs: startMs, reference: info.reference, within: walk,
                using: &generator
            )
            var closed = RingBuffer<Candle>(capacity: Self.closedCandlesKept)
            history.dropLast().forEach { closed.append($0) }
            var aggregator = CandleAggregator(interval: interval)
            if let current = history.last {
                Self.replay(current, into: &aggregator)
                candles.append(current)
            }
            closedCandles.append(closed)
            aggregators.append(aggregator)
        }
        depth = BookDepth(bids: [], asks: [])
        depth.replenish(bestBid: bestBid, spreadTicks: spreadTicks, baseQuantity: baseQuantity, using: &generator)
        quote = SymbolQuote(
            symbolId: info.id, last: bestBid, bid: bestBid, ask: PriceGrid.up(bestBid, ticks: spreadTicks), bidQty: 0,
            askQty: 0, dayVolume: dayVolume, candle1s: candles[0], candle1m: candles[1], candle5m: candles[2],
            eventNs: startMs * 1_000_000
        )
        self.generator = generator
        syncQuote()
    }

    /// Makes the quote's bid and ask the best levels of the book. A side with no levels keeps its price, with 0 shares.
    mutating func syncQuote() {
        if let best = depth.bids.first {
            quote.bid = best.price
            quote.bidQty = best.quantity
        } else {
            quote.bidQty = 0
        }
        if let best = depth.asks.first {
            quote.ask = best.price
            quote.askQty = best.quantity
        } else {
            quote.askQty = 0
        }
    }

    /// Runs this symbol's ticks between `fromMs` and `toMs` (`toMs` is later) and returns how many there were.
    ///
    /// Ticks form a Poisson process: the gap to each tick is exponential with mean 1/rate. The process runs over the
    /// last `min(elapsed, maxTicksPerCall / rate)` seconds before `toMs`, so a long jump skips the time the cap cannot
    /// cover. Tick times are nanoseconds, never decrease, and fall after `fromMs` and no later than `toMs`.
    mutating func advance(fromMs: Int64, toMs: Int64, rate: Double) -> Int {
        let toNs = toMs * 1_000_000
        let floorNs = fromMs * 1_000_000 + 1
        var tickNs = floorNs
        var ticks = 0

        if rate > 0, rate.isFinite {
            let elapsed = Double(Int128(toMs) - Int128(fromMs)) / 1000
            let window = min(elapsed, Double(SimulatedMarket.maxTicksPerCall) / rate)
            let windowStartNs = saturatingSum(toNs, -nanoseconds(seconds: window))
            var offset = 0.0
            while ticks < SimulatedMarket.maxTicksPerCall {
                offset += generator.exponential() / rate
                guard offset <= window else { break }
                tickNs = min(max(saturatingSum(windowStartNs, nanoseconds(seconds: offset)), tickNs), toNs)
                tick(atNs: tickNs)
                ticks += 1
            }
        }
        if ticks > 0 || needsRefill {
            depth.replenish(bestBid: bestBid, spreadTicks: spreadTicks, baseQuantity: baseQuantity, using: &generator)
            needsRefill = false
            syncQuote()
            quote.eventNs = ticks > 0 ? tickNs : toNs
            quote.candle1s = aggregators[0].current ?? quote.candle1s
            quote.candle1m = aggregators[1].current ?? quote.candle1m
            quote.candle5m = aggregators[2].current ?? quote.candle5m
        }
        return ticks
    }

    /// One trade at `ns`. It moves the regime on if its time is up, walks the best bid, may change the spread or the
    /// side, and prints at the bid or the ask for a few lots (mostly one to six, sometimes a block). The trade goes
    /// into the day volume and all three aggregators, and a candle it closes goes to the history.
    private mutating func tick(atNs ns: Int64) {
        if ns >= regimeEndsNs {
            regime = Regime.next(after: regime, using: &generator)
            let dwell = Regime.meanDwellSeconds * generator.exponential()
            regimeEndsNs = saturatingSum(ns, nanoseconds(seconds: dwell))
        }
        let move = regime.step(from: bestBid, toward: info.reference, scale: .perTick, using: &generator)
        bestBid = PriceGrid.moved(bestBid, byTicks: move, within: walk)
        if generator.unit() < 0.05 {
            spreadTicks = min(max(spreadTicks + (generator.below(2) == 0 ? -1 : 1), 1), 3)
        }
        if generator.unit() < 0.25 {
            buyAggressor.toggle()
        }
        let price = buyAggressor ? PriceGrid.up(bestBid, ticks: spreadTicks) : bestBid
        let lots = 1 + generator.below(6) + (generator.below(16) == 0 ? generator.below(40) : 0)
        let quantity = Quantity(lots) * TickRules.boardLot

        quote.last = price
        quote.dayVolume = saturatingSum(quote.dayVolume, quantity)
        for slot in aggregators.indices {
            if let closed = aggregators[slot].add(price: price, quantity: quantity, atMs: ns / 1_000_000) {
                archive(closed, slot: slot)
            }
        }
    }

    /// Stores a candle that has just closed, then a flat candle with no volume at its closing price for each bucket the
    /// aggregator skipped (nothing traded in it), so the history stays contiguous. Only the newest `closedCandlesKept`
    /// of a long gap can survive in the store, so only those are made: a gap of years costs no more than a gap of
    /// 1,000 buckets.
    private mutating func archive(_ closed: Candle, slot: Int) {
        closedCandles[slot].append(closed)
        guard let opened = aggregators[slot].current else { return }
        let width = Int64(CandleInterval.allCases[slot].seconds) * 1000
        let gap = (Int128(opened.openTimeMs) - Int128(closed.openTimeMs)) / Int128(width) - 1
        let flats = Int(min(max(gap, 0), Int128(Self.closedCandlesKept)))
        for index in 0..<flats {
            let openTimeMs = opened.openTimeMs - Int64(flats - index) * width
            let flat = Candle(
                openTimeMs: openTimeMs, open: closed.close, high: closed.close, low: closed.close, close: closed.close,
                volume: 0
            )
            closedCandles[slot].append(flat)
        }
    }

    func history(_ interval: CandleInterval, limit: Int) -> [Candle] {
        guard let slot = CandleInterval.allCases.firstIndex(of: interval) else { return [] }
        let closed = closedCandles[slot]
        let total = closed.count + (aggregators[slot].current == nil ? 0 : 1)
        var candles: [Candle] = []
        for index in (total - min(limit, total))..<total {
            if index < closed.count {
                candles.append(closed[index])
            } else if let current = aggregators[slot].current {
                candles.append(current)
            }
        }
        return candles
    }

    /// The candles of one interval for the start of the market, oldest first: `closedCandlesKept` closed ones and the
    /// one in progress at `startMs`, which ends at `price`. Each candle is walked backwards from its close in a few
    /// big steps (the walk is as good backwards as forwards), so its open is the close of the one before, and the cost
    /// is a handful of steps per candle however many trades the candle stands for.
    private static func synthesise(
        _ interval: CandleInterval, closingAt price: Price, startMs: Int64, reference: Price,
        within walk: ClosedRange<Price>, using generator: inout SeededGenerator
    ) -> [Candle] {
        let width = Int64(interval.seconds) * 1000
        let currentOpen = interval.bucketStartMs(forMs: startMs)
        let tradesPerSlice = typicalRate * Double(interval.seconds) / Double(historySlices)
        let scale = StepScale(ticks: tradesPerSlice)
        var regime = Regime.next(after: nil, using: &generator)
        var close = price
        var candles: [Candle] = []

        for age in 0...closedCandlesKept {
            if generator.unit() < Double(interval.seconds) / Regime.meanDwellSeconds {
                regime = Regime.next(after: regime, using: &generator)
            }
            var cursor = close
            var high = close
            var low = close
            var volume: Int64 = 0
            for _ in 0..<historySlices {
                let move = regime.step(from: cursor, toward: reference, scale: scale, using: &generator)
                cursor = PriceGrid.moved(cursor, byTicks: move, within: walk)
                high = max(high, cursor)
                low = min(low, cursor)
                let shares = tradesPerSlice * averageTradeShares * (0.5 + generator.unit())
                volume += max(Int64(shares) / TickRules.boardLot, 1) * TickRules.boardLot
            }
            candles.append(
                Candle(
                    openTimeMs: currentOpen - Int64(age) * width, open: cursor, high: high, low: low, close: close,
                    volume: volume
                )
            )
            close = cursor
        }
        return candles.reversed()
    }

    /// Makes `aggregator` hold `candle` by feeding it four trades inside its bucket: the open, the low, the high and
    /// the close, in that order, with the volume split so the total is the candle's (it is at least eight lots).
    private static func replay(_ candle: Candle, into aggregator: inout CandleAggregator) {
        let lot = TickRules.boardLot
        let atMs = candle.openTimeMs
        _ = aggregator.add(price: candle.open, quantity: candle.volume - 3 * lot, atMs: atMs)
        _ = aggregator.add(price: candle.low, quantity: lot, atMs: atMs)
        _ = aggregator.add(price: candle.high, quantity: lot, atMs: atMs)
        _ = aggregator.add(price: candle.close, quantity: lot, atMs: atMs)
    }
}

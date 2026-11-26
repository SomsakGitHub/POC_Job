import TradeCore

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

/// Everything the market keeps for one symbol.
struct SymbolState: Sendable {
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

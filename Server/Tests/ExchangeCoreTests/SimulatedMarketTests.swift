import Testing
import TradeCore
@testable import ExchangeCore

private func requireSendable<T: Sendable>(_: T.Type) {}

struct SimulatedMarketTests {
    // MARK: - Determinism

    /// Two markets built from the same seed and given the same advances are identical, history included: nothing in the
    /// simulation reads a clock or a global source of randomness. The steps are uneven on purpose.
    @Test func sameSeedSameSequence() {
        var first = SimulatedMarket(symbols: catalogSymbols, seed: 42, startMs: marketStartMs)
        var second = SimulatedMarket(symbols: catalogSymbols, seed: 42, startMs: marketStartMs)
        #expect(quotes(of: first) == quotes(of: second))

        var now = marketStartMs
        for step in 1...50 {
            now += Int64(20 + step)
            let fromFirst = first.advance(toMs: now, updatesPerSymbolPerSecond: 20)
            let fromSecond = second.advance(toMs: now, updatesPerSymbolPerSecond: 20)
            #expect(fromFirst == fromSecond)
        }

        #expect(quotes(of: first) == quotes(of: second))
        #expect(first.generatedUpdates == second.generatedUpdates)
        for info in catalogSymbols {
            #expect(first.depth(info.id) == second.depth(info.id))
            for interval in CandleInterval.allCases {
                let fromFirst = first.history(symbolId: info.id, interval: interval, limit: 2000)
                let fromSecond = second.history(symbolId: info.id, interval: interval, limit: 2000)
                #expect(fromFirst == fromSecond)
            }
        }
    }

    @Test func differentSeedDiffers() {
        var first = defaultMarket
        var other = SimulatedMarket(symbols: catalogSymbols, seed: 43, startMs: marketStartMs)

        // The history that is synthesised at construction already differs, symbol by symbol.
        #expect(quotes(of: first) != quotes(of: other))
        for info in catalogSymbols {
            let fromFirst = first.history(symbolId: info.id, interval: .m1, limit: 100)
            let fromOther = other.history(symbolId: info.id, interval: .m1, limit: 100)
            #expect(fromFirst != fromOther, "\(info.ticker)")
        }

        var now = marketStartMs
        for _ in 0..<20 {
            now += 100
            _ = first.advance(toMs: now, updatesPerSymbolPerSecond: 20)
            _ = other.advance(toMs: now, updatesPerSymbolPerSecond: 20)
        }
        #expect(quotes(of: first) != quotes(of: other))
    }

    /// Each symbol draws from its own stream: two symbols with the same price and the same seed still walk differently.
    @Test(arguments: [UInt64(0), 1, .max] as [UInt64])
    func symbolsWalkIndependently(seed: UInt64) {
        let twins = [makeSymbol(1, reference: 3425), makeSymbol(2, reference: 3425)]
        let market = SimulatedMarket(symbols: twins, seed: seed, startMs: marketStartMs)

        for interval in CandleInterval.allCases {
            #expect(
                market.history(symbolId: 1, interval: interval, limit: 100)
                    != market.history(symbolId: 2, interval: interval, limit: 100)
            )
        }
    }

    /// A market is a value: a copy advances on its own and leaves the original where it was.
    @Test func aCopyEvolvesIndependently() {
        let original = defaultMarket
        var copy = original

        _ = copy.advance(toMs: marketStartMs + 1000, updatesPerSymbolPerSecond: 20)

        #expect(quotes(of: original) == quotes(of: defaultMarket))
        #expect(quotes(of: copy) != quotes(of: original))
        #expect(original.generatedUpdates == 0)
        requireSendable(SimulatedMarket.self)
        requireSendable(SymbolQuote.self)
    }

    // MARK: - Prices

    /// The brief's 100,000-step run: five simulated minutes at the default rate (volatility regimes last about twenty
    /// seconds, so each symbol changes regime many times) followed by twenty seconds at the stress rate, 192,000 ticks
    /// in all. After every call, every returned quote and its book obey every rule in `problems`, and the quote that
    /// came back is the one `quote(_:)` reports.
    @Test func pricesStayOnTickAndInsideBand() {
        var market = defaultMarket
        let infoById = Dictionary(uniqueKeysWithValues: catalogSymbols.map { ($0.id, $0) })
        var issues: [String] = []
        var regimes = market.currentRegimes
        var regimesSeen = Set(regimes.values)
        var regimeChanges = 0
        var now = marketStartMs

        for (calls, rate) in [(3000, 20.0), (200, 500.0)] {
            for _ in 0..<calls {
                now += 100
                for quote in market.advance(toMs: now, updatesPerSymbolPerSecond: rate) where issues.count < 20 {
                    guard let info = infoById[quote.symbolId], let depth = market.depth(quote.symbolId) else {
                        issues.append("no symbol or book for \(quote.symbolId)")
                        continue
                    }
                    issues += problems(quote, depth, info)
                    if market.quote(quote.symbolId) != quote {
                        issues.append("\(info.ticker): the returned quote is not quote(_:)")
                    }
                }
                for (id, regime) in market.currentRegimes {
                    if regimes[id] != regime {
                        regimeChanges += 1
                        regimes[id] = regime
                    }
                    regimesSeen.insert(regime)
                }
            }
        }

        #expect(issues.isEmpty, "\(issues.prefix(5))")
        #expect(market.generatedUpdates >= 100_000)
        #expect(regimesSeen == Set(Regime.allCases))
        #expect(regimeChanges >= catalogSymbols.count * 5, "\(regimeChanges) regime changes")
    }

    /// A band that straddles a tick-size change, walked through for a minute: 100.00 baht is where the tick goes from
    /// 25 to 50 satang, so the walk (and the ladders around it) must cross it and stay on tick.
    @Test func aWalkAcrossATickSizeChangeStaysOnTick() {
        let symbol = makeSymbol(1, reference: 10_000)
        var market = SimulatedMarket(symbols: [symbol], seed: 3, startMs: marketStartMs)
        var issues: [String] = []
        var sawBelow = false
        var sawAbove = false
        var now = marketStartMs

        for _ in 0..<600 {
            now += 100
            for quote in market.advance(toMs: now, updatesPerSymbolPerSecond: 100) {
                if let depth = market.depth(quote.symbolId) {
                    issues += problems(quote, depth, symbol)
                }
                sawBelow = sawBelow || quote.bid < symbol.reference
                sawAbove = sawAbove || quote.ask > symbol.reference
            }
        }

        #expect(issues.isEmpty, "\(issues.prefix(5))")
        #expect(sawBelow && sawAbove)
    }

    /// The price band of a very cheap symbol is only a handful of ticks wide, so the walk lives against its edges and
    /// the book against the band's: it must still be a full, valid book. At 17 satang the walk has one price to stand
    /// on.
    @Test(arguments: [17, 18, 20, 30, 60] as [Int64])
    func aTightBandKeepsAFullBookInsideTheBand(reference: Int64) {
        let symbol = makeSymbol(1, reference: reference)
        var market = SimulatedMarket(symbols: [symbol], seed: 8, startMs: marketStartMs)
        var issues: [String] = []
        if let quote = market.quote(1), let depth = market.depth(1) {
            issues += problems(quote, depth, symbol)
        }

        var now = marketStartMs
        for _ in 0..<200 {
            now += 100
            for quote in market.advance(toMs: now, updatesPerSymbolPerSecond: 200) {
                if let depth = market.depth(quote.symbolId) {
                    issues += problems(quote, depth, symbol)
                }
            }
        }

        #expect(issues.isEmpty, "\(issues.prefix(5))")
    }

    // MARK: - Update rate

    /// Ten simulated seconds at 20 updates a second a symbol is 2,400 updates over twelve symbols, within 25%, however
    /// the time is cut into steps: `generatedUpdates` counts the ticks themselves, not the conflated quotes a call
    /// returns, so a step of 10 ms and a step of a second give the same rate.
    @Test(arguments: [10, 50, 1000] as [Int64])
    func updateRateMatches(stepMs: Int64) {
        var market = defaultMarket
        var now = marketStartMs
        var returned = 0
        var largestBatch = 0

        while now < marketStartMs + 10_000 {
            now += stepMs
            let batch = market.advance(toMs: now, updatesPerSymbolPerSecond: 20)
            returned += batch.count
            largestBatch = max(largestBatch, batch.count)
        }

        let expected = 12.0 * 20 * 10
        #expect(Double(market.generatedUpdates) >= expected * 0.75, "\(market.generatedUpdates)")
        #expect(Double(market.generatedUpdates) <= expected * 1.25, "\(market.generatedUpdates)")
        // Conflation: never more than one quote per symbol per call, and fewer quotes than ticks.
        #expect(largestBatch <= 12)
        #expect(returned <= market.generatedUpdates)
    }

    /// One second at 500 updates a second a symbol is about 6,000 ticks: the stress mode's five thousand and more.
    @Test func stressRateReachesFiveThousand() {
        var market = defaultMarket

        let batch = market.advance(toMs: marketStartMs + 1000, updatesPerSymbolPerSecond: 500)

        #expect(market.generatedUpdates >= 5000, "\(market.generatedUpdates)")
        #expect(market.generatedUpdates <= 7500, "\(market.generatedUpdates)")
        #expect(batch.count <= 12)
        #expect(Set(batch.map(\.symbolId)).count == batch.count)
    }

    /// A call returns each symbol that changed once, with its current state, and no symbol that did not change. A step
    /// of 5 ms at 20 updates a second gives a symbol a tick in about one call in ten, so most symbols stay quiet.
    @Test func advanceReturnsOneCurrentQuoteForEachSymbolThatChanged() {
        var market = defaultMarket
        var known = quotes(of: market)
        var now = marketStartMs
        var quietCalls = 0
        var returnedTotal = 0

        for _ in 0..<200 {
            now += 5
            let batch = market.advance(toMs: now, updatesPerSymbolPerSecond: 20)
            let returnedIds = Set(batch.map(\.symbolId))
            #expect(returnedIds.count == batch.count)
            for (index, info) in catalogSymbols.enumerated() {
                let current = market.quote(info.id)
                if returnedIds.contains(info.id) {
                    #expect(current != known[index], "\(info.ticker) was returned but did not change")
                } else {
                    #expect(current == known[index], "\(info.ticker) changed but was not returned")
                }
                if let current {
                    known[index] = current
                }
            }
            for quote in batch {
                #expect(market.quote(quote.symbolId) == quote)
            }
            quietCalls += batch.isEmpty ? 1 : 0
            returnedTotal += batch.count
        }

        #expect(quietCalls > 0)
        #expect(returnedTotal < 200 * 12 / 2)
    }

    // MARK: - eventNs, day volume

    /// `eventNs` is the simulated time of the quote's last tick: after the previous call's time, never later than
    /// `toMs` in nanoseconds, never backwards for a symbol, and finer than a millisecond.
    @Test func eventNsIsTheLastTickTimeInNanoseconds() {
        var market = defaultMarket
        var previous = Dictionary(uniqueKeysWithValues: catalogSymbols.map { ($0.id, marketStartMs * 1_000_000) })
        var problemsFound: [String] = []
        var withSubMillisecond = 0
        var total = 0
        var now = marketStartMs

        for _ in 0..<100 {
            let before = now
            now += 50
            for quote in market.advance(toMs: now, updatesPerSymbolPerSecond: 20) {
                if quote.eventNs > now * 1_000_000 {
                    problemsFound.append("\(quote.symbolId): \(quote.eventNs) is after toMs \(now)")
                }
                if quote.eventNs <= before * 1_000_000 {
                    problemsFound.append("\(quote.symbolId): \(quote.eventNs) is not after the previous call's time")
                }
                if quote.eventNs < previous[quote.symbolId, default: 0] {
                    problemsFound.append("\(quote.symbolId): eventNs went backwards")
                }
                previous[quote.symbolId] = quote.eventNs
                total += 1
                withSubMillisecond += quote.eventNs % 1_000_000 == 0 ? 0 : 1
            }
        }

        #expect(problemsFound.isEmpty, "\(problemsFound.prefix(5))")
        #expect(total > 500)
        #expect(Double(withSubMillisecond) / Double(total) > 0.95, "\(withSubMillisecond) of \(total)")
    }

    /// The first quotes carry the start time itself.
    @Test func eventNsStartsAtTheStartTime() {
        for quote in quotes(of: defaultMarket) {
            #expect(quote.eventNs == marketStartMs * 1_000_000)
        }
    }

    /// The day volume starts at an invented positive base, never decreases, and grows by whole lots: every tick
    /// trades a positive multiple of the board lot.
    @Test func dayVolumeNeverDecreasesAndGrowsInWholeLots() {
        var market = defaultMarket
        var volume = Dictionary(uniqueKeysWithValues: quotes(of: market).map { ($0.symbolId, $0.dayVolume) })
        let start = volume
        var problemsFound: [String] = []
        var now = marketStartMs

        for _ in 0..<100 {
            now += 100
            for quote in market.advance(toMs: now, updatesPerSymbolPerSecond: 20) {
                let growth = quote.dayVolume - volume[quote.symbolId, default: 0]
                if growth <= 0 || growth % TickRules.boardLot != 0 {
                    problemsFound.append("\(quote.symbolId): day volume grew by \(growth)")
                }
                volume[quote.symbolId] = quote.dayVolume
            }
        }

        #expect(problemsFound.isEmpty, "\(problemsFound.prefix(5))")
        for (id, base) in start {
            #expect(base > 0 && base % TickRules.boardLot == 0)
            #expect(volume[id, default: 0] > base)
        }
    }

    // MARK: - Candles

    /// `low <= open, close <= high` for the current candle of all three intervals while the market runs for five
    /// minutes (long enough for the 1-minute candle to roll five times and the 5-minute candle once), and for every
    /// candle in every history. Prices end on `last`, volumes are whole lots, and each candle opens on its bucket.
    @Test func candleInvariants() {
        var market = defaultMarket
        let infoById = Dictionary(uniqueKeysWithValues: catalogSymbols.map { ($0.id, $0) })
        let first = Dictionary(uniqueKeysWithValues: quotes(of: market).map { ($0.symbolId, $0) })
        var issues: [String] = []
        var now = marketStartMs

        for _ in 0..<300 {
            now += 1000
            for quote in market.advance(toMs: now, updatesPerSymbolPerSecond: 20) where issues.count < 20 {
                if let info = infoById[quote.symbolId], let depth = market.depth(quote.symbolId) {
                    issues += problems(quote, depth, info)
                }
            }
        }

        for quote in quotes(of: market) {
            let initial = first[quote.symbolId]
            #expect(quote.candle1m.openTimeMs > initial?.candle1m.openTimeMs ?? .max, "\(quote.symbolId)")
            #expect(quote.candle5m.openTimeMs > initial?.candle5m.openTimeMs ?? .max, "\(quote.symbolId)")
            for interval in CandleInterval.allCases {
                for candle in market.history(symbolId: quote.symbolId, interval: interval, limit: 2000) {
                    let wellFormed = candle.low <= candle.open && candle.low <= candle.close
                        && candle.open <= candle.high && candle.close <= candle.high
                    if !wellFormed || candle.volume < 0 || candle.volume % TickRules.boardLot != 0 {
                        issues.append("\(quote.symbolId) \(interval.label): \(candle)")
                    }
                }
            }
        }
        #expect(issues.isEmpty, "\(issues.prefix(5))")
    }

    /// The candle in progress when the market starts is carried on by the live trades: once its bucket is over, the
    /// closed candle in the history has the same open and extends the extremes and the volume it had.
    @Test(arguments: CandleInterval.allCases)
    func liveTradesContinueTheCandleThatWasInProgress(interval: CandleInterval) throws {
        var market = defaultMarket
        let before = quotes(of: market).map { candle(interval, of: $0) }
        let bucketEnd = interval.bucketStartMs(forMs: marketStartMs) + widthMs(interval)

        _ = market.advance(toMs: bucketEnd + 1000, updatesPerSymbolPerSecond: 20)

        for (info, started) in zip(catalogSymbols, before) {
            let history = market.history(symbolId: info.id, interval: interval, limit: 10)
            let closed = try #require(history.first { $0.openTimeMs == started.openTimeMs }, "\(info.ticker)")
            #expect(closed.open == started.open)
            #expect(closed.high >= started.high && closed.low <= started.low)
            #expect(closed.volume >= started.volume)
            #expect(closed.volume > started.volume || interval == .s1, "\(info.ticker): no trade in the bucket")
        }
    }

    // MARK: - History

    @Test func historyAscendingContiguous() throws {
        var market = defaultMarket

        for live in [false, true] {
            if live {
                _ = market.advance(toMs: marketStartMs + 150_000, updatesPerSymbolPerSecond: 20)
            }
            for info in catalogSymbols {
                let quote = try #require(market.quote(info.id))
                for interval in CandleInterval.allCases {
                    let history = market.history(symbolId: info.id, interval: interval, limit: 300)
                    let steps = zip(history, history.dropFirst()).map { $1.openTimeMs - $0.openTimeMs }
                    let currentMs = live ? quote.eventNs / 1_000_000 : marketStartMs

                    #expect(history.count == 300, "\(info.ticker) \(interval.label)")
                    #expect(steps.allSatisfy { $0 == widthMs(interval) }, "\(info.ticker) \(interval.label)")
                    #expect(history.last == candle(interval, of: quote), "\(info.ticker) \(interval.label)")
                    #expect(history.last?.openTimeMs == interval.bucketStartMs(forMs: currentMs))
                }
            }
        }
    }

    /// At construction each candle opens where the one before it closed, and the market's last price is the close of
    /// the candle in progress, for every interval and symbol.
    @Test func historyChainsOpensToPreviousClosesAndEndsAtLast() throws {
        for info in catalogSymbols {
            let quote = try #require(defaultMarket.quote(info.id))
            for interval in CandleInterval.allCases {
                let history = defaultMarket.history(symbolId: info.id, interval: interval, limit: 2000)

                let chained = zip(history, history.dropFirst()).allSatisfy { $0.close == $1.open }
                #expect(chained, "\(info.ticker) \(interval.label)")
                #expect(history.last?.close == quote.last, "\(info.ticker) \(interval.label)")
            }
        }
    }

    /// There are at least 1,000 closed candles and the current one for every interval and symbol, and `limit` is
    /// clamped to what there is. A limit of zero or less, and an unknown symbol, give nothing.
    @Test(arguments: CandleInterval.allCases)
    func historyReturnsTheSmallerOfLimitAndWhatThereIs(interval: CandleInterval) throws {
        let market = defaultMarket
        let id = try #require(catalogSymbols.first).id
        let newest = market.history(symbolId: id, interval: interval, limit: 1)
        let all = market.history(symbolId: id, interval: interval, limit: Int.max)

        #expect(all.count == 1001)
        #expect(market.history(symbolId: id, interval: interval, limit: 1001) == all)
        #expect(market.history(symbolId: id, interval: interval, limit: 5000) == all)
        #expect(market.history(symbolId: id, interval: interval, limit: 1000) == Array(all.suffix(1000)))
        #expect(newest == [all[1000]])
        #expect(market.history(symbolId: id, interval: interval, limit: 0).isEmpty)
        #expect(market.history(symbolId: id, interval: interval, limit: -1).isEmpty)
        #expect(market.history(symbolId: id, interval: interval, limit: Int.min).isEmpty)
    }

    // MARK: - Book

    @Test func depthHasFiveLevels() throws {
        var market = defaultMarket
        var now = marketStartMs

        for round in 0..<3 {
            for info in catalogSymbols {
                let depth = try #require(market.depth(info.id))
                let prices = (bids: depth.bids.map(\.price), asks: depth.asks.map(\.price))

                #expect(prices.bids.count == 5 && prices.asks.count == 5, "\(info.ticker) round \(round)")
                #expect(zip(prices.bids, prices.bids.dropFirst()).allSatisfy { $0 > $1 }, "\(info.ticker) bids")
                #expect(zip(prices.asks, prices.asks.dropFirst()).allSatisfy { $0 < $1 }, "\(info.ticker) asks")
                #expect((prices.bids + prices.asks).allSatisfy { TickRules.isOnTick($0) }, "\(info.ticker)")
            }
            now += 250
            _ = market.advance(toMs: now, updatesPerSymbolPerSecond: 20)
        }
    }

    /// Take the best ask level away (as a market buy would), advance a second, and the asks are five levels again, on
    /// tick, strictly ascending, with the spread back inside three ticks.
    @Test func depthReplenishesAfterConsumption() throws {
        var market = defaultMarket

        market.updateDepth(ptt.id) { $0.asks.removeFirst() }
        let consumed = try #require(market.depth(ptt.id))
        #expect(consumed.asks.count == 4)

        _ = market.advance(toMs: marketStartMs + 1000, updatesPerSymbolPerSecond: 20)

        let depth = try #require(market.depth(ptt.id))
        let quote = try #require(market.quote(ptt.id))
        #expect(depth.asks.count == 5)
        #expect(zip(depth.asks, depth.asks.dropFirst()).allSatisfy { $0.price < $1.price })
        #expect(depth.asks.allSatisfy { TickRules.isOnTick($0.price) && $0.quantity > 0 })
        #expect(problems(quote, depth, ptt).isEmpty, "\(problems(quote, depth, ptt))")
    }
}

// MARK: - The walk

extension SimulatedMarketTests {
    struct Walk {
        private let price = Price(satang: 3425)

        private func meanAbsoluteStep(_ regime: Regime, seed: UInt64) -> Double {
            var generator = SeededGenerator(seed: seed)
            var total = 0
            for _ in 0..<20_000 {
                total += abs(regime.step(from: price, toward: price, scale: .perTick, using: &generator))
            }
            return Double(total) / 20_000
        }

        /// The three regimes differ in how far one tick moves the price: calm < normal < volatile, and even the calm
        /// one is not frozen.
        @Test func volatileRegimesTakeBiggerSteps() {
            let calm = meanAbsoluteStep(.calm, seed: 5)
            let normal = meanAbsoluteStep(.normal, seed: 5)
            let volatile = meanAbsoluteStep(.volatile, seed: 5)

            #expect(calm > 0)
            #expect(calm < normal && normal < volatile, "\(calm) \(normal) \(volatile)")
        }

        /// Far below the reference the steps lean up, far above they lean down: the walk is mean-reverting.
        @Test func stepsLeanTowardTheReference() {
            func meanStep(from satang: Int64) -> Double {
                var generator = SeededGenerator(seed: 6)
                var total = 0
                for _ in 0..<20_000 {
                    total += Regime.normal.step(
                        from: Price(satang: satang), toward: price, scale: .perTick, using: &generator
                    )
                }
                return Double(total) / 20_000
            }

            #expect(meanStep(from: 2400) > 0.02)
            #expect(meanStep(from: 4450) < -0.02)
            #expect(abs(meanStep(from: 3425)) < 0.02)
        }

        /// One step never exceeds `maxStepTicks`, even when the scale asks for far more (as a long candle's would).
        @Test func stepsAreLimited() {
            var generator = SeededGenerator(seed: 7)
            let huge = StepScale(pull: 0, spread: 1000)
            var steps: [Int] = []

            for regime in Regime.allCases {
                for _ in 0..<1000 {
                    steps.append(regime.step(from: price, toward: price, scale: huge, using: &generator))
                }
            }

            #expect(steps.allSatisfy { abs($0) <= Regime.maxStepTicks })
            #expect(steps.contains(Regime.maxStepTicks) && steps.contains(-Regime.maxStepTicks))
        }

        /// The weights make calm the commonest regime and volatile the rarest, and the next regime is never the
        /// current one.
        @Test func nextRegimeDiffersFromTheCurrentOne() {
            var generator = SeededGenerator(seed: 8)
            var counts: [Regime: Int] = [:]

            var neverTheSame = true

            for current in Regime.allCases {
                for _ in 0..<2000 {
                    let next = Regime.next(after: current, using: &generator)
                    neverTheSame = neverTheSame && next != current
                    counts[next, default: 0] += 1
                }
            }

            #expect(neverTheSame)
            #expect(counts[.calm, default: 0] > counts[.volatile, default: 0])
        }
    }
}

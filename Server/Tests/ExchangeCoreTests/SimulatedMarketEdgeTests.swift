import Testing
import TradeCore
@testable import ExchangeCore

/// Inputs outside the usual range: unknown symbols, time that does not move forward, rates that make no sense, a long
/// sleep, extreme times and degenerate symbols. A nested suite, so `--filter SimulatedMarketTests` runs it too.
extension SimulatedMarketTests {
    struct Edges {
        private let threeSymbols = Array(catalogSymbols.prefix(3))

        // MARK: - Unknown symbols

        @Test(arguments: [0, 13, 99, UInt32.max] as [UInt32])
        func unknownSymbolIdsAnswerNilOrEmptyAndChangeNothing(id: UInt32) {
            var market = defaultMarket
            var closureRan = false

            #expect(market.quote(id) == nil)
            #expect(market.depth(id) == nil)
            for interval in CandleInterval.allCases {
                #expect(market.history(symbolId: id, interval: interval, limit: 10).isEmpty)
            }
            market.updateDepth(id) { _ in closureRan = true }

            #expect(!closureRan)
            #expect(quotes(of: market) == quotes(of: defaultMarket))
            for info in catalogSymbols {
                #expect(market.depth(info.id) == defaultMarket.depth(info.id))
            }
        }

        // MARK: - Time

        /// A time that is not later than the market's own returns nothing and changes nothing, before or after the
        /// market has moved, down to `Int64.min`.
        @Test(arguments: [0, -1, -10_000, Int64.min] as [Int64])
        func advancingBackwardsOrToTheSameTimeChangesNothing(offset: Int64) {
            var market = defaultMarket
            _ = market.advance(toMs: marketStartMs + 1000, updatesPerSymbolPerSecond: 20)
            let settled = market
            let target = offset == Int64.min ? Int64.min : marketStartMs + 1000 + offset

            #expect(market.advance(toMs: target, updatesPerSymbolPerSecond: 20).isEmpty)

            #expect(quotes(of: market) == quotes(of: settled))
            #expect(market.generatedUpdates == settled.generatedUpdates)
            for info in catalogSymbols {
                #expect(market.depth(info.id) == settled.depth(info.id))
                #expect(
                    market.history(symbolId: info.id, interval: .s1, limit: 50)
                        == settled.history(symbolId: info.id, interval: .s1, limit: 50)
                )
            }
        }

        /// Backwards from the very start too, and a book that is waiting for a repair is not repaired by a call that
        /// does not move the clock.
        @Test func aCallThatDoesNotMoveTheClockRepairsNothing() throws {
            var market = defaultMarket
            market.updateDepth(ptt.id) { $0.asks.removeFirst() }
            let damaged = try #require(market.depth(ptt.id))

            #expect(market.advance(toMs: marketStartMs, updatesPerSymbolPerSecond: 20).isEmpty)
            #expect(market.advance(toMs: marketStartMs - 5000, updatesPerSymbolPerSecond: 20).isEmpty)

            #expect(market.depth(ptt.id) == damaged)
        }

        /// A rate that is not positive and finite generates no ticks: nothing is returned, `generatedUpdates` stays
        /// put, no quote changes. The clock still moves, so a later call to a time inside that stretch is a call
        /// backwards.
        @Test(arguments: [0, -1, -Double.infinity, Double.infinity, Double.nan, -0.0] as [Double])
        func aRateThatIsNotPositiveAndFiniteGeneratesNoTicks(rate: Double) {
            var market = defaultMarket

            #expect(market.advance(toMs: marketStartMs + 5000, updatesPerSymbolPerSecond: rate).isEmpty)

            #expect(market.generatedUpdates == 0)
            #expect(quotes(of: market) == quotes(of: defaultMarket))
            #expect(market.advance(toMs: marketStartMs + 2000, updatesPerSymbolPerSecond: 20).isEmpty)
            #expect(market.generatedUpdates == 0)
        }

        /// The smallest positive rate cannot produce a tick in any step and the largest finite one is cut off at the
        /// cap: neither traps.
        @Test func theSmallestAndLargestRatesDoNotTrap() {
            var market = SimulatedMarket(symbols: threeSymbols, seed: 4, startMs: marketStartMs)
            let cap = SimulatedMarket.maxTicksPerCall

            let tiny = market.advance(toMs: marketStartMs + 1000, updatesPerSymbolPerSecond: .leastNonzeroMagnitude)
            #expect(tiny.isEmpty)
            #expect(market.generatedUpdates == 0)

            let batch = market.advance(toMs: marketStartMs + 2000, updatesPerSymbolPerSecond: .greatestFiniteMagnitude)

            #expect(batch.count == 3)
            #expect(market.generatedUpdates <= 3 * cap)
            #expect(market.generatedUpdates >= 3 * cap * 9 / 10)
        }

        /// One call generates at most `maxTicksPerCall` ticks for a symbol. A call that spans far more time than that
        /// (a Mac waking from sleep) skips the time it cannot cover instead of generating every tick: here an hour at
        /// 20 a second is 72,000 ticks a symbol, and what is generated is the last 1,000 seconds' worth, right up to
        /// the new time.
        @Test func theTickCapBoundsOneCallAndTheSkippedTimeGeneratesNothing() {
            var market = SimulatedMarket(symbols: threeSymbols, seed: 4, startMs: marketStartMs)
            let cap = SimulatedMarket.maxTicksPerCall
            let toMs = marketStartMs + 3_600_000

            let batch = market.advance(toMs: toMs, updatesPerSymbolPerSecond: 20)

            #expect(batch.count == 3)
            #expect(market.generatedUpdates <= 3 * cap)
            #expect(market.generatedUpdates >= 3 * cap * 9 / 10)
            for quote in batch {
                #expect(quote.eventNs <= toMs * 1_000_000)
                #expect(toMs * 1_000_000 - quote.eventNs < 60_000_000_000, "the last tick is within a minute of toMs")
                #expect(quote.candle1s.openTimeMs > toMs - 60_000)
            }
        }

        /// Whatever the step, the work of a call is bounded: even a jump across the whole range of times does not trap
        /// or run away, and what it generates is still capped.
        @Test func aJumpAcrossAllOfTimeIsBounded() {
            var market = SimulatedMarket(symbols: threeSymbols, seed: 4, startMs: Int64.min)

            let batch = market.advance(toMs: Int64.max, updatesPerSymbolPerSecond: 1_000_000)

            #expect(batch.count == 3)
            #expect(market.generatedUpdates <= 3 * SimulatedMarket.maxTicksPerCall)
            for quote in batch {
                #expect(quote.eventNs > 0)
                #expect(quote.candle1s.close == quote.last)
            }
        }

        // MARK: - One source of truth for the book

        /// `quote(_:)` always reports the best level of `depth(_:)`: after `updateDepth` removes the best level,
        /// changes a quantity, drops a level to zero or adds a better one, the quote follows at once. Nothing else in
        /// the quote moves.
        @Test func quoteFollowsTheBestLevelAfterUpdateDepth() throws {
            var market = defaultMarket
            let start = try #require(market.quote(ptt.id))
            let book = try #require(market.depth(ptt.id))

            market.updateDepth(ptt.id) { $0.asks.removeFirst() }
            var quote = try #require(market.quote(ptt.id))
            #expect(quote.ask == book.asks[1].price && quote.askQty == book.asks[1].quantity)
            #expect(quote.bid == book.bids[0].price && quote.bidQty == book.bids[0].quantity)

            market.updateDepth(ptt.id) { $0.bids[0].quantity = 700 }
            quote = try #require(market.quote(ptt.id))
            #expect(quote.bid == book.bids[0].price && quote.bidQty == 700)

            market.updateDepth(ptt.id) { $0.bids[0].quantity = 0 }
            quote = try #require(market.quote(ptt.id))
            let dropped = try #require(market.depth(ptt.id))
            #expect(dropped.bids.count == 4, "a level with no quantity is dropped")
            #expect(quote.bid == book.bids[1].price && quote.bidQty == book.bids[1].quantity)

            market.updateDepth(ptt.id) { $0.asks.insert(BookLevel(price: book.asks[0].price, quantity: 300), at: 0) }
            quote = try #require(market.quote(ptt.id))
            #expect(quote.ask == book.asks[0].price && quote.askQty == 300)

            #expect(quote.last == start.last && quote.dayVolume == start.dayVolume)
            #expect(quote.candle1s == start.candle1s && quote.eventNs == start.eventNs)
        }

        /// Emptying a side leaves its quote at the previous price with no quantity, until the next `advance` that moves
        /// the clock puts the book back.
        @Test func anEmptiedSideKeepsItsPriceWithNoQuantityUntilTheNextAdvance() throws {
            var market = defaultMarket
            let before = try #require(market.quote(ptt.id))

            market.updateDepth(ptt.id) {
                $0.bids.removeAll()
                $0.asks.removeAll()
            }

            let emptied = try #require(market.quote(ptt.id))
            #expect(emptied.bid == before.bid && emptied.bidQty == 0)
            #expect(emptied.ask == before.ask && emptied.askQty == 0)
            #expect(market.depth(ptt.id) == BookDepth(bids: [], asks: []))

            _ = market.advance(toMs: marketStartMs + 1000, updatesPerSymbolPerSecond: 20)

            let quote = try #require(market.quote(ptt.id))
            let depth = try #require(market.depth(ptt.id))
            #expect(problems(quote, depth, ptt).isEmpty, "\(problems(quote, depth, ptt))")
        }

        /// A book that was changed is repaired by the next call that moves the clock even when no tick comes, and the
        /// repaired quote is returned (and only that symbol's): its `eventNs` is `toMs`, since nothing traded.
        @Test func aRepairedBookIsReturnedEvenWhenNoTickHappened() throws {
            var market = defaultMarket
            market.updateDepth(ptt.id) { $0.asks.removeFirst() }

            let batch = market.advance(toMs: marketStartMs + 1, updatesPerSymbolPerSecond: 0)

            #expect(batch.map(\.symbolId) == [ptt.id])
            #expect(market.generatedUpdates == 0)
            let quote = try #require(batch.first)
            let depth = try #require(market.depth(ptt.id))
            #expect(quote.eventNs == (marketStartMs + 1) * 1_000_000)
            #expect(market.quote(ptt.id) == quote)
            #expect(problems(quote, depth, ptt).isEmpty, "\(problems(quote, depth, ptt))")
        }

        // MARK: - History stays contiguous

        /// At 0.2 updates a second most seconds have no trade. The history still has no holes: each empty second is a
        /// flat candle with no volume that opens, closes and has its high and low at the price the last trade left,
        /// and the store slides: it still holds 1,001 candles and ends with the candle of the last trade, which is
        /// never after the clock's second and, here, within a minute of it. A silence at the end is not filled in
        /// until the next trade arrives, since only a trade tells the aggregator that a second has passed.
        @Test func aLowRateKeepsHistoryContiguousWithFlatCandlesInTheGaps() throws {
            var market = SimulatedMarket(symbols: Array(threeSymbols.prefix(2)), seed: 5, startMs: marketStartMs)
            let oldest = try #require(market.history(symbolId: 1, interval: .s1, limit: .max).first)
            var now = marketStartMs

            for _ in 0..<600 {
                now += 1000
                _ = market.advance(toMs: now, updatesPerSymbolPerSecond: 0.2)
            }

            for id in [1, 2] as [UInt32] {
                let history = market.history(symbolId: id, interval: .s1, limit: .max)
                let flat = history.enumerated().filter { $0.element.volume == 0 && $0.offset > 0 }
                let last = try #require(history.last)

                #expect(history.count == 1001)
                #expect(zip(history, history.dropFirst()).allSatisfy { $1.openTimeMs - $0.openTimeMs == 1000 })
                #expect(last.openTimeMs <= now / 1000 * 1000 && now - last.openTimeMs < 60_000, "\(last)")
                #expect(history.first?.openTimeMs == last.openTimeMs - 1_000_000)
                #expect(history.first.map { $0.openTimeMs > oldest.openTimeMs + 540_000 } == true)
                #expect(flat.count > 200, "\(flat.count) empty seconds")
                for (index, candle) in flat {
                    #expect(candle.open == history[index - 1].close, "\(candle)")
                    #expect(candle.high == candle.open && candle.low == candle.open && candle.close == candle.open)
                }
            }
        }

        /// Three days in one call: the history covers the skipped time with flat candles, so it is contiguous from the
        /// last candle that was there before the jump to the first of the ticks that were generated, and it holds
        /// 1,001 candles, no more.
        @Test(arguments: CandleInterval.allCases)
        func aLongJumpKeepsHistoryContiguousAndBounded(interval: CandleInterval) throws {
            var market = SimulatedMarket(symbols: [ptt], seed: 6, startMs: marketStartMs)

            let batch = market.advance(toMs: marketStartMs + 3 * 86_400_000, updatesPerSymbolPerSecond: 20)

            let quote = try #require(batch.first)
            let history = market.history(symbolId: ptt.id, interval: interval, limit: .max)
            let flat = history.filter { $0.volume == 0 }
            #expect(history.count == 1001)
            #expect(zip(history, history.dropFirst()).allSatisfy { $1.openTimeMs - $0.openTimeMs == widthMs(interval) })
            #expect(history.last == candle(interval, of: quote))
            #expect(interval == .s1 || flat.count > 800, "\(flat.count) flat candles")
        }

        // MARK: - Time and numbers at their extremes

        /// No start time, jump or number traps. A start outside the representable range of nanoseconds is clamped
        /// into it.
        @Test(arguments: [Int64.min, Int64.min + 1, -1, 0, 1, Int64.max - 1, Int64.max] as [Int64])
        func extremeStartTimesDoNotTrap(start: Int64) throws {
            var market = SimulatedMarket(symbols: [ptt], seed: 1, startMs: start)
            var issues: [String] = []

            func audit(_ quote: SymbolQuote?) throws {
                let quote = try #require(quote)
                let depth = try #require(market.depth(ptt.id))
                issues += problems(quote, depth, ptt)
                for interval in CandleInterval.allCases {
                    let history = market.history(symbolId: ptt.id, interval: interval, limit: .max)
                    let contiguous = zip(history, history.dropFirst()).allSatisfy {
                        $1.openTimeMs - $0.openTimeMs == widthMs(interval)
                    }
                    if history.count != 1001 || !contiguous || history.last != candle(interval, of: quote) {
                        issues.append("\(interval.label) history is \(history.count) candles, contiguous \(contiguous)")
                    }
                }
            }

            try audit(market.quote(ptt.id))
            try audit(market.advance(toMs: .max, updatesPerSymbolPerSecond: 20).first ?? market.quote(ptt.id))
            #expect(market.advance(toMs: .min, updatesPerSymbolPerSecond: 20).isEmpty)
            #expect(market.advance(toMs: start, updatesPerSymbolPerSecond: 20).isEmpty)
            try audit(market.quote(ptt.id))

            #expect(issues.isEmpty, "\(issues.prefix(5))")
        }

        /// A seed of `UInt64.max` and a reference price of `Int64.max` are as good as any other: the band saturates,
        /// the ticks are 200 satang and no sum overflows.
        @Test func aHugeReferenceAndSeedDoNotOverflow() {
            let symbol = makeSymbol(1, reference: .max)
            var market = SimulatedMarket(symbols: [symbol], seed: .max, startMs: marketStartMs)
            var issues: [String] = []
            var now = marketStartMs

            #expect(market.quote(1) != nil)
            for _ in 0..<100 {
                now += 100
                for quote in market.advance(toMs: now, updatesPerSymbolPerSecond: 100) {
                    if let depth = market.depth(quote.symbolId) {
                        issues += problems(quote, depth, symbol)
                    }
                }
            }

            #expect(issues.isEmpty, "\(issues.prefix(5))")
        }

        // MARK: - Symbols the market cannot use

        /// A repeated id is ignored (the first one wins); a symbol whose price band cannot hold a five-level book (no
        /// price, a negative one, or under 17 satang) is left out of the market as if it did not exist, and 17
        /// satang is the smallest that works.
        @Test func symbolsThatCannotHoldABookOrRepeatAnIdAreLeftOut() throws {
            let market = SimulatedMarket(
                symbols: [
                    makeSymbol(1, reference: 3425), makeSymbol(1, reference: 9999),
                    makeSymbol(2, reference: 0), makeSymbol(3, reference: -500), makeSymbol(4, reference: 16),
                    makeSymbol(5, reference: 17), makeSymbol(6, reference: .min),
                ],
                seed: 1, startMs: marketStartMs
            )

            #expect(market.quote(2) == nil && market.quote(3) == nil && market.quote(4) == nil)
            #expect(market.quote(6) == nil)
            #expect(market.depth(4) == nil)
            #expect(market.history(symbolId: 4, interval: .s1, limit: 10).isEmpty)
            let first = try #require(market.quote(1))
            #expect(TickRules.band(reference: Price(satang: 3425)).contains(first.last), "the first symbol 1 is kept")
            let smallest = try #require(market.quote(5))
            let smallestBook = try #require(market.depth(5))
            #expect(problems(smallest, smallestBook, makeSymbol(5, reference: 17)).isEmpty)
        }

        @Test func aMarketWithNoSymbolsIsEmptyButRuns() {
            var market = SimulatedMarket(symbols: [], seed: 1, startMs: marketStartMs)

            #expect(market.advance(toMs: marketStartMs + 1000, updatesPerSymbolPerSecond: 20).isEmpty)
            #expect(market.generatedUpdates == 0)
            #expect(market.quote(1) == nil)
        }

        // MARK: - Cost

        /// Building the twelve default symbols takes about a third of a second in a release build. The bound here is
        /// generous (10 seconds, in a debug build) and exists to catch a generator that produces every tick of the
        /// history instead of a few steps for each candle: that would take minutes.
        @Test func buildingTheDefaultMarketIsFast() {
            var market: SimulatedMarket?

            let elapsed = ContinuousClock().measure {
                market = SimulatedMarket(symbols: catalogSymbols, seed: 7, startMs: marketStartMs)
            }

            #expect(elapsed < .seconds(10), "took \(elapsed)")
            for interval in CandleInterval.allCases {
                #expect(market?.history(symbolId: 1, interval: interval, limit: .max).count == 1001)
            }
        }
    }
}

import Testing
import TradeCore
@testable import ExchangeCore

private func price(_ satang: Int64) -> Price {
    Price(satang: satang)
}

private func level(_ satang: Int64, _ quantity: Quantity) -> BookLevel {
    BookLevel(price: price(satang), quantity: quantity)
}

private func fill(_ satang: Int64, _ quantity: Quantity) -> Fill {
    Fill(price: price(satang), quantity: quantity)
}

/// Bids 34.00 x 200 and 33.75 x 300, asks 34.25 x 200 and 34.50 x 300: 500 shares to sell into and 500 to buy.
private let twoLevelBook = BookDepth(
    bids: [level(3400, 200), level(3375, 300)],
    asks: [level(3425, 200), level(3450, 300)]
)

/// What an order gets back when nothing trades and nothing is left over: no fills and a remainder of 0.
private let nothingTraded = SweepResult(fills: [], remaining: 0)

/// A quote with the given best prices and sizes. Nothing else in a quote plays a part in matching, so the last price is
/// the bid and every candle is the same flat, empty one. The sizes differ by default, so a test notices an
/// implementation that reads the size of the wrong side.
private func makeQuote(bid: Int64, ask: Int64, bidQty: Quantity = 900, askQty: Quantity = 800) -> SymbolQuote {
    let flat = Candle(openTimeMs: 0, open: price(bid), high: price(bid), low: price(bid), close: price(bid), volume: 0)
    return SymbolQuote(
        symbolId: 1, last: price(bid), bid: price(bid), ask: price(ask), bidQty: bidQty, askQty: askQty, dayVolume: 0,
        candle1s: flat, candle1m: flat, candle5m: flat, eventNs: 0
    )
}

struct MatchingTests {
    // MARK: - Sweeping the book

    /// A market buy of 400 takes the whole first ask (200 at 34.25) and 200 of the 300 at 34.50: one fill per level,
    /// each at that level's own price, and nothing left over.
    @Test func marketBuySweepsMultipleLevels() {
        let result = Matching.sweep(side: .buy, quantity: 400, limit: nil, depth: twoLevelBook)

        #expect(result == SweepResult(fills: [fill(3425, 200), fill(3450, 200)], remaining: 0))
    }

    /// 1,000 shares against the 500 on offer: both levels are taken whole and the other 500 shares are left over.
    @Test func marketBuyBeyondDepthLeavesRemaining() {
        let result = Matching.sweep(side: .buy, quantity: 1000, limit: nil, depth: twoLevelBook)

        #expect(result == SweepResult(fills: [fill(3425, 200), fill(3450, 300)], remaining: 500))
    }

    /// The sell mirror: a market sell walks the bids from the highest price down.
    @Test func marketSellBeyondDepthLeavesRemaining() {
        let result = Matching.sweep(side: .sell, quantity: 1000, limit: nil, depth: twoLevelBook)

        #expect(result == SweepResult(fills: [fill(3400, 200), fill(3375, 300)], remaining: 500))
    }

    /// A limit buy at 34.25 takes the ask that is exactly at its limit (equal prices cross) and stops before 34.50.
    @Test func limitBuyStopsAtLimit() {
        let result = Matching.sweep(side: .buy, quantity: 400, limit: price(3425), depth: twoLevelBook)

        #expect(result == SweepResult(fills: [fill(3425, 200)], remaining: 200))
    }

    /// A limit sell at 33.75 walks the bids from 34.00 down and takes the second one, which is exactly at its limit.
    @Test func limitSellSweepsBidsDescending() {
        let result = Matching.sweep(side: .sell, quantity: 400, limit: price(3375), depth: twoLevelBook)

        #expect(result == SweepResult(fills: [fill(3400, 200), fill(3375, 200)], remaining: 0))
    }

    /// The sell mirror of the limit buy: a limit sell at 34.00 takes the bid at its limit and stops before 33.75.
    @Test func limitSellStopsAtLimit() {
        let result = Matching.sweep(side: .sell, quantity: 400, limit: price(3400), depth: twoLevelBook)

        #expect(result == SweepResult(fills: [fill(3400, 200)], remaining: 200))
    }

    /// A limit that does not reach the best level on the other side trades nothing and leaves the whole order. The best
    /// ask is 34.25 and the best bid 34.00; a limit one satang short is already too far.
    @Test(arguments: [
        // side, limit
        (.buy, 3400),
        (.buy, 3424),  // one satang short of the best ask
        (.sell, 3425),
        (.sell, 3401), // one satang short of the best bid
    ] as [(Side, Int64)])
    func nonMarketableLimitHasNoFills(side: Side, limit: Int64) {
        let result = Matching.sweep(side: side, quantity: 400, limit: price(limit), depth: twoLevelBook)

        #expect(result == SweepResult(fills: [], remaining: 400))
    }

    /// The order trades at the price of each level it takes, not at its own limit: a limit buy at 35.00 pays 34.25
    /// and 34.50, and a limit sell at 33.00 gets 34.00 and 33.75.
    @Test func anOrderTradesAtTheRestingPricesNotAtItsOwnLimit() {
        let buy = Matching.sweep(side: .buy, quantity: 500, limit: price(3500), depth: twoLevelBook)
        let sell = Matching.sweep(side: .sell, quantity: 500, limit: price(3300), depth: twoLevelBook)

        #expect(buy == SweepResult(fills: [fill(3425, 200), fill(3450, 300)], remaining: 0))
        #expect(sell == SweepResult(fills: [fill(3400, 200), fill(3375, 300)], remaining: 0))
    }

    /// An order for exactly what the best level holds is one fill of that whole level: nothing is left over and the
    /// next level is not touched.
    @Test(arguments: [(.buy, 3425), (.sell, 3400)] as [(Side, Int64)])
    func aLevelTakenExactlyIsOneFillOfItsWholeQuantity(side: Side, levelPrice: Int64) {
        let result = Matching.sweep(side: side, quantity: 200, limit: nil, depth: twoLevelBook)

        #expect(result == SweepResult(fills: [fill(levelPrice, 200)], remaining: 0))
    }

    /// An order for no shares, or for less than none, trades nothing and leaves nothing (the remainder is 0, never
    /// negative), market or limit, on either side.
    @Test(arguments: [0, -1, -100, Int64.min] as [Int64], [Side.buy, .sell])
    func aQuantityThatIsNotPositiveTradesNothingAndLeavesNothing(quantity: Int64, side: Side) {
        let crossing = side == .buy ? price(3500) : price(3300)

        let market = Matching.sweep(side: side, quantity: quantity, limit: nil, depth: twoLevelBook)
        let limited = Matching.sweep(side: side, quantity: quantity, limit: crossing, depth: twoLevelBook)

        #expect(market == nothingTraded)
        #expect(limited == nothingTraded)
    }

    /// A limit that is not a positive price is compared like any other price (the exchange engine rejects such an
    /// order before it gets here): a buy limited to it reaches no level and a sell limited to it reaches every one.
    @Test(arguments: [0, -1, Int64.min] as [Int64])
    func aLimitThatIsNotPositiveIsComparedLikeAnyOtherPrice(limit: Int64) {
        let buy = Matching.sweep(side: .buy, quantity: 1000, limit: price(limit), depth: twoLevelBook)
        let sell = Matching.sweep(side: .sell, quantity: 1000, limit: price(limit), depth: twoLevelBook)

        #expect(buy == SweepResult(fills: [], remaining: 1000))
        #expect(sell == SweepResult(fills: [fill(3400, 200), fill(3375, 300)], remaining: 500))
    }

    /// A level that holds no shares (or a negative number, which is as good as none) is passed over: it is not filled
    /// and it is no reason to stop. Here empty levels come first, in the middle and last.
    @Test(arguments: [0, -1, Int64.min] as [Int64])
    func levelsWithoutSharesAreSkipped(held: Int64) {
        let depth = BookDepth(
            bids: [level(3400, held), level(3375, 300), level(3350, held), level(3325, 100), level(3300, held)],
            asks: [level(3425, held), level(3450, 300), level(3475, held), level(3500, 100), level(3525, held)]
        )

        let buy = Matching.sweep(side: .buy, quantity: 1000, limit: nil, depth: depth)
        let sell = Matching.sweep(side: .sell, quantity: 1000, limit: nil, depth: depth)

        #expect(buy == SweepResult(fills: [fill(3450, 300), fill(3500, 100)], remaining: 600))
        #expect(sell == SweepResult(fills: [fill(3375, 300), fill(3325, 100)], remaining: 600))
    }

    /// A side with nothing to take (no level, or only levels with no shares) trades nothing and keeps the whole order.
    /// An order never borrows from its own side: the other side of the book is full here and is not used.
    @Test(arguments: [Side.buy, .sell], [[], [level(3425, 0)], [level(3425, -100)]] as [[BookLevel]])
    func aSideWithNothingToTakeTradesNothing(side: Side, dead: [BookLevel]) {
        let depth = side == .buy
            ? BookDepth(bids: twoLevelBook.bids, asks: dead)
            : BookDepth(bids: dead, asks: twoLevelBook.asks)

        let result = Matching.sweep(side: side, quantity: 300, limit: nil, depth: depth)

        #expect(result == SweepResult(fills: [], remaining: 300))
    }

    /// The walk goes level by level in the book's order and stops at the first level beyond the limit; it does not look
    /// further down for a level that is inside it. A book is always best first, so this only shows on one that is not.
    /// The first level beyond the limit stops the walk even when it holds no shares.
    @Test func theWalkStopsAtTheFirstLevelBeyondTheLimit() {
        let unsorted = BookDepth(
            bids: [level(3375, 300), level(3400, 200)],
            asks: [level(3450, 300), level(3425, 200)]
        )
        let reentering = BookDepth(bids: [], asks: [level(3425, 200), level(3450, 300), level(3430, 100)])
        let emptyFirst = BookDepth(bids: [], asks: [level(3450, 0), level(3425, 200)])

        let buy = Matching.sweep(side: .buy, quantity: 500, limit: price(3440), depth: unsorted)
        let sell = Matching.sweep(side: .sell, quantity: 500, limit: price(3380), depth: unsorted)
        let again = Matching.sweep(side: .buy, quantity: 500, limit: price(3440), depth: reentering)
        let empty = Matching.sweep(side: .buy, quantity: 500, limit: price(3440), depth: emptyFirst)

        #expect(buy == SweepResult(fills: [], remaining: 500))
        #expect(sell == SweepResult(fills: [], remaining: 500))
        #expect(again == SweepResult(fills: [fill(3425, 200)], remaining: 300))
        #expect(empty == SweepResult(fills: [], remaining: 500))
    }

    /// Nothing traps or wraps at the ends of `Int64`. Quantities are only compared, and taken from a larger one, so a
    /// book whose levels together hold more than `Int64.max` is no problem.
    @Test func extremeQuantitiesDoNotTrap() {
        let top = Int64.max
        let deep = BookDepth(bids: [], asks: [level(3425, top), level(3450, top)])
        let smallFirst = BookDepth(bids: [], asks: [level(3425, 5), level(3450, top)])
        let nearlyDeep = BookDepth(bids: [], asks: [level(3425, top - 1), level(3450, top)])

        let wholeFirstLevel = Matching.sweep(side: .buy, quantity: top, limit: nil, depth: deep)
        let acrossBoth = Matching.sweep(side: .buy, quantity: top, limit: nil, depth: smallFirst)
        let cutByTheLimit = Matching.sweep(side: .buy, quantity: top, limit: price(3425), depth: nearlyDeep)

        #expect(wholeFirstLevel == SweepResult(fills: [fill(3425, top)], remaining: 0))
        #expect(acrossBoth == SweepResult(fills: [fill(3425, 5), fill(3450, top - 5)], remaining: 0))
        #expect(cutByTheLimit == SweepResult(fills: [fill(3425, top - 1)], remaining: 1))
    }

    /// Prices are only compared, so a limit or a level at either end of `Int64` is no problem, and equal prices cross
    /// there too.
    @Test func extremePricesDoNotTrap() {
        let depth = BookDepth(
            bids: [level(Int64.max, 100), level(Int64.min, 100)],
            asks: [level(Int64.min, 100), level(Int64.max, 100)]
        )

        let buyUp = Matching.sweep(side: .buy, quantity: 200, limit: price(Int64.max), depth: depth)
        let sellDown = Matching.sweep(side: .sell, quantity: 200, limit: price(Int64.min), depth: depth)
        let buyDown = Matching.sweep(side: .buy, quantity: 200, limit: price(Int64.min), depth: depth)
        let sellUp = Matching.sweep(side: .sell, quantity: 200, limit: price(Int64.max), depth: depth)

        #expect(buyUp == SweepResult(fills: [fill(Int64.min, 100), fill(Int64.max, 100)], remaining: 0))
        #expect(sellDown == SweepResult(fills: [fill(Int64.max, 100), fill(Int64.min, 100)], remaining: 0))
        #expect(buyDown == SweepResult(fills: [fill(Int64.min, 100)], remaining: 100))
        #expect(sellUp == SweepResult(fills: [fill(Int64.max, 100)], remaining: 100))
    }
}

// MARK: - A resting limit order against the quote

extension MatchingTests {
    struct RestingFill {
        /// The size of what a resting order fills: the smaller of what is left of it and what the best level shows.
        private static let sizes = [
            // remaining, shown at the best level, filled
            (300, 800, 300), // the level shows more than is wanted: the order is filled in full
            (700, 500, 500), // the level shows less: the fill is what it shows
            (500, 500, 500),
            (100, 100, 100),
        ] as [(Int64, Int64, Int64)]

        /// A resting buy at 34.25 against an ask of 34.00, which is inside its limit: it trades at its own limit, not
        /// at the better ask, for the smaller of what is left and what the ask shows.
        @Test(arguments: sizes)
        func restingBuyFillsWhenAskCrossesLimit(remaining: Quantity, askQty: Quantity, filled: Quantity) {
            let quote = makeQuote(bid: 3375, ask: 3400, askQty: askQty)

            let result = Matching.restingFill(side: .buy, limit: price(3425), remaining: remaining, quote: quote)

            #expect(result == fill(3425, filled))
        }

        /// The sell mirror: a resting sell at 34.25 against a bid of 34.50 trades at 34.25, for the smaller of what is
        /// left and what the bid shows.
        @Test(arguments: sizes)
        func restingSellFillsWhenBidCrossesLimit(remaining: Quantity, bidQty: Quantity, filled: Quantity) {
            let quote = makeQuote(bid: 3450, ask: 3475, bidQty: bidQty)

            let result = Matching.restingFill(side: .sell, limit: price(3425), remaining: remaining, quote: quote)

            #expect(result == fill(3425, filled))
        }

        /// An ask above the limit is not reached: the order keeps resting.
        @Test func restingBuyIgnoredAboveLimit() {
            let quote = makeQuote(bid: 3425, ask: 3450)

            #expect(Matching.restingFill(side: .buy, limit: price(3425), remaining: 300, quote: quote) == nil)
        }

        /// Equal prices cross: a quote exactly at the limit fills, and one satang short of it does not (nor does a
        /// whole tick short, which for a sell is the bid below the limit).
        @Test(arguments: [
            // side, the best price the order could trade at (against a limit of 3425), whether it fills
            (.buy, 3425, true),
            (.buy, 3426, false),
            (.sell, 3425, true),
            (.sell, 3424, false),
            (.sell, 3400, false),
        ] as [(Side, Int64, Bool)])
        func equalPricesCrossAndAQuoteShortOfTheLimitDoesNot(side: Side, best: Int64, fills: Bool) {
            let quote = side == .buy ? makeQuote(bid: best - 25, ask: best) : makeQuote(bid: best, ask: best + 25)

            let result = Matching.restingFill(side: side, limit: price(3425), remaining: 300, quote: quote)

            let expected: Fill? = fills ? fill(3425, 300) : nil
            #expect(result == expected)
        }

        /// A side a sweep emptied keeps its price with a quantity of 0 until the market's next step: there is nothing
        /// to trade against, so there is no fill, although the price is inside the limit. A negative size is no better.
        @Test(arguments: [0, -100, Int64.min] as [Int64])
        func noFillWhenTheBestLevelHoldsNoShares(shown: Int64) {
            let buyable = makeQuote(bid: 3375, ask: 3400, askQty: shown)
            let sellable = makeQuote(bid: 3450, ask: 3475, bidQty: shown)

            #expect(Matching.restingFill(side: .buy, limit: price(3425), remaining: 300, quote: buyable) == nil)
            #expect(Matching.restingFill(side: .sell, limit: price(3425), remaining: 300, quote: sellable) == nil)
        }

        /// An order with nothing left to fill (zero, or less) never fills, although the quote is inside its limit.
        @Test(arguments: [0, -1, Int64.min] as [Int64])
        func noFillForAnOrderWithNothingLeft(remaining: Int64) {
            let buyable = makeQuote(bid: 3375, ask: 3400)
            let sellable = makeQuote(bid: 3450, ask: 3475)

            let buy = Matching.restingFill(side: .buy, limit: price(3425), remaining: remaining, quote: buyable)
            let sell = Matching.restingFill(side: .sell, limit: price(3425), remaining: remaining, quote: sellable)

            #expect(buy == nil)
            #expect(sell == nil)
        }

        /// A limit that is not a positive price is not one an order can rest at, so it never fills, although the quote
        /// is inside it: the ask is exactly at a buy's limit, and the bid is above a sell's.
        @Test(arguments: [0, -5, Int64.min] as [Int64])
        func noFillForALimitThatIsNotPositive(limit: Int64) {
            let buyable = makeQuote(bid: limit, ask: limit)
            let sellable = makeQuote(bid: 3400, ask: 3425)

            let buy = Matching.restingFill(side: .buy, limit: price(limit), remaining: 300, quote: buyable)
            let sell = Matching.restingFill(side: .sell, limit: price(limit), remaining: 300, quote: sellable)

            #expect(buy == nil)
            #expect(sell == nil)
        }

        /// Nothing traps at the ends of `Int64`: sizes are only compared, and so are prices.
        @Test func extremeQuantitiesAndPricesDoNotTrap() {
            let top = Int64.max
            let buyable = makeQuote(bid: 3375, ask: top, askQty: top)
            let sellable = makeQuote(bid: top, ask: top, bidQty: top)

            let buy = Matching.restingFill(side: .buy, limit: price(top), remaining: top, quote: buyable)
            let sell = Matching.restingFill(side: .sell, limit: price(1), remaining: top - 1, quote: sellable)
            let tooDear = Matching.restingFill(side: .buy, limit: price(top - 1), remaining: top, quote: buyable)

            #expect(buy == fill(top, top))
            #expect(sell == fill(1, top - 1))
            #expect(tooDear == nil)
        }
    }
}

// MARK: - Consuming what an order took

extension MatchingTests {
    struct Consume {
        /// The asks are 34.25 x 200 and 34.50 x 300. A buy that took the whole first level and 100 of the second leaves
        /// 200 at 34.50: the emptied level is gone and the bids are as they were.
        @Test func consumeRemovesLiquidityAndEmptiedLevels() {
            var depth = twoLevelBook

            depth.consume(side: .buy, fills: [fill(3425, 200), fill(3450, 100)])

            #expect(depth.asks == [level(3450, 200)])
            #expect(depth.bids == twoLevelBook.bids)
        }

        /// The aggressor's side decides which side loses shares: a sell trades with the bids and leaves the asks alone.
        @Test func aSellTakesFromTheBidsAndLeavesTheAsks() {
            var depth = twoLevelBook

            depth.consume(side: .sell, fills: [fill(3400, 200), fill(3375, 100)])

            #expect(depth.bids == [level(3375, 200)])
            #expect(depth.asks == twoLevelBook.asks)
        }

        /// A fill smaller than its level leaves the level in place with the rest of its shares.
        @Test func aPartialFillLeavesTheRestOfTheLevel() {
            var depth = twoLevelBook

            depth.consume(side: .buy, fills: [fill(3425, 50)])

            #expect(depth.asks == [level(3425, 150), level(3450, 300)])
        }

        /// Fills at one price add up on that level, so several small ones can take it whole, in any order among fills
        /// at other prices.
        @Test(arguments: [
            // the fills, the asks left
            ([fill(3425, 50), fill(3425, 100)], [level(3425, 50), level(3450, 300)]),
            ([fill(3425, 120), fill(3425, 80)], [level(3450, 300)]),
            ([fill(3425, 120), fill(3450, 100), fill(3425, 30)], [level(3425, 50), level(3450, 200)]),
        ] as [([Fill], [BookLevel])])
        func fillsAtOnePriceAddUp(fills: [Fill], left: [BookLevel]) {
            var depth = twoLevelBook

            depth.consume(side: .buy, fills: fills)

            #expect(depth.asks == left)
        }

        /// A level never goes below 0: a fill larger than its level removes the level and takes nothing from the next.
        @Test func aFillLargerThanItsLevelRemovesTheLevelAndNoMore() {
            var depth = twoLevelBook

            depth.consume(side: .buy, fills: [fill(3425, 500)])

            #expect(depth.asks == [level(3450, 300)])
        }

        /// A fill at a price the side does not have takes nothing: one between two levels, beyond the last, below the
        /// first, and a price that exists only on the other side of the book (3400 and 3375 are bids).
        @Test(arguments: [3430, 3500, 3400, 3375, 0, -1, Int64.min] as [Int64])
        func aFillAtAPriceTheSideDoesNotHaveChangesNothing(satang: Int64) {
            var depth = twoLevelBook

            depth.consume(side: .buy, fills: [fill(satang, 100)])

            #expect(depth == twoLevelBook)
        }

        /// A fill of no shares, or of less than none, changes nothing.
        @Test(arguments: [0, -1, -300, Int64.min] as [Int64])
        func aFillThatIsNotPositiveChangesNothing(quantity: Int64) {
            var depth = twoLevelBook

            depth.consume(side: .buy, fills: [fill(3425, quantity), fill(3450, quantity)])

            #expect(depth == twoLevelBook)
        }

        /// An empty list of fills, and an empty book, are no problem and change nothing.
        @Test func noFillsAndNoBookChangeNothing() {
            var depth = twoLevelBook
            var empty = BookDepth(bids: [], asks: [])

            depth.consume(side: .buy, fills: [])
            depth.consume(side: .sell, fills: [])
            empty.consume(side: .buy, fills: [fill(3425, 100)])
            empty.consume(side: .sell, fills: [fill(3400, 100)])

            #expect(depth == twoLevelBook)
            #expect(empty == BookDepth(bids: [], asks: []))
        }

        /// A level left with no shares is dropped, and so is one that held none (or a negative number) before, even
        /// when there are no fills at all. The levels that stay keep their order.
        @Test(arguments: [
            // the fills, the asks left
            ([], [level(3450, 300), level(3500, 100)]),
            ([fill(3450, 300)], [level(3500, 100)]),
            ([fill(3500, 40)], [level(3450, 300), level(3500, 60)]),
        ] as [([Fill], [BookLevel])])
        func levelsWithNoSharesAreDroppedWhateverTheFills(fills: [Fill], left: [BookLevel]) {
            var depth = BookDepth(
                bids: [],
                asks: [level(3425, 0), level(3450, 300), level(3475, -100), level(3500, 100)]
            )

            depth.consume(side: .buy, fills: fills)

            #expect(depth.asks == left)
        }

        /// A buy leaves the bids exactly as they were, not even dropping a level that holds no shares, and a fill at a
        /// price that is on the bids (3400) is no business of theirs.
        @Test func aBuyLeavesTheBidsExactlyAsTheyWere() {
            let bids = [level(3400, 0), level(3375, 300), level(3350, -100)]
            var depth = BookDepth(bids: bids, asks: [level(3425, 200), level(3450, 300)])

            depth.consume(side: .buy, fills: [fill(3425, 200), fill(3400, 100)])

            #expect(depth.bids == bids)
            #expect(depth.asks == [level(3450, 300)])
        }

        /// A sell leaves the asks exactly as they were, in the same way.
        @Test func aSellLeavesTheAsksExactlyAsTheyWere() {
            let asks = [level(3425, 0), level(3450, 300), level(3475, -100)]
            var depth = BookDepth(bids: [level(3400, 200), level(3375, 300)], asks: asks)

            depth.consume(side: .sell, fills: [fill(3400, 200), fill(3425, 100)])

            #expect(depth.asks == asks)
            #expect(depth.bids == [level(3375, 300)])
        }

        /// A book that lists one price on two levels (the market never builds one) is taken level by level, the way a
        /// sweep walks it: each fill comes off the first level at its price that still holds shares.
        @Test func eachFillComesOffTheFirstLevelAtItsPriceThatStillHoldsShares() {
            var depth = BookDepth(bids: [], asks: [level(3425, 100), level(3425, 100), level(3450, 300)])

            depth.consume(side: .buy, fills: [fill(3425, 100), fill(3425, 50)])

            #expect(depth.asks == [level(3425, 50), level(3450, 300)])
        }

        /// Nothing traps or wraps at the ends of `Int64`: a level loses at most what it holds, fills are applied one at
        /// a time and never summed, and a negative size is dropped without anything being taken from it.
        @Test func extremeQuantitiesDoNotTrap() {
            let top = Int64.max
            var depth = BookDepth(
                bids: [],
                asks: [level(3425, top), level(3450, Int64.min), level(3475, top), level(3500, 5)]
            )

            depth.consume(
                side: .buy,
                fills: [fill(3425, top), fill(3425, top), fill(3450, top), fill(3475, top - 1), fill(3500, top)]
            )

            #expect(depth.asks == [level(3475, 1)])
        }

        /// What an order does to a book from end to end: sweep, then consume its fills. The levels it took whole are
        /// gone, the one it only dented keeps the rest, and the deeper level and the other side are as they were.
        @Test func consumingASweepLeavesWhatTheOrderDidNotTake() {
            let depth = BookDepth(
                bids: [level(3400, 200)],
                asks: [level(3425, 200), level(3450, 300), level(3475, 400)]
            )
            let swept = Matching.sweep(side: .buy, quantity: 600, limit: nil, depth: depth)
            var after = depth

            after.consume(side: .buy, fills: swept.fills)

            #expect(swept == SweepResult(fills: [fill(3425, 200), fill(3450, 300), fill(3475, 100)], remaining: 0))
            #expect(after == BookDepth(bids: [level(3400, 200)], asks: [level(3475, 300)]))
        }
    }
}

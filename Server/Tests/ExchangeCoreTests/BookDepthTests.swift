import Testing
import TradeCore
@testable import ExchangeCore

private func price(_ satang: Int64) -> Price {
    Price(satang: satang)
}

private func requireSendable<T: Sendable>(_: T.Type) {}

/// The prices at which the tick size changes, in satang: 2, 5, 10, 25, 100, 200 and 400 baht.
private let tierEdges: [Int64] = [200, 500, 1000, 2500, 10_000, 20_000, 40_000]

/// Every on-tick price from 1 satang to 500.00 baht, ascending: both sides of every tier edge, found by asking
/// `TickRules` about each satang, so the grid maths below is checked against the rules and not against itself.
private let onTickPrices: [Int64] = (Int64(1)...50_000).filter { TickRules.isOnTick(price($0)) }

struct PriceGridTests {
    /// Stepping up from an on-tick price lands on the next on-tick price, and stepping down on the one before it,
    /// across all seven tier edges. This is the property the walk and the ladders rely on: a step is one tick, and the
    /// result is never off tick, even where the tick size changes.
    @Test func upAndDownMoveToTheNeighbouringOnTickPrice() {
        var wrong: [String] = []

        for (below, above) in zip(onTickPrices, onTickPrices.dropFirst()) {
            let up = PriceGrid.up(price(below)).satang
            let down = PriceGrid.down(price(above)).satang
            if up != above {
                wrong.append("up(\(below)) = \(up), expected \(above)")
            }
            if down != below {
                wrong.append("down(\(above)) = \(down), expected \(below)")
            }
        }

        #expect(wrong.isEmpty, "\(wrong.prefix(5))")
    }

    /// Several ticks at once are repeated single ticks; a count of zero or less does not move.
    @Test func manyTicksAreRepeatedSingleTicks() {
        #expect(PriceGrid.up(price(9900), ticks: 4) == price(10_000))
        #expect(PriceGrid.up(price(9900), ticks: 6) == price(10_100))
        #expect(PriceGrid.down(price(10_100), ticks: 6) == price(9900))
        #expect(PriceGrid.up(price(3425), ticks: 0) == price(3425))
        #expect(PriceGrid.up(price(3425), ticks: -3) == price(3425))
        #expect(PriceGrid.down(price(3425), ticks: 0) == price(3425))
        #expect(PriceGrid.down(price(3425), ticks: -3) == price(3425))
    }

    /// The cheapest valid price is 1 satang: there is nothing below it to step down to.
    @Test(arguments: [1, 0, -5] as [Int64])
    func thereIsNothingToStepDownToAtTheBottom(satang: Int64) {
        #expect(PriceGrid.down(price(satang)) == price(satang))
    }

    /// `snappedDown` is the largest on-tick price at or below the argument, `snappedUp` the smallest at or above it,
    /// for every satang from 1 to 500.00 baht (an on-tick price is its own snap).
    @Test func snapsFindTheNearestOnTickPriceBelowAndAbove() {
        var wrong: [String] = []
        var index = 0

        for satang in Int64(1)...50_000 {
            while index + 1 < onTickPrices.count, onTickPrices[index + 1] <= satang {
                index += 1
            }
            let expectedDown = onTickPrices[index]
            let expectedUp = expectedDown == satang ? satang : onTickPrices[index + 1]
            let down = PriceGrid.snappedDown(price(satang)).satang
            let up = PriceGrid.snappedUp(price(satang)).satang
            if down != expectedDown || up != expectedUp {
                wrong.append("\(satang): down \(down) (expected \(expectedDown)), up \(up) (expected \(expectedUp))")
            }
        }

        #expect(wrong.isEmpty, "\(wrong.prefix(5))")
    }

    /// No price at or below zero is on a tick: nothing is at or below it, and the first price there is is 1 satang.
    @Test(arguments: [0, -1, Int64.min] as [Int64])
    func nonPositivePricesHaveNothingBelowAndOneSatangAbove(satang: Int64) {
        #expect(PriceGrid.snappedDown(price(satang)) == price(0))
        #expect(PriceGrid.snappedUp(price(satang)) == price(1))
    }

    /// Nothing traps at the ends of `Int64`. A step that would overflow stays where it is. The largest on-tick price is
    /// `Int64.max - 7` (the tick there is 200 and `Int64.max % 200` is 7), so `snappedUp` of anything above it can only
    /// saturate at `Int64.max`.
    @Test func extremePricesDoNotTrap() {
        #expect(PriceGrid.up(price(.max)) == price(.max))
        #expect(PriceGrid.up(price(.max - 1), ticks: 5) == price(.max - 1))
        #expect(PriceGrid.down(price(.min)) == price(.min))
        #expect(PriceGrid.down(price(.max)) == price(Int64.max - 7))
        #expect(PriceGrid.snappedDown(price(.max)) == price(Int64.max - 7))
        #expect(PriceGrid.snappedUp(price(.max)) == price(.max))
        #expect(PriceGrid.snappedUp(price(Int64.max - 7)) == price(Int64.max - 7))
    }

    /// A walk step moves whole ticks, never leaves the range, and stops at an edge instead of overshooting it.
    @Test(arguments: [
        // start, ticks, range, expected
        (3425, 3, 2400...4450, 3500),     // 25-satang ticks: 3450, 3475, 3500
        (3425, -2, 2400...4450, 3375),
        (3425, 0, 2400...4450, 3425),
        (4425, 5, 2400...4450, 4450),     // one tick, then the upper edge stops it
        (2410, -5, 2400...4450, 2400),    // one tick (10 satang here), then the lower edge stops it
        (4450, 1, 2400...4450, 4450),
        (2400, -1, 2400...4450, 2400),
        (5000, 0, 2400...4450, 4450),     // a start outside the range is pulled in first
        (1000, 0, 2400...4450, 2400),
        (9975, 1, 2400...20_000, 10_000), // across the 100 baht edge: 25, then 50 satang ticks
        (10_000, -1, 2400...20_000, 9975),
        (9900, 4, 2400...20_000, 10_000),
        (10_000, 3, 2400...20_000, 10_150),
        (3425, 2, 3425...3425, 3425),     // a one-price range cannot be left
        (3425, Int.max, 3400...3450, 3450),
        (3425, Int.min, 3400...3450, 3400),
    ] as [(Int64, Int, ClosedRange<Int64>, Int64)])
    func movedStaysOnTickInsideTheRange(start: Int64, ticks: Int, range: ClosedRange<Int64>, expected: Int64) {
        let bounds = price(range.lowerBound)...price(range.upperBound)

        #expect(PriceGrid.moved(price(start), byTicks: ticks, within: bounds) == price(expected))
    }

    /// A ladder is `count` prices, one tick apart, strictly monotone and on tick, across every tier edge.
    @Test(arguments: tierEdges)
    func laddersStayStrictlyMonotoneAndOnTickAcrossATierEdge(edge: Int64) {
        let up = PriceGrid.ladder(from: PriceGrid.down(price(edge), ticks: 2), ascending: true, count: 5)
        let down = PriceGrid.ladder(from: PriceGrid.up(price(edge), ticks: 2), ascending: false, count: 5)

        #expect(up.count == 5 && down.count == 5)
        #expect(up.contains(price(edge)) && down.contains(price(edge)))
        #expect(zip(up, up.dropFirst()).allSatisfy { $0 < $1 })
        #expect(zip(down, down.dropFirst()).allSatisfy { $0 > $1 })
        #expect((up + down).allSatisfy { TickRules.isOnTick($0) })
    }

    @Test func aLadderOfNoLevelsIsEmpty() {
        #expect(PriceGrid.ladder(from: price(3425), ascending: true, count: 0).isEmpty)
        #expect(PriceGrid.ladder(from: price(3425), ascending: false, count: -2).isEmpty)
    }
}

struct BookDepthTests {
    private let bestBid = price(3425)

    private func replenished(
        _ book: BookDepth = BookDepth(bids: [], asks: []), spreadTicks: Int = 2, seed: UInt64 = 1
    ) -> BookDepth {
        var depth = book
        var generator = SeededGenerator(seed: seed)
        depth.replenish(bestBid: bestBid, spreadTicks: spreadTicks, baseQuantity: 5000, using: &generator)
        return depth
    }

    /// From an empty book: five levels a side, best first, one tick apart, with the ask `spreadTicks` above the bid.
    @Test func buildsFiveOnTickLevelsPerSideAroundTheBestBid() {
        let depth = replenished(spreadTicks: 2)

        #expect(depth.bids.map(\.price) == [3425, 3400, 3375, 3350, 3325].map(price))
        #expect(depth.asks.map(\.price) == [3475, 3500, 3525, 3550, 3575].map(price))
    }

    /// The spread is at least one tick whatever is asked for, so the book can never be crossed or locked.
    @Test(arguments: [1, 0, -4, Int.min])
    func theSpreadIsAtLeastOneTick(spreadTicks: Int) {
        let depth = replenished(spreadTicks: spreadTicks)

        #expect(depth.asks.first?.price == price(3450))
    }

    @Test func everyLevelHoldsAPositiveWholeNumberOfLots() {
        let depth = replenished()

        for level in depth.bids + depth.asks {
            #expect(level.quantity > 0 && level.quantity % TickRules.boardLot == 0, "\(level)")
        }
    }

    /// Deeper levels aim at bigger sizes: each level is 30% of the base bigger than the one before,
    /// target = base * (10 + 3 * level) / 10.
    @Test func deeperLevelsHaveBiggerTargets() {
        let targets = (0..<5).map { BookDepth.targetQuantity(base: 5000, level: $0) }

        #expect(targets == [5000, 6500, 8000, 9500, 11_000])
    }

    /// Each pass moves a level halfway to a noisy target in 50%...150% of its own target, so after enough passes every
    /// level sits in that band, whatever it started at: here a huge level, a level of one share (not a whole lot)
    /// and a side with no levels at all.
    @Test func quantitiesConvergeToTheirTargetBand() {
        var depth = BookDepth(
            bids: [BookLevel(price: bestBid, quantity: .max), BookLevel(price: price(3400), quantity: 1)],
            asks: []
        )
        var generator = SeededGenerator(seed: 9)

        for _ in 0..<120 {
            depth.replenish(bestBid: bestBid, spreadTicks: 1, baseQuantity: 5000, using: &generator)
        }

        for side in [depth.bids, depth.asks] {
            for (index, level) in side.enumerated() {
                let target = BookDepth.targetQuantity(base: 5000, level: index)
                #expect(level.quantity >= target / 2 - TickRules.boardLot, "level \(index): \(level.quantity)")
                #expect(level.quantity <= target * 3 / 2, "level \(index): \(level.quantity)")
            }
        }
    }

    /// A level whose price survives keeps most of its size; a price the book did not have is created at a fresh size.
    /// The best bid walked down one tick: the old second level is now the best one and still holds its huge size,
    /// and 3300 is new.
    @Test func carriesQuantitiesByPriceAndCreatesTheMissingLevels() {
        let old = [3425, 3400, 3375, 3350, 3325].map { BookLevel(price: price($0), quantity: 1_000_000) }
        var depth = BookDepth(bids: old, asks: [])
        var generator = SeededGenerator(seed: 4)

        depth.replenish(bestBid: price(3400), spreadTicks: 1, baseQuantity: 5000, using: &generator)

        #expect(depth.bids.map(\.price) == [3400, 3375, 3350, 3325, 3300].map(price))
        for level in depth.bids.prefix(4) {
            #expect(level.quantity >= 400_000, "\(level)")
        }
        #expect(depth.bids[4].quantity <= BookDepth.targetQuantity(base: 5000, level: 4) * 3 / 2, "\(depth.bids[4])")
        #expect(depth.asks.count == 5)
    }

    /// Quantities that are not valid are repaired, never carried: zero, negative, not a whole lot, and the extremes.
    @Test(arguments: [0, -100, 150, 99, Int64.min, Int64.max] as [Int64])
    func invalidQuantitiesAreRepaired(garbage: Int64) {
        let book = BookDepth(
            bids: [BookLevel(price: bestBid, quantity: garbage)],
            asks: [BookLevel(price: price(3450), quantity: garbage)]
        )

        let depth = replenished(book, spreadTicks: 1)

        for level in depth.bids + depth.asks {
            #expect(level.quantity > 0 && level.quantity % TickRules.boardLot == 0, "\(garbage) -> \(level)")
        }
    }

    @Test func theSameGeneratorGivesTheSameBook() {
        #expect(replenished(seed: 5) == replenished(seed: 5))
        #expect(replenished(seed: 5) != replenished(seed: 6))
    }

    @Test func dropsLevelsWithoutAPositiveQuantity() {
        var depth = BookDepth(
            bids: [BookLevel(price: price(3425), quantity: 0), BookLevel(price: price(3400), quantity: 300)],
            asks: [BookLevel(price: price(3450), quantity: -5), BookLevel(price: price(3475), quantity: 100)]
        )

        depth.dropEmptyLevels()

        #expect(depth.bids == [BookLevel(price: price(3400), quantity: 300)])
        #expect(depth.asks == [BookLevel(price: price(3475), quantity: 100)])
    }

    @Test func valueTypesAreEquatableAndSendable() {
        #expect(BookLevel(price: price(3425), quantity: 100) == BookLevel(price: price(3425), quantity: 100))
        #expect(BookLevel(price: price(3425), quantity: 100) != BookLevel(price: price(3425), quantity: 200))
        #expect(BookDepth(bids: [], asks: []) == BookDepth(bids: [], asks: []))
        requireSendable(BookLevel.self)
        requireSendable(BookDepth.self)
    }
}

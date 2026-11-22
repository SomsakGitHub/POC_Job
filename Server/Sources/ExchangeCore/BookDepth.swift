import TradeCore

/// One price level of the book: shares waiting at one price.
public struct BookLevel: Sendable, Equatable {
    public var price: Price
    public var quantity: Quantity

    public init(price: Price, quantity: Quantity) {
        self.price = price
        self.quantity = quantity
    }
}

/// The book of one symbol, best level first on each side: bids from the highest price down, asks from the lowest up.
///
/// `SimulatedMarket` keeps five levels a side, one tick apart, each holding a positive whole number of board lots. A
/// book can hold fewer between an order that took a level away (`updateDepth`) and the next `advance` that moves the
/// clock, which puts the missing levels back.
public struct BookDepth: Sendable, Equatable {
    public var bids: [BookLevel]
    public var asks: [BookLevel]

    public init(bids: [BookLevel], asks: [BookLevel]) {
        self.bids = bids
        self.asks = asks
    }
}

/// The market's view of one symbol after an `advance`: the last trade, the best bid and ask, the day's volume and the
/// current candle of each interval.
///
/// `bid`, `ask`, `bidQty` and `askQty` always equal the best level of `SimulatedMarket.depth(_:)`: the book is the one
/// source of truth. A side with no levels keeps its last price with a quantity of 0 until the book is replenished.
/// Prices are satang, quantities shares, and nothing here is a real quote: all of it is simulated.
public struct SymbolQuote: Sendable, Equatable {
    public let symbolId: UInt32
    public var last: Price
    public var bid: Price
    public var ask: Price
    public var bidQty: Quantity
    public var askQty: Quantity
    /// Shares traded so far today. It starts at an invented base, only grows, and grows by whole lots.
    public var dayVolume: Int64
    public var candle1s: Candle
    public var candle1m: Candle
    public var candle5m: Candle
    /// When the simulator produced this state: the simulated time of the symbol's last tick in the `advance` call that
    /// returned it, in nanoseconds since the Unix epoch and finer than a millisecond. It is never later than that
    /// call's `toMs`, never earlier than the one before it for the same symbol, and starts at the market's start time.
    /// A book repaired without a tick is stamped with that call's `toMs`, since nothing traded.
    public var eventNs: Int64

    public init(
        symbolId: UInt32, last: Price, bid: Price, ask: Price, bidQty: Quantity, askQty: Quantity, dayVolume: Int64,
        candle1s: Candle, candle1m: Candle, candle5m: Candle, eventNs: Int64
    ) {
        self.symbolId = symbolId
        self.last = last
        self.bid = bid
        self.ask = ask
        self.bidQty = bidQty
        self.askQty = askQty
        self.dayVolume = dayVolume
        self.candle1s = candle1s
        self.candle1m = candle1m
        self.candle5m = candle5m
        self.eventNs = eventNs
    }
}

/// Arithmetic on the price grid: one tick up or down, snapping to the grid, and walking within a range.
///
/// The tick size changes with the price (`TickRules.tickSize(at:)`), and every price where it changes is a multiple of
/// the tick on both sides of the change, so a step of one tick from an on-tick price always lands on the next on-tick
/// price, across a change too. Nothing here traps for any `Int64`: a step that would overflow stays where it is. The
/// tick counts are small numbers (a step is at most `Regime.maxStepTicks`), because each tick is one loop.
enum PriceGrid {
    /// `ticks` ticks up from an on-tick `price`; a count of zero or less does not move.
    static func up(_ price: Price, ticks: Int = 1) -> Price {
        var result = price
        for _ in 0..<max(ticks, 0) {
            let (sum, overflow) = result.satang.addingReportingOverflow(TickRules.tickSize(at: result).satang)
            if overflow { break }
            result = Price(satang: sum)
        }
        return result
    }

    /// `ticks` ticks down from an on-tick `price`. The step is taken from just below the price, so the tick size is
    /// the lower tier's. The cheapest valid price is 1 satang; nothing is below it, so a price of 1 or less stays.
    static func down(_ price: Price, ticks: Int = 1) -> Price {
        var result = price
        for _ in 0..<max(ticks, 0) {
            guard result.satang > 1 else { break }
            let below = result.satang - 1
            result = Price(satang: below - below % TickRules.tickSize(at: Price(satang: below)).satang)
        }
        return result
    }

    /// The largest on-tick price at or below `price`; 0 when there is none (a price below 1 satang). Rounding down
    /// to a multiple of the tick never crosses into the tier below, because each tier starts on a multiple of its tick.
    static func snappedDown(_ price: Price) -> Price {
        guard price.satang > 0 else { return Price(satang: 0) }
        return Price(satang: price.satang - price.satang % TickRules.tickSize(at: price).satang)
    }

    /// The smallest on-tick price at or above `price`; 1 satang for a price below that. Saturates at `Int64.max`,
    /// where no on-tick price is left to snap up to.
    static func snappedUp(_ price: Price) -> Price {
        guard price.satang > 0 else { return Price(satang: 1) }
        let floor = snappedDown(price)
        guard floor != price else { return price }
        let (sum, overflow) = floor.satang.addingReportingOverflow(TickRules.tickSize(at: floor).satang)
        return Price(satang: overflow ? .max : sum)
    }

    /// `price` moved by `ticks` (up if positive, down if negative), kept inside `range`. A start outside the range is
    /// pulled in first, and a move that would leave the range stops at its edge, so the result is always in `range`
    /// and, when the range's edges are on tick, on tick.
    static func moved(_ price: Price, byTicks ticks: Int, within range: ClosedRange<Price>) -> Price {
        var result = min(max(price, range.lowerBound), range.upperBound)
        for _ in 0..<ticks.magnitude {
            let next = ticks > 0 ? up(result) : down(result)
            guard next != result, range.contains(next) else { break }
            result = next
        }
        return result
    }

    /// `count` prices starting at `start`, each one tick on from the one before: strictly ascending or descending.
    static func ladder(from start: Price, ascending: Bool, count: Int) -> [Price] {
        var prices: [Price] = []
        var price = start
        for _ in 0..<max(count, 0) {
            prices.append(price)
            price = ascending ? up(price) : down(price)
        }
        return prices
    }
}

extension BookDepth {
    /// The number of levels the market keeps on each side.
    static let levelsPerSide = 5

    /// The size a level aims for: each level is 30% of the base bigger than the one before it, so the book gets deeper
    /// away from the best price.
    static func targetQuantity(base: Quantity, level: Int) -> Quantity {
        base * Quantity(10 + 3 * level) / 10
    }

    /// Rebuilds both sides as five levels each: bids from `bestBid` down, asks from `spreadTicks` ticks above it up
    /// (at least one, so the book is never crossed or locked), one tick between levels.
    ///
    /// A level whose price the book already had keeps its quantity; any other price gets a fresh level at 25% to 100%
    /// of its target. Then every level moves halfway to a noisy target of 50% to 150% of its own, so quantities settle
    /// around the target and keep flickering. A quantity that is not a positive whole lot (zero, negative, a part of a
    /// lot) is not carried: that level starts fresh. Every result is a positive multiple of the board lot.
    mutating func replenish(
        bestBid: Price, spreadTicks: Int, baseQuantity: Quantity, using generator: inout SeededGenerator
    ) {
        let bidPrices = PriceGrid.ladder(from: bestBid, ascending: false, count: Self.levelsPerSide)
        let bestAsk = PriceGrid.up(bestBid, ticks: max(spreadTicks, 1))
        let askPrices = PriceGrid.ladder(from: bestAsk, ascending: true, count: Self.levelsPerSide)
        bids = Self.refilled(bidPrices, from: bids, base: baseQuantity, using: &generator)
        asks = Self.refilled(askPrices, from: asks, base: baseQuantity, using: &generator)
    }

    /// Removes the levels that hold nothing (a quantity of zero or less).
    mutating func dropEmptyLevels() {
        bids.removeAll { $0.quantity <= 0 }
        asks.removeAll { $0.quantity <= 0 }
    }

    private static func refilled(
        _ prices: [Price], from existing: [BookLevel], base: Quantity, using generator: inout SeededGenerator
    ) -> [BookLevel] {
        let lot = TickRules.boardLot
        return prices.enumerated().map { level, price in
            let target = targetQuantity(base: base, level: level)
            let carried = existing.first { $0.price == price }.map { $0.quantity / lot * lot } ?? 0
            let start = carried >= lot ? carried : target * Quantity(25 + generator.below(76)) / 100
            let noisy = target * Quantity(50 + generator.below(101)) / 100
            return BookLevel(price: price, quantity: max(start + (noisy - start) / 2, lot) / lot * lot)
        }
    }
}

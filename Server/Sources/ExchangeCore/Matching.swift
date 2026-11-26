import TradeCore

/// One trade against the book: `quantity` shares at `price`, in satang per share. All of it is simulated.
public struct Fill: Sendable, Equatable {
    public let price: Price
    public let quantity: Quantity

    /// The fields as given; nothing is checked. The matching functions below only ever make fills of a positive
    /// quantity.
    public init(price: Price, quantity: Quantity) {
        self.price = price
        self.quantity = quantity
    }
}

/// What sweeping the book gave an incoming order.
public struct SweepResult: Sendable, Equatable {
    /// One fill per level touched, in the order the sweep reached them: best price first, so the last fill is the worst
    /// price the order reached. Each is for a positive quantity. Empty when nothing traded.
    public let fills: [Fill]
    /// The shares that found no trade: the quantity asked for (0 if that was not positive) less the fills, so never
    /// negative.
    public let remaining: Quantity

    public init(fills: [Fill], remaining: Quantity) {
        self.fills = fills
        self.remaining = remaining
    }
}

/// How an order meets the simulated book: three pure functions, with no state, no clock and no randomness.
///
/// `sweep` is a what-if. It reads a book and says what an incoming order would trade, and changes nothing;
/// `BookDepth.consume(side:fills:)` is what takes those shares out of the book afterwards. `restingFill` decides what
/// the current quote fills of a limit order that is resting elsewhere: a resting order is never part of a `BookDepth`,
/// which holds only the simulated market's own liquidity.
///
/// No operation traps or overflows for any input, the extremes of `Int64` included: prices are only compared, and
/// quantities are only compared and taken from a larger one.
public enum Matching: Sendable {
    /// What an incoming order of `quantity` shares trades against `depth`. A buy takes from the asks and a sell from
    /// the bids, never from its own side. `limit` is the worst price the order accepts; `nil` is a market order, which
    /// accepts any.
    ///
    /// The sweep walks that side in array order, which `BookDepth` keeps best price first (asks ascending, bids
    /// descending), and
    /// - stops at the first level whose price is beyond the limit (a buy: above it; a sell: below it), whether or not
    ///   the level holds shares, so a price equal to the limit trades. It trusts the order of the book: on a book that
    ///   is not sorted it does not look further down for a level that is inside the limit;
    /// - passes over a level that holds no shares (a quantity of 0 or less), which is no reason to stop;
    /// - takes `min(still wanted, level quantity)` from every other level as one `Fill` at that level's price: the
    ///   order trades at the prices it finds, never at its own limit;
    /// - stops as soon as the order is filled.
    ///
    /// `remaining` is `max(quantity, 0)` less the filled shares. A `quantity` of 0 or less trades nothing and leaves
    /// nothing: no fills and a `remaining` of 0. A limit of 0 or less is compared like any other price (a buy with one
    /// reaches no level and a sell reaches every level); the exchange engine rejects such orders before it matches.
    public static func sweep(side: Side, quantity: Quantity, limit: Price?, depth: BookDepth) -> SweepResult {
        guard quantity > 0 else { return SweepResult(fills: [], remaining: 0) }
        var wanted = quantity
        var fills: [Fill] = []
        let levels = side == .buy ? depth.asks : depth.bids
        for level in levels {
            if let limit, isBeyond(level.price, limit: limit, for: side) { break }
            guard level.quantity > 0 else { continue }
            let taken = min(wanted, level.quantity)
            fills.append(Fill(price: level.price, quantity: taken))
            wanted -= taken
            if wanted == 0 { break }
        }
        return SweepResult(fills: fills, remaining: wanted)
    }

    /// What the quote fills of a resting limit order now, or `nil` when it fills nothing.
    ///
    /// The order trades against the best level on the other side of the quote: a buy against the ask and `askQty`, a
    /// sell against the bid and `bidQty`. It fills once the quote has reached its limit (a buy: the ask is at or below
    /// the limit; a sell: the bid is at or above it; equal prices cross), at the order's own limit and not at the
    /// quote's better price, for the smaller of `remaining` and the shares that best level shows.
    ///
    /// It is `nil` when `remaining` is 0 or less (nothing is left to fill), when the limit is 0 or less (not a price
    /// an order can rest at), when the best level shows no shares (a side that a sweep emptied keeps its price with a
    /// quantity of 0 until the market's next step, and there is nothing to trade against), and when the quote has not
    /// reached the limit.
    public static func restingFill(side: Side, limit: Price, remaining: Quantity, quote: SymbolQuote) -> Fill? {
        guard remaining > 0, limit.satang > 0 else { return nil }
        let best = side == .buy ? quote.ask : quote.bid
        let shown = side == .buy ? quote.askQty : quote.bidQty
        guard shown > 0, !isBeyond(best, limit: limit, for: side) else { return nil }
        return Fill(price: limit, quantity: min(remaining, shown))
    }

    /// Whether `levelPrice` is beyond `limit` for an order on `side`: above it for a buy, which pays at most its limit,
    /// and below it for a sell, which gets at least its limit. Equal prices are not beyond.
    private static func isBeyond(_ levelPrice: Price, limit: Price, for side: Side) -> Bool {
        side == .buy ? levelPrice > limit : levelPrice < limit
    }
}

extension BookDepth {
    /// Takes the shares of `fills` out of the book. `side` is the aggressor's: a buy takes from the asks and a sell
    /// from the bids. The other side is not touched at all, not even to drop a level that holds nothing.
    ///
    /// Each fill comes off the first level of that side at exactly its price that still holds shares, so fills at one
    /// price add up (a book that lists one price twice is taken level by level, as a sweep walks it). A fill at a
    /// price the side does not have changes nothing, and neither does a fill of 0 shares or less. A level never goes
    /// below 0: a fill larger than its level takes the level whole and nothing from any other.
    ///
    /// Afterwards every level of that side that holds nothing is dropped, whether this call emptied it or it already
    /// held nothing (a quantity of 0 or less), even when `fills` is empty. The levels that stay keep their order.
    /// `dropEmptyLevels()` is not used because it cleans both sides.
    ///
    /// Nothing can overflow: each fill is applied alone, never summed with the others, and takes the smaller of its
    /// own quantity and what the level holds, both positive.
    public mutating func consume(side: Side, fills: [Fill]) {
        switch side {
        case .buy: asks = Self.taking(fills, from: asks)
        case .sell: bids = Self.taking(fills, from: bids)
        }
    }

    /// One side of the book after `fills` came off it: see `consume(side:fills:)` for the rules.
    private static func taking(_ fills: [Fill], from levels: [BookLevel]) -> [BookLevel] {
        var left = levels
        for fill in fills where fill.quantity > 0 {
            guard let index = left.firstIndex(where: { $0.price == fill.price && $0.quantity > 0 }) else { continue }
            left[index].quantity -= min(fill.quantity, left[index].quantity)
        }
        return left.filter { $0.quantity > 0 }
    }
}

import Testing
import TradeCore
@testable import ExchangeCore

private func price(_ satang: Int64) -> Price {
    Price(satang: satang)
}

private func level(_ satang: Int64, _ quantity: Quantity) -> BookLevel {
    BookLevel(price: price(satang), quantity: quantity)
}

/// What kind of case a random order was: its side, market or limit, whether any level could trade with it, and how much
/// of it traded.
private struct Kind: Hashable {
    enum Outcome: Hashable {
        case nothingTraded, partlyFilled, fullyFilled
    }

    let side: Side
    let isMarket: Bool
    /// Whether some level that holds shares is inside the order's limit, so the order could trade if it asked for any
    /// shares.
    let crossing: Bool
    let outcome: Outcome

    /// Every kind that can happen. An order that cannot cross trades nothing; one that can cross trades all, part or,
    /// when it asked for no shares, none of what it asked.
    static let all: [Kind] = {
        let possible: [(crossing: Bool, outcome: Outcome)] = [
            (true, .fullyFilled), (true, .partlyFilled), (true, .nothingTraded), (false, .nothingTraded),
        ]
        var kinds: [Kind] = []
        for side in [Side.buy, .sell] {
            for isMarket in [true, false] {
                for state in possible {
                    kinds.append(Kind(side: side, isMarket: isMarket, crossing: state.crossing, outcome: state.outcome))
                }
            }
        }
        return kinds
    }()
}

/// One order against one book, drawn at random.
///
/// The book has up to six levels a side, 25 to 75 satang apart, each holding 0 to 1,000 shares in lots of 100 (a level
/// of 0 is one that a sweep emptied; a side may have no level at all). One order in ten is for no shares or less; the
/// others are for 100 to 4,000. Four in ten are market orders; the others have a limit from six ticks short of the best
/// level they trade against to six ticks past it.
private struct RandomOrder {
    let side: Side
    let quantity: Quantity
    let limit: Price?
    let depth: BookDepth

    init(using generator: inout SeededGenerator) {
        let bestBid = Int64(3000 + 25 * generator.below(40))
        let bestAsk = bestBid + Int64(25 * (1 + generator.below(3)))
        let depth = BookDepth(
            bids: Self.levels(from: bestBid, step: -25, using: &generator),
            asks: Self.levels(from: bestAsk, step: 25, using: &generator)
        )
        let side: Side = generator.below(2) == 0 ? .buy : .sell
        let best = (side == .buy ? depth.asks : depth.bids).first?.price.satang ?? 3400
        let forNothing = generator.below(10) == 0
        let isMarket = generator.below(10) < 4
        self.depth = depth
        self.side = side
        quantity = forNothing ? Quantity(-50 * generator.below(3)) : Quantity(100 * (1 + generator.below(40)))
        limit = isMarket ? nil : price(best + Int64(25 * (generator.below(13) - 6)))
    }

    /// Up to six levels from `best`, each a step of one to three ticks further out than the one before (the step is
    /// negative for bids).
    private static func levels(from best: Int64, step: Int64, using generator: inout SeededGenerator) -> [BookLevel] {
        var built: [BookLevel] = []
        var satang = best
        for _ in 0..<generator.below(7) {
            built.append(level(satang, Quantity(100 * generator.below(11))))
            satang += step * Int64(1 + generator.below(3))
        }
        return built
    }

    /// The side of the book this order trades against.
    private var book: [BookLevel] {
        side == .buy ? depth.asks : depth.bids
    }

    /// Whether `candidate` is a price the order accepts: any price for a market order, otherwise at or below the limit
    /// for a buy and at or above it for a sell.
    private func isInside(_ candidate: Price) -> Bool {
        guard let limit else { return true }
        return side == .buy ? candidate <= limit : candidate >= limit
    }

    /// The shares that `book` holds at `atPrice`; 0 where it has no level.
    private func held(at atPrice: Price) -> Quantity {
        book.first { $0.price == atPrice }?.quantity ?? 0
    }

    private func total(_ quantities: [Quantity]) -> Quantity {
        quantities.reduce(0, +)
    }

    /// Sweeps the order, consumes the fills, and returns the kind of case with whatever is wrong with what came back
    /// (an empty list when every rule holds).
    func play() -> (kind: Kind, problems: [String]) {
        var found: [String] = []
        func check(_ holds: Bool, _ what: @autoclosure () -> String) {
            if !holds {
                found.append("\(what()): \(side) \(quantity) limit \(String(describing: limit)) in \(depth)")
            }
        }

        let result = Matching.sweep(side: side, quantity: quantity, limit: limit, depth: depth)
        let wanted = max(quantity, 0)
        let filled = total(result.fills.map(\.quantity))
        let tradable = book.filter { $0.quantity > 0 && isInside($0.price) }
        let prices = result.fills.map(\.price)
        let monotone = zip(prices, prices.dropFirst()).allSatisfy { side == .buy ? $0 < $1 : $0 > $1 }

        check(result.remaining >= 0 && result.fills.allSatisfy { $0.quantity > 0 }, "an empty fill or a negative rest")
        check(filled + result.remaining == wanted, "filled \(filled) and remaining \(result.remaining), not \(wanted)")
        check(filled == min(wanted, total(tradable.map(\.quantity))), "filled \(filled) is not all the limit allows")
        check(monotone, "fill prices \(prices) are not strictly monotone")
        check(prices.allSatisfy(isInside), "fill prices \(prices) are outside the limit")
        for taken in result.fills {
            check(taken.quantity <= held(at: taken.price), "\(taken) is larger than its level")
        }

        var after = depth
        after.consume(side: side, fills: result.fills)
        let left = side == .buy ? after.asks : after.bids
        let otherBefore = side == .buy ? depth.bids : depth.asks
        let otherAfter = side == .buy ? after.bids : after.asks
        let emptied = Set(result.fills.filter { $0.quantity == held(at: $0.price) }.map(\.price))
        let kept = book.filter { $0.quantity > 0 && !emptied.contains($0.price) }.map(\.price)

        check(total(book.map(\.quantity)) - total(left.map(\.quantity)) == filled, "consume did not take \(filled)")
        check(left.allSatisfy { $0.quantity > 0 }, "a level with no shares is left")
        check(left.map(\.price) == kept, "the levels left are \(left.map(\.price)), not \(kept)")
        check(otherAfter == otherBefore, "the other side changed")

        let outcome: Kind.Outcome = result.fills.isEmpty
            ? .nothingTraded : (result.remaining == 0 ? .fullyFilled : .partlyFilled)
        return (Kind(side: side, isMarket: limit == nil, crossing: !tradable.isEmpty, outcome: outcome), found)
    }
}

extension MatchingTests {
    struct RandomOrders {
        /// 4,000 seeded orders against seeded books, each swept and then consumed. For every one: the filled total and
        /// the remainder add up to the shares asked for (none when that is not positive); the filled total is as much
        /// of the order as the book holds inside the limit; fill prices are strictly monotone (ascending for a buy,
        /// descending for a sell) and inside the limit; no fill is larger than its level; and consuming the fills takes
        /// exactly the filled total off that side of the book, leaves no level without shares, keeps the order of the
        /// levels, drops the ones taken whole, and leaves the other side as it was.
        ///
        /// The run counts its cases by kind (side, market or limit, crossing or not, and how much of the order traded)
        /// and every kind must have happened, so it cannot pass by never reaching a case.
        @Test func randomOrdersObeyTheMatchingRules() {
            var generator = SeededGenerator(seed: 11)
            var counts: [Kind: Int] = [:]
            var problems: [String] = []
            let cases = 4000

            for _ in 0..<cases {
                let played = RandomOrder(using: &generator).play()
                counts[played.kind, default: 0] += 1
                problems += played.problems
            }

            #expect(problems.isEmpty, "\(problems.prefix(3))")
            #expect(counts.values.reduce(0, +) == cases, "each case is counted once")
            #expect(Kind.all.count == 16)
            for kind in Kind.all {
                #expect(counts[kind, default: 0] > 0, "\(kind) never happened: \(counts)")
            }
        }
    }
}

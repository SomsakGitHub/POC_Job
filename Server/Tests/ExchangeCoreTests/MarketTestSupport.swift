import TradeCore
@testable import ExchangeCore

/// 2023-11-14 22:15:23.456 UTC. It is not on a bucket edge for any interval, so at the start the current candle of
/// every interval is a partly finished one.
let marketStartMs: Int64 = 1_700_000_123_456

let catalogSymbols = SymbolCatalog.defaultSymbols

/// PTT, the symbol the app opens by name with `--open-symbol PTT`. (The catalog tests pin that it is there, and first.)
let ptt = catalogSymbols.first { $0.ticker == "PTT" } ?? catalogSymbols[0]

/// The default market (the twelve catalog symbols, seed 42), built once and shared. A market is a value type, so a test
/// copies it (`var market = defaultMarket`) and works on its own copy. Building one synthesises about 36,000 candles,
/// which is why the tests do not rebuild it each time.
let defaultMarket = SimulatedMarket(symbols: catalogSymbols, seed: 42, startMs: marketStartMs)

/// A symbol for tests that need a price of their own. The names are Thai and English placeholders.
func makeSymbol(_ id: UInt32, reference satang: Int64) -> SymbolInfo {
    SymbolInfo(id: id, ticker: "T\(id)", nameTh: "ทดสอบ", nameEn: "Test \(id)", reference: Price(satang: satang))
}

/// The market's current quote for each of `symbols`, in that order.
func quotes(of market: SimulatedMarket, for symbols: [SymbolInfo] = catalogSymbols) -> [SymbolQuote] {
    symbols.compactMap { market.quote($0.id) }
}

func candle(_ interval: CandleInterval, of quote: SymbolQuote) -> Candle {
    switch interval {
    case .s1: quote.candle1s
    case .m1: quote.candle1m
    case .m5: quote.candle5m
    }
}

func widthMs(_ interval: CandleInterval) -> Int64 {
    Int64(interval.seconds) * 1000
}

/// Every rule a quote and its book must satisfy once the market has produced them, as a list of what is wrong (empty if
/// all is well). Returning text instead of calling `#expect` for each check keeps a 100,000-step run to one assertion.
///
/// The rules: `last`, `bid` and `ask` are on tick and inside the price band; `bid < ask` and at most three ticks
/// apart, with `last` between them; the book has five strictly monotone, on-tick, in-band levels a side holding
/// positive whole lots; the quote is the best level of the book; each current candle is well formed and closes at
/// `last`; the day volume is a positive whole number of lots.
func problems(_ quote: SymbolQuote, _ depth: BookDepth, _ info: SymbolInfo) -> [String] {
    var found: [String] = []
    let band = TickRules.band(reference: info.reference)
    func check(_ holds: Bool, _ what: @autoclosure () -> String) {
        if !holds {
            found.append("\(info.ticker): \(what())")
        }
    }

    let prices = [quote.last, quote.bid, quote.ask]
    check(prices.allSatisfy { TickRules.isOnTick($0) }, "off tick: \(prices)")
    check(prices.allSatisfy { band.contains($0) }, "outside the band \(band): \(prices)")
    check(quote.bid < quote.ask, "bid \(quote.bid) is not below ask \(quote.ask)")
    check(quote.bid <= quote.last && quote.last <= quote.ask, "last \(quote.last) is outside bid and ask")
    check(PriceGrid.up(quote.bid, ticks: 3) >= quote.ask, "spread over 3 ticks: \(quote.bid) / \(quote.ask)")

    check(depth.bids.count == 5 && depth.asks.count == 5, "\(depth.bids.count) bid and \(depth.asks.count) ask levels")
    let bidsDescend = zip(depth.bids, depth.bids.dropFirst()).allSatisfy { $0.price > $1.price }
    let asksAscend = zip(depth.asks, depth.asks.dropFirst()).allSatisfy { $0.price < $1.price }
    check(bidsDescend, "bids are not strictly descending")
    check(asksAscend, "asks are not strictly ascending")
    for level in depth.bids + depth.asks {
        check(TickRules.isOnTick(level.price) && band.contains(level.price), "level price \(level.price)")
        check(level.quantity > 0 && level.quantity % TickRules.boardLot == 0, "level quantity \(level.quantity)")
    }
    let bestBid = depth.bids.first
    let bestAsk = depth.asks.first
    check(bestBid?.price == quote.bid && bestBid?.quantity == quote.bidQty, "bid is not the best bid level")
    check(bestAsk?.price == quote.ask && bestAsk?.quantity == quote.askQty, "ask is not the best ask level")

    for interval in CandleInterval.allCases {
        let current = candle(interval, of: quote)
        let label = interval.label
        check(
            current.low <= current.open && current.low <= current.close
                && current.open <= current.high && current.close <= current.high,
            "\(label) candle is malformed: \(current)"
        )
        check(current.close == quote.last, "\(label) candle closes at \(current.close), last is \(quote.last)")
        check(current.volume > 0 && current.volume % TickRules.boardLot == 0, "\(label) volume \(current.volume)")
        let onBucket = current.openTimeMs == interval.bucketStartMs(forMs: current.openTimeMs)
        check(onBucket, "\(label) candle is off its bucket")
    }
    check(quote.dayVolume > 0 && quote.dayVolume % TickRules.boardLot == 0, "day volume \(quote.dayVolume)")
    return found
}

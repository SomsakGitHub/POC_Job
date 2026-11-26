import TradeCore

/// What the market feed last said about one symbol: the last trade, the top of the book, the day's volume and the
/// three candles still open, plus the bookkeeping a reader needs to know how far to trust it.
///
/// A plain value. `MarketState.snapshot(_:)` hands out a copy, so a reader holds a consistent picture (every field is
/// from the same update) however the feed moves on meanwhile.
public struct SymbolSnapshot: Sendable, Equatable {
    /// The symbol this is about: the id the order API and the market feed use.
    public let symbolId: UInt32
    /// The sequence number of the update this snapshot comes from. The server numbers the updates of a symbol per
    /// connection, from 1, so this says how far the current connection has got, not how many updates there ever were.
    public let seq: UInt64
    /// The price of the last trade, in satang.
    public let last: Price
    /// The best bid, in satang. When nobody bids, the server keeps sending the last bid price and `bidQty` is 0.
    public let bid: Price
    /// The best ask, in satang. When nobody asks, the server keeps sending the last ask price and `askQty` is 0.
    public let ask: Price
    /// The shares wanted at the best bid; 0 when nobody bids.
    public let bidQty: Quantity
    /// The shares offered at the best ask; 0 when nobody asks.
    public let askQty: Quantity
    /// The shares traded so far today.
    public let dayVolume: Int64
    /// The one-second candle in progress; all zeros until the feed has sent one.
    public let candle1s: Candle
    /// The one-minute candle in progress; all zeros until the feed has sent one.
    public let candle1m: Candle
    /// The five-minute candle in progress; all zeros until the feed has sent one.
    public let candle5m: Candle
    /// When the frame this snapshot comes from was received, in wall-clock nanoseconds: how old the numbers are.
    public let appliedAtNs: Int64
    /// How many times the sequence jumped on the current connection: each one is a stretch of updates this client never
    /// saw. It starts again from 0 with every connection.
    public let gapCount: Int

    /// The fields in declared order. The market state is what makes snapshots; this exists for code that needs to
    /// build one by hand, such as a test or a preview.
    public init(
        symbolId: UInt32, seq: UInt64, last: Price, bid: Price, ask: Price, bidQty: Quantity, askQty: Quantity,
        dayVolume: Int64, candle1s: Candle, candle1m: Candle, candle5m: Candle, appliedAtNs: Int64, gapCount: Int
    ) {
        self.symbolId = symbolId
        self.seq = seq
        self.last = last
        self.bid = bid
        self.ask = ask
        self.bidQty = bidQty
        self.askQty = askQty
        self.dayVolume = dayVolume
        self.candle1s = candle1s
        self.candle1m = candle1m
        self.candle5m = candle5m
        self.appliedAtNs = appliedAtNs
        self.gapCount = gapCount
    }
}

extension SymbolSnapshot {
    /// This snapshot with another gap count: the one thing that changes without a new update, when a connection begins.
    func withGapCount(_ gapCount: Int) -> SymbolSnapshot {
        SymbolSnapshot(
            symbolId: symbolId, seq: seq, last: last, bid: bid, ask: ask, bidQty: bidQty, askQty: askQty,
            dayVolume: dayVolume, candle1s: candle1s, candle1m: candle1m, candle5m: candle5m,
            appliedAtNs: appliedAtNs, gapCount: gapCount
        )
    }
}

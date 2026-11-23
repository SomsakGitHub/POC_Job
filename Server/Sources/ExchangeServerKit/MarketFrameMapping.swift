import Contracts
import ExchangeCore
import TradeCore

/// How the market feed puts a quote on the wire.
///
/// Every update carries the symbol's whole state, never a delta, so a client that missed updates is whole again with
/// the next one it receives. The generated message types are filled field by field.
enum MarketFrameMapping {
    /// `quote` as a wire update numbered `seq`. `eventNs` is the quote's own (the simulated time of the symbol's last
    /// tick) and is informational: it is not when the frame was sent.
    static func update(_ quote: SymbolQuote, seq: UInt64) -> Tp_SymbolUpdate {
        var update = Tp_SymbolUpdate()
        update.symbolID = quote.symbolId
        update.seq = seq
        update.last = quote.last.satang
        update.bid = quote.bid.satang
        update.ask = quote.ask.satang
        update.bidQty = quote.bidQty
        update.askQty = quote.askQty
        update.dayVolume = quote.dayVolume
        update.candle1S = candle(quote.candle1s)
        update.candle1M = candle(quote.candle1m)
        update.candle5M = candle(quote.candle5m)
        update.eventNs = quote.eventNs
        return update
    }

    /// `candle` as a wire candle: its open time in milliseconds since the Unix epoch, prices in satang, volume in
    /// shares.
    static func candle(_ candle: Candle) -> Tp_Candle {
        var wire = Tp_Candle()
        wire.openTimeMs = candle.openTimeMs
        wire.open = candle.open.satang
        wire.high = candle.high.satang
        wire.low = candle.low.satang
        wire.close = candle.close.satang
        wire.volume = candle.volume
        return wire
    }
}

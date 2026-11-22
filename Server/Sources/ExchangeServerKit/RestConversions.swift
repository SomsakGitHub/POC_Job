import Contracts
import ExchangeCore
import TradeCore

// The engine's types as the REST models of `Contracts`. The models know nothing of the engine, so the conversions
// live here, next to the routes that use them.

extension SymbolDTO {
    /// `info` as the symbol list shows it; the lot is the board lot the engine's order checks use.
    init(_ info: SymbolInfo) {
        self.init(
            id: info.id, ticker: info.ticker, nameTh: info.nameTh, nameEn: info.nameEn,
            reference: info.reference.satang, lot: TickRules.boardLot
        )
    }
}

extension AccountDTO {
    /// `snapshot` with its positions in ascending symbol order; the ledger lists no symbol it holds no shares of.
    init(_ snapshot: AccountSnapshot) {
        self.init(
            epoch: snapshot.epoch, cash: snapshot.cash,
            positions: snapshot.positions.sorted { $0.key < $1.key }.map {
                PositionDTO(symbolId: $0.key, quantity: $0.value)
            },
            lastEventSeq: snapshot.lastEventSeq, lastLedgerSeq: snapshot.lastLedgerSeq
        )
    }
}

extension TransactionDTO {
    /// `entry` with its side named "buy" or "sell"; every amount stays in satang.
    init(_ entry: LedgerEntry) {
        let side: String
        switch entry.side {
        case .buy: side = "buy"
        case .sell: side = "sell"
        }
        self.init(
            ledgerSeq: entry.ledgerSeq, orderId: entry.orderId, symbolId: entry.symbolId, side: side,
            quantity: entry.quantity, price: entry.price.satang, commission: entry.commission,
            cashDelta: entry.cashDelta, tsNs: entry.tsNs
        )
    }
}

extension CandleDTO {
    /// `candle` with its open time in milliseconds and its prices in satang.
    init(_ candle: Candle) {
        self.init(
            t: candle.openTimeMs, o: candle.open.satang, h: candle.high.satang, l: candle.low.satang,
            c: candle.close.satang, v: candle.volume
        )
    }
}

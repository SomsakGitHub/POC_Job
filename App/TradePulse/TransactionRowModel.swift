import Foundation
import TradeCore
import TradeNetworking

/// What one transaction on screen says, worked out from a ledger row.
struct TransactionRowModel: Identifiable, Equatable {
    /// The ledger sequence number.
    let id: UInt64
    /// The time of the fill on a 24-hour clock with seconds: "14:03:22".
    let timeText: String
    /// "Buy" or "Sell".
    let sideText: String
    /// The shares in the fill, written with groups.
    let sharesText: String
    /// The ticker of the symbol.
    let ticker: String
    /// The price of one share in baht.
    let priceText: String
    /// The commission as money.
    let commissionText: String
    /// What the fill did to cash as money, with a plus sign for money that came in.
    let cashChangeText: String
    /// The whole row as one sentence for VoiceOver.
    let accessibilityText: String

    /// The row of `row` for the symbol `ticker`, with the time as it reads in `timeZone`.
    init(row: LedgerRow, ticker: String, timeZone: TimeZone = .current) {
        id = row.id
        timeText = Self.clockTime(ofNanoseconds: row.tsNs, in: timeZone)
        sideText = row.side == .buy ? "Buy" : "Sell"
        sharesText = ShareFormat.grouped(row.quantity)
        self.ticker = ticker
        priceText = row.price.description
        commissionText = MoneyFormat.baht(satang: row.commission)
        cashChangeText = (row.cashDelta > 0 ? "+" : "") + MoneyFormat.baht(satang: row.cashDelta)
        accessibilityText = "\(timeText), \(sideText) \(sharesText) shares of \(ticker) at \(priceText) baht, "
            + "commission \(commissionText), cash change \(cashChangeText)"
    }

    /// "HH:mm:ss" for `nanoseconds` since the Unix epoch as the clock of `timeZone` shows it. The second is the whole
    /// second the time falls in (a time before the epoch is rounded down, never towards zero), and the digits are
    /// ASCII whatever the locale. It is worked out in integers, so every `Int64` has a time and nothing traps.
    private static func clockTime(ofNanoseconds nanoseconds: Int64, in timeZone: TimeZone) -> String {
        var seconds = nanoseconds / 1_000_000_000
        if nanoseconds % 1_000_000_000 < 0 {
            seconds -= 1
        }
        let offset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(seconds)))
        let local = seconds + Int64(offset)
        let secondOfDay = ((local % 86_400) + 86_400) % 86_400
        return twoDigits(secondOfDay / 3_600) + ":" + twoDigits(secondOfDay % 3_600 / 60) + ":"
            + twoDigits(secondOfDay % 60)
    }

    /// `number`, which is 0 to 59, with a zero in front when it has one digit.
    private static func twoDigits(_ number: Int64) -> String {
        (number < 10 ? "0" : "") + String(number)
    }
}

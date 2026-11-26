import Foundation
import Testing
import TradeNetworking
@testable import TradePulse

/// What one line of the transactions list says: the time on a 24-hour clock in the zone given, the side, the shares,
/// the price, the commission and the change in cash with its sign.
@Suite(.timeLimit(.minutes(1)))
struct TransactionRowModelTests {
    /// 14:03:22 UTC, in nanoseconds since the Unix epoch.
    private let afternoon: Int64 = 1_795_615_402_000_000_000
    /// 00:05:09 UTC on the same day.
    private let justAfterMidnight: Int64 = 1_795_565_109_000_000_000
    /// 23:59:59 UTC on the day before.
    private let justBeforeMidnight: Int64 = 1_795_564_799_000_000_000

    /// A time zone `hours` hours from UTC.
    private func zone(hours: Int) throws -> TimeZone {
        try #require(TimeZone(secondsFromGMT: hours * 3_600))
    }

    /// The time text of a fill at `tsNs` as it reads in `timeZone`.
    private func time(_ tsNs: Int64, in timeZone: TimeZone) -> String {
        TransactionRowModel(row: ledgerRow(1, tsNs: tsNs), ticker: "PTT", timeZone: timeZone).timeText
    }

    @Test func theTimeIsOnA24HourClockInTheZoneGiven() throws {
        let utc = try zone(hours: 0)
        let bangkok = try zone(hours: 7)
        let newYork = try zone(hours: -5)
        let table: [(tsNs: Int64, zone: TimeZone, text: String)] = [
            (afternoon, utc, "14:03:22"), (afternoon, bangkok, "21:03:22"), (afternoon, newYork, "09:03:22"),
            (justAfterMidnight, utc, "00:05:09"), (justAfterMidnight, bangkok, "07:05:09"),
            (justAfterMidnight, newYork, "19:05:09"), (justBeforeMidnight, utc, "23:59:59"),
            (justBeforeMidnight, bangkok, "06:59:59"), (justBeforeMidnight, newYork, "18:59:59"),
        ]
        #expect(table.count == 9)
        for entry in table {
            #expect(time(entry.tsNs, in: entry.zone) == entry.text, "\(entry.tsNs) in \(entry.zone.identifier)")
        }
    }

    @Test func aFillIsShownAtTheSecondItHappenedIn() throws {
        let utc = try zone(hours: 0)

        #expect(time(afternoon + 999_999_999, in: utc) == "14:03:22", "a second is never rounded up")
        #expect(time(afternoon + 1_000_000_000, in: utc) == "14:03:23")
        #expect(time(0, in: utc) == "00:00:00")
        #expect(time(-1, in: utc) == "23:59:59", "a time before the epoch counts down from midnight")
        #expect(time(-1_000_000_000, in: utc) == "23:59:59")
        #expect(time(-1_000_000_001, in: utc) == "23:59:58")
    }

    @Test func theLargestAndSmallestTimesDoNotTrapAndStillReadAsAClockTime() throws {
        let utc = try zone(hours: 0)

        #expect(time(Int64.max, in: utc) == "23:47:16")
        #expect(time(Int64.min, in: utc) == "00:12:43", "the smallest time reads as the whole second it falls in")
    }

    @Test func theLineSaysSideSharesTickerPriceCommissionAndCash() throws {
        let row = ledgerRow(
            12, symbol: 4, side: .buy, quantity: 100, price: 3_425, commission: 51, cashDelta: -342_551,
            tsNs: afternoon
        )

        let model = TransactionRowModel(row: row, ticker: "PTT", timeZone: try zone(hours: 0))

        #expect(model.id == 12)
        #expect(model.timeText == "14:03:22")
        #expect(model.sideText == "Buy")
        #expect(model.sharesText == "100")
        #expect(model.ticker == "PTT")
        #expect(model.priceText == "34.25")
        #expect(model.commissionText == "฿0.51")
        #expect(model.cashChangeText == "-฿3,425.51")
    }

    @Test func aSaleShowsMoneyThatCameInWithAPlusSign() throws {
        let row = ledgerRow(
            13, symbol: 2, side: .sell, quantity: 10_000_000, price: 5_800, commission: 87, cashDelta: 1_739_913,
            tsNs: afternoon
        )

        let model = TransactionRowModel(row: row, ticker: "AOT", timeZone: try zone(hours: 0))

        #expect(model.sideText == "Sell")
        #expect(model.sharesText == "10,000,000")
        #expect(model.priceText == "58.00")
        #expect(model.cashChangeText == "+฿17,399.13")
    }

    @Test func theSignOfTheCashChangeIsTheSignOfTheMoney() throws {
        let utc = try zone(hours: 0)
        let table: [(cashDelta: Int64, text: String)] = [
            (-342_551, "-฿3,425.51"), (-1, "-฿0.01"), (0, "฿0.00"), (1, "+฿0.01"), (342_551, "+฿3,425.51"),
            (Int64.max, "+฿92,233,720,368,547,758.07"), (Int64.min, "-฿92,233,720,368,547,758.08"),
        ]
        #expect(table.count == 7)
        for entry in table {
            let row = ledgerRow(1, cashDelta: entry.cashDelta)

            let model = TransactionRowModel(row: row, ticker: "PTT", timeZone: utc)

            #expect(model.cashChangeText == entry.text, "\(entry.cashDelta)")
        }
    }

    @Test func theSpokenLineSaysEverythingTheLineDoes() throws {
        let row = ledgerRow(
            12, side: .buy, quantity: 1_000, price: 3_425, commission: 51, cashDelta: -3_425_051, tsNs: afternoon
        )

        let model = TransactionRowModel(row: row, ticker: "PTT", timeZone: try zone(hours: 0))

        #expect(
            model.accessibilityText
                == "14:03:22, Buy 1,000 shares of PTT at 34.25 baht, commission ฿0.51, cash change -฿34,250.51"
        )
    }

    @Test func aTickerTheCallerDoesNotKnowShowsAsGiven() throws {
        let model = TransactionRowModel(row: ledgerRow(1, symbol: 12), ticker: "#12", timeZone: try zone(hours: 0))

        #expect(model.ticker == "#12")
        #expect(model.accessibilityText.contains("#12"))
    }

    @Test func twoLinesOfTheSameFillAreEqual() throws {
        let utc = try zone(hours: 0)
        let one = TransactionRowModel(row: ledgerRow(1), ticker: "PTT", timeZone: utc)
        let same = TransactionRowModel(row: ledgerRow(1), ticker: "PTT", timeZone: utc)
        let other = TransactionRowModel(row: ledgerRow(2), ticker: "PTT", timeZone: utc)

        #expect(one == same)
        #expect(one != other)
    }
}

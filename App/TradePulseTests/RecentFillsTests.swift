import Testing
import TradeNetworking
@testable import TradePulse

/// Which fills the "Recent fills" area of a symbol's screen shows: the newest five of that symbol.
@Suite(.timeLimit(.minutes(1)))
struct RecentFillsTests {
    /// The ids of the rows, in the order they are in.
    private func ids(_ rows: [LedgerRow]) -> [UInt64] {
        rows.map(\.id)
    }

    @Test func theFiveNewestFillsOfTheSymbolAreShownNewestFirst() {
        let ledger = (1...7).reversed().map { ledgerRow(UInt64($0)) }

        let latest = RecentFills.latest(in: ledger, symbolId: 4)

        #expect(ids(latest) == [7, 6, 5, 4, 3])
    }

    @Test func theOrderIsTheLedgerSequenceWhateverOrderTheLedgerIsIn() {
        let oldestFirst = [1, 2, 3, 4, 5, 6, 7].map { ledgerRow(UInt64($0)) }
        let shuffled = [3, 7, 1, 5, 2, 6, 4].map { ledgerRow(UInt64($0)) }

        #expect(ids(RecentFills.latest(in: oldestFirst, symbolId: 4)) == [7, 6, 5, 4, 3])
        #expect(ids(RecentFills.latest(in: shuffled, symbolId: 4)) == [7, 6, 5, 4, 3])
    }

    @Test func theDefaultLimitIsFive() {
        let ledger = (1...20).map { ledgerRow(UInt64($0)) }

        #expect(RecentFills.defaultLimit == 5)
        #expect(RecentFills.latest(in: ledger, symbolId: 4).count == 5)
    }

    @Test func aLimitGivesAtMostThatManyAndZeroOrLessGiveNone() {
        let ledger = (1...10).map { ledgerRow(UInt64($0)) }

        #expect(ids(RecentFills.latest(in: ledger, symbolId: 4, limit: 3)) == [10, 9, 8])
        #expect(ids(RecentFills.latest(in: ledger, symbolId: 4, limit: 1)) == [10])
        #expect(RecentFills.latest(in: ledger, symbolId: 4, limit: 10).count == 10)
        #expect(RecentFills.latest(in: ledger, symbolId: 4, limit: 100).count == 10)
        #expect(RecentFills.latest(in: ledger, symbolId: 4, limit: 0).isEmpty)
        #expect(RecentFills.latest(in: ledger, symbolId: 4, limit: -3).isEmpty)
    }

    @Test func fewerThanFiveFillsAreAllShown() {
        let ledger = [ledgerRow(2), ledgerRow(1), ledgerRow(3)]

        #expect(ids(RecentFills.latest(in: ledger, symbolId: 4)) == [3, 2, 1])
    }

    @Test func aLedgerWithNoFillsGivesNone() {
        #expect(RecentFills.latest(in: [], symbolId: 4).isEmpty)
    }

    @Test func fillsOfOtherSymbolsAreLeftOut() {
        let ledger = [
            ledgerRow(9, symbol: 2), ledgerRow(8, symbol: 4), ledgerRow(7, symbol: 2), ledgerRow(6, symbol: 4),
            ledgerRow(5, symbol: 9), ledgerRow(4, symbol: 4), ledgerRow(3, symbol: 2), ledgerRow(2, symbol: 4),
            ledgerRow(1, symbol: 4),
        ]

        #expect(ids(RecentFills.latest(in: ledger, symbolId: 4)) == [8, 6, 4, 2, 1])
        #expect(ids(RecentFills.latest(in: ledger, symbolId: 2)) == [9, 7, 3])
        #expect(ids(RecentFills.latest(in: ledger, symbolId: 9)) == [5])
        #expect(RecentFills.latest(in: ledger, symbolId: 12).isEmpty)
    }

    @Test func theLimitCountsOnlyTheFillsOfTheSymbol() {
        let others = (100...120).map { ledgerRow(UInt64($0), symbol: 2) }
        let ours = (1...6).map { ledgerRow(UInt64($0), symbol: 4) }

        let latest = RecentFills.latest(in: others + ours, symbolId: 4)

        #expect(ids(latest) == [6, 5, 4, 3, 2])
    }

    @Test func theRowsComeBackUnchanged() {
        let row = ledgerRow(
            5, symbol: 4, side: .sell, quantity: 300, price: 3_500, commission: 77, cashDelta: 1_049_923
        )

        #expect(RecentFills.latest(in: [row], symbolId: 4) == [row])
    }
}

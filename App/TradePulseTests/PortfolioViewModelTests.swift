import Contracts
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// What the Portfolio screen says of the account: the cash, the positions and the equity.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PortfolioViewModelTests {
    /// A trading state that holds `cash` satang and the shares `held` (symbol id to shares).
    private func tradingState(cash: Int64, held: [UInt32: Int64] = [:]) -> TradingState {
        var state = TradingState()
        state.cash = cash
        state.positions = held
        return state
    }

    /// The portfolio of `state` priced with the last prices `lasts` (symbol id to satang), over `symbols`.
    private func priced(
        _ state: TradingState, lasts: [UInt32: Int64] = [:], symbols: [SymbolDTO] = sampleSymbols
    ) -> PortfolioViewModel {
        PortfolioViewModel(
            state: state, snapshots: { id in lasts[id].map { snapshot(symbol: id, last: $0) } }, symbols: symbols
        )
    }

    @Test func equityIsCashPlusMarketValue() {
        let portfolio = priced(tradingState(cash: 90_000_000, held: [4: 100]), lasts: [4: 3_450])

        #expect(portfolio.equityText == "฿903,450.00")
        #expect(portfolio.cashText == "฿900,000.00")
        #expect(portfolio.unpricedCount == 0)
        #expect(portfolio.waitingText == nil)
        let expected = PositionRow(id: 4, ticker: "PTT", quantity: 100, last: satang(3_450), marketValueSatang: 345_000)
        #expect(portfolio.rows == [expected])
    }

    @Test func emptyPositionsShowsCashOnly() {
        let portfolio = priced(tradingState(cash: 90_000_000))

        #expect(portfolio.rows.isEmpty)
        #expect(portfolio.cashText == "฿900,000.00")
        #expect(portfolio.equityText == "฿900,000.00")
        #expect(portfolio.unpricedCount == 0)
        #expect(portfolio.waitingText == nil)
    }

    @Test func theValueOfARowIsItsSharesTimesTheLastPrice() {
        let portfolio = priced(tradingState(cash: 0, held: [4: 250, 2: 1_000]), lasts: [4: 3_425, 2: 5_800])

        #expect(portfolio.rows.map(\.ticker) == ["AOT", "PTT"])
        #expect(portfolio.rows.map(\.marketValueSatang) == [5_800_000, 856_250])
        #expect(portfolio.equityText == "฿66,562.50")
    }

    @Test func aPositionWithoutAPriceMakesTheEquityUnknownAndIsCounted() {
        let state = tradingState(cash: 90_000_000, held: [4: 100, 2: 200])
        let waiting = priced(state, lasts: [4: 3_450])

        #expect(waiting.equityText == "—")
        #expect(waiting.unpricedCount == 1)
        #expect(waiting.waitingText == "Waiting for the price of 1 position")
        #expect(waiting.cashText == "฿900,000.00", "the cash is known whatever the prices are")
        let aot = waiting.rows.first { $0.ticker == "AOT" }
        #expect(aot?.last == nil)
        #expect(aot?.marketValueSatang == nil)
        let ptt = waiting.rows.first { $0.ticker == "PTT" }
        #expect(ptt?.marketValueSatang == 345_000, "a position that has a price still shows its value")

        let none = priced(state)
        #expect(none.unpricedCount == 2)
        #expect(none.waitingText == "Waiting for prices of 2 positions")
        #expect(none.equityText == "—")

        let complete = priced(state, lasts: [4: 3_450, 2: 5_800])
        #expect(complete.unpricedCount == 0)
        #expect(complete.waitingText == nil)
        #expect(complete.equityText == "฿915,050.00")
    }

    @Test func aLastPriceThatIsNotAboveZeroCountsAsNoPrice() {
        let prices: [Int64] = [0, -1, Int64.min]
        #expect(prices.count == 3)
        for last in prices {
            let portfolio = priced(tradingState(cash: 100, held: [4: 100]), lasts: [4: last])

            #expect(portfolio.rows.first?.last == nil, "\(last)")
            #expect(portfolio.rows.first?.marketValueSatang == nil, "\(last)")
            #expect(portfolio.unpricedCount == 1, "\(last)")
            #expect(portfolio.equityText == "—", "\(last)")
        }

        let control = priced(tradingState(cash: 100, held: [4: 100]), lasts: [4: 1])
        #expect(control.unpricedCount == 0)
        #expect(control.equityText == "฿2.00")
    }

    @Test func rowsAreOrderedByTickerWhateverTheIdsAndTheSymbolListSay() {
        // The sample list is PTT (4), AOT (2), CPALL (9): neither its order nor the order of the ids is the order of
        // the tickers.
        let state = tradingState(cash: 0, held: [4: 100, 2: 100, 9: 100])
        let portfolio = priced(state, lasts: [4: 3_425, 2: 5_800, 9: 5_000])

        #expect(portfolio.rows.map(\.ticker) == ["AOT", "CPALL", "PTT"])
        #expect(portfolio.rows.map(\.id) == [2, 9, 4])
    }

    @Test func aSymbolTheListDoesNotHaveShowsItsId() {
        let state = tradingState(cash: 0, held: [12: 100, 2: 100, 4: 100])
        let portfolio = priced(state, lasts: [12: 1_000, 2: 5_800, 4: 3_425])

        // By plain string order, in which "#" comes before the letters.
        #expect(portfolio.rows.map(\.ticker) == ["#12", "AOT", "PTT"])
        #expect(portfolio.rows.first?.marketValueSatang == 100_000, "it is priced like any other")
        let noList = priced(tradingState(cash: 0, held: [12: 100]), symbols: [])
        #expect(noList.rows.map(\.ticker) == ["#12"])
    }

    @Test func positionsOfNoSharesAreLeftOut() {
        let state = tradingState(cash: 0, held: [4: 0, 2: -5, 9: 100])
        let portfolio = priced(state, lasts: [4: 3_425, 2: 5_800, 9: 5_000])

        #expect(portfolio.rows.map(\.ticker) == ["CPALL"])
        #expect(portfolio.unpricedCount == 0)
        #expect(portfolio.equityText == "฿5,000.00")
    }

    @Test func negativeCashKeepsItsSignAndTakesPartInTheEquity() {
        let portfolio = priced(tradingState(cash: -50_000, held: [4: 100]), lasts: [4: 3_450])

        #expect(portfolio.cashText == "-฿500.00")
        #expect(portfolio.equityText == "฿2,950.00")
        let onlyCash = priced(tradingState(cash: -50_000))
        #expect(onlyCash.equityText == "-฿500.00")
    }

    @Test func hugeQuantitiesAndPricesClampWithoutATrap() {
        let top = MoneyFormat.baht(satang: Int64.max)
        let bottom = MoneyFormat.baht(satang: Int64.min)

        let huge = priced(tradingState(cash: 0, held: [4: Int64.max]), lasts: [4: Int64.max])
        #expect(huge.rows.first?.marketValueSatang == Int64.max)
        #expect(huge.equityText == top)

        let manyRows = tradingState(cash: Int64.max, held: [4: Int64.max, 2: Int64.max, 9: Int64.max])
        let moreThanFits = priced(manyRows, lasts: [4: Int64.max, 2: Int64.max, 9: Int64.max])
        #expect(moreThanFits.equityText == top, "the sum of rows and cash is worked out wide, then held to the range")
        #expect(moreThanFits.cashText == top)

        let balanced = priced(tradingState(cash: Int64.min, held: [4: Int64.max]), lasts: [4: Int64.max])
        #expect(balanced.equityText == "-฿0.01", "the lowest cash and the highest value make minus one satang")

        let underwater = priced(tradingState(cash: Int64.min))
        #expect(underwater.equityText == bottom)
        #expect(underwater.cashText == bottom)
    }

    @Test func theSameInputsGiveTheSameWords() {
        let one = priced(tradingState(cash: 123_456, held: [4: 300, 9: 100]), lasts: [4: 3_425, 9: 5_000])
        let other = priced(tradingState(cash: 123_456, held: [9: 100, 4: 300]), lasts: [9: 5_000, 4: 3_425])

        #expect(one.rows.count == 2)
        #expect(one.rows == other.rows)
        #expect(one.cashText == other.cashText)
        #expect(one.equityText == other.equityText)
    }
}

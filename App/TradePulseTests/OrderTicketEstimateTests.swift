import Contracts
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// What the ticket says about money before an order is sent: the line of prices, the estimate of what the shares are
/// worth (before commission), and the warnings that never stop an order.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OrderTicketEstimateTests {
    /// A ticket of `symbol` whose market has given exactly one update of PTT (id 4) with these prices.
    private func ticket(
        last: Int64 = 3_425, bid: Int64 = 3_400, ask: Int64 = 3_450, symbol: SymbolDTO = sampleSymbols[0],
        side: Side = .buy, rest: FakeRest = FakeRest()
    ) -> TicketRig {
        let rig = TicketRig(symbol: symbol, side: side, rest: rest, feedsPrices: false)
        var update = symbolUpdate(symbol: 4, seq: 1, last: last)
        update.bid = bid
        update.ask = ask
        feed(update, to: rig)
        return rig
    }

    /// Gives the market of `rig` one frame that carries `update`.
    private func feed(_ update: Tp_SymbolUpdate, to rig: TicketRig) {
        let frame = marketFrame(sendNs: 0, updates: [update])
        _ = rig.market.state.apply(frame: frame, receivedAtNs: TicketRig.frameReceivedNs)
    }

    /// A ticket over an account that holds `cash` satang and the shares `held`, already started.
    private func startedTicket(cash: Int64, held: [UInt32: Int64] = [:], side: Side = .buy) async -> TicketRig {
        let rest = FakeRest(accounts: [.account(accountDTO(cash: cash, held: held))])
        let rig = TicketRig(side: side, rest: rest)
        await rig.start()
        return rig
    }

    // MARK: The line of prices

    @Test func theMarketLineShowsLastBidAndAsk() {
        let rig = ticket()

        #expect(rig.model.marketLine == "Last 34.25 · Bid 34.00 · Ask 34.50")
    }

    @Test func theMarketLineWaitsForPricesAndDashesWhatIsMissing() {
        let waiting = TicketRig(feedsPrices: false)
        #expect(waiting.model.marketLine == "Waiting for prices")
        let other = TicketRig(symbol: sampleSymbols[1])
        #expect(other.model.marketLine == "Waiting for prices", "the market has prices of PTT only")

        let noBook = ticket(last: 3_425, bid: 0, ask: 0)
        #expect(noBook.model.marketLine == "Last 34.25 · Bid — · Ask —")
        let noTrade = ticket(last: 0, bid: 3_400, ask: 3_450)
        #expect(noTrade.model.marketLine == "Last — · Bid 34.00 · Ask 34.50")
    }

    @Test func theMarketLineIsReadFromTheMarketEachTimeItIsAsked() {
        let rig = TicketRig()
        #expect(rig.model.marketLine == "Last 34.25 · Bid 34.00 · Ask 34.50")

        rig.market.feed(last: 3_500)

        #expect(rig.model.marketLine == "Last 35.00 · Bid 34.75 · Ask 35.25")
    }

    // MARK: The estimate

    @Test func aLimitOrderIsEstimatedAtItsLimitPrice() {
        for side in [Side.buy, .sell] {
            let rig = ticket(side: side)
            rig.model.type = .limit
            rig.model.priceText = "35.00"
            rig.model.quantityText = "200"

            #expect(rig.model.estimatedCost == "≈ ฿7,000.00", "\(side)")
        }
    }

    @Test func aLimitOrderNeedsNoPriceFromTheMarket() {
        let rig = TicketRig(feedsPrices: false)
        rig.model.type = .limit
        rig.model.priceText = "35.00"

        #expect(rig.model.estimatedCost == "≈ ฿3,500.00")
    }

    @Test func aMarketBuyIsEstimatedAtTheAsk() {
        let rig = ticket(side: .buy)
        #expect(rig.model.estimatedCost == "≈ ฿3,450.00")

        rig.model.quantityText = "300"

        #expect(rig.model.estimatedCost == "≈ ฿10,350.00")
    }

    @Test func aMarketSellIsEstimatedAtTheBid() {
        let rig = ticket(side: .sell)
        #expect(rig.model.estimatedCost == "≈ ฿3,400.00")

        rig.model.quantityText = "300"

        #expect(rig.model.estimatedCost == "≈ ฿10,200.00")
    }

    @Test func aPriceThatIsNotAboveZeroFallsBackToTheLastPrice() {
        let prices: [(name: String, side: Side, bid: Int64, ask: Int64, estimate: String)] = [
            ("a zero ask", .buy, 3_400, 0, "≈ ฿3,425.00"),
            ("a negative ask", .buy, 3_400, -5, "≈ ฿3,425.00"),
            ("a zero bid", .sell, 0, 3_450, "≈ ฿3,425.00"),
            ("a negative bid", .sell, -5, 3_450, "≈ ฿3,425.00"),
            ("a usable ask", .buy, 3_400, 3_450, "≈ ฿3,450.00"),
        ]
        #expect(prices.count == 5)
        for row in prices {
            let rig = ticket(last: 3_425, bid: row.bid, ask: row.ask, side: row.side)

            #expect(rig.model.estimatedCost == row.estimate, "\(row.name)")
        }
    }

    @Test func withoutAPriceToWorkFromTheEstimateIsADash() {
        let noMarket = TicketRig(feedsPrices: false)
        #expect(noMarket.model.estimatedCost == "—")
        let otherSymbol = TicketRig(symbol: sampleSymbols[1])
        #expect(otherSymbol.model.estimatedCost == "—", "the market has a price of PTT only")
        let nothingAbove = ticket(last: 0, bid: 0, ask: 0)
        #expect(nothingAbove.model.estimatedCost == "—", "no price above zero anywhere")
        let sell = ticket(last: -1, bid: 0, ask: 3_450, side: .sell)
        #expect(sell.model.estimatedCost == "—")

        let control = ticket()
        #expect(control.model.estimatedCost != "—")
    }

    @Test func aFormThatIsNotValidHasNoEstimate() {
        let forms: [(quantity: String, type: OrderType, price: String)] = [
            ("", .market, ""), ("abc", .market, ""), ("150", .market, ""), ("0", .market, ""),
            ("10000100", .market, ""), ("100", .limit, ""), ("100", .limit, "44.52"), ("100", .limit, "99"),
            ("100", .limit, "0"), ("100", .limit, "x"),
        ]
        #expect(forms.count == 10)
        for form in forms {
            let rig = ticket()
            rig.model.quantityText = form.quantity
            rig.model.type = form.type
            rig.model.priceText = form.price
            #expect(rig.model.validationMessage != nil, "\(form)")

            #expect(rig.model.estimatedCost == "—", "\(form)")
        }

        let valid = ticket()
        valid.model.type = .limit
        valid.model.priceText = "34.25"
        #expect(valid.model.estimatedCost == "≈ ฿3,425.00")
    }

    @Test func theEstimateIsWrittenWithGroupsAndTwoDecimals() {
        let rig = ticket()
        rig.model.quantityText = "10000000"

        #expect(rig.model.estimatedCost == "≈ ฿345,000,000.00")
    }

    @Test func aHugeReferenceAndLimitClampInsteadOfTrapping() {
        let huge: Int64 = 9_223_372_036_854_775_600
        let symbol = SymbolDTO(id: 4, ticker: "HUGE", nameTh: "", nameEn: "", reference: huge, lot: 100)
        let rig = ticket(symbol: symbol)
        rig.model.type = .limit
        rig.model.priceText = Price(satang: huge).description
        rig.model.quantityText = "10000000"
        #expect(rig.model.validationMessage == nil, "the limit is the reference, which is on the step and in the band")

        let estimate = rig.model.estimatedCost

        #expect(estimate == "≈ ฿92,233,720,368,547,758.07")
    }

    @Test func aHugeAskClampsInsteadOfTrapping() {
        let rig = ticket(last: 3_425, bid: 3_400, ask: Int64.max)
        rig.model.quantityText = "10000000"

        #expect(rig.model.estimatedCost == "≈ ฿92,233,720,368,547,758.07")
    }

    @Test func theEstimateIsWorkedOutFromTheMarketEachTimeItIsAsked() {
        let rig = TicketRig()
        #expect(rig.model.estimatedCost == "≈ ฿3,450.00")

        rig.market.feed(last: 3_500)

        #expect(rig.model.estimatedCost == "≈ ฿3,525.00")
    }

    // MARK: Warnings that never block

    @Test func fundsHintDoesNotBlockSubmit() async {
        let rig = await startedTicket(cash: 100_000)
        #expect(rig.store.state.cash == 100_000)

        let hint = rig.model.balanceHint

        #expect(hint == OrderMessages.cashHint(estimate: 345_000, cash: 100_000))
        #expect(rig.model.validationMessage == nil)
        #expect(rig.model.canSubmit(tradingConnected: true))
        await rig.model.submit()
        #expect(rig.client.drafts.count == 1, "the exchange is left to refuse it")
    }

    @Test func positionHintDoesNotBlockSubmit() async {
        let rig = await startedTicket(cash: 100_000_000, held: [4: 100], side: .sell)
        rig.model.quantityText = "200"

        let hint = rig.model.balanceHint

        #expect(hint == OrderMessages.positionHint(held: 100, ticker: "PTT"))
        #expect(rig.model.validationMessage == nil)
        #expect(rig.model.canSubmit(tradingConnected: true))
        await rig.model.submit()
        #expect(rig.client.drafts.count == 1, "the exchange is left to refuse it")
    }

    @Test func noHintWhenAffordable() async {
        let affordable: [(name: String, cash: Int64, held: [UInt32: Int64], side: Side, quantity: String)] = [
            ("a buy with plenty of cash", 100_000_000, [:], .buy, "100"),
            ("a buy with exactly the cash it costs", 345_000, [:], .buy, "100"),
            ("a buy that needs no position", 345_000, [2: 5_000], .buy, "100"),
            ("a sale of all that is held", 0, [4: 100], .sell, "100"),
            ("a sale of part of what is held", 0, [4: 300], .sell, "100"),
            ("a sale that needs no cash", 0, [4: 100, 2: 5], .sell, "100"),
        ]
        #expect(affordable.count == 6)
        for row in affordable {
            let rig = await startedTicket(cash: row.cash, held: row.held, side: row.side)
            rig.model.quantityText = row.quantity
            #expect(rig.model.validationMessage == nil, "\(row.name)")

            #expect(rig.model.balanceHint == nil, "\(row.name)")
        }

        let oneSatangShort = await startedTicket(cash: 344_999)
        #expect(oneSatangShort.model.balanceHint != nil, "the same buy with one satang less")
        let oneShareShort = await startedTicket(cash: 0, held: [4: 99], side: .sell)
        oneShareShort.model.quantityText = "100"
        #expect(oneShareShort.model.balanceHint != nil, "the same sale with one share less")
    }

    @Test func theHintIsAboutTheSharesOfThisSymbolOnly() async {
        let rig = await startedTicket(cash: 0, held: [2: 5_000], side: .sell)

        #expect(rig.model.balanceHint == OrderMessages.positionHint(held: 0, ticker: "PTT"))
    }

    @Test func noHintWhileTheFormIsInvalid() async {
        let forms: [(quantity: String, type: OrderType, price: String)] = [
            ("abc", .market, ""), ("150", .market, ""), ("", .market, ""), ("100", .limit, ""),
            ("100", .limit, "44.52"), ("100", .limit, "99"),
        ]
        #expect(forms.count == 6)
        for form in forms {
            let rig = await startedTicket(cash: 0)
            rig.model.quantityText = form.quantity
            rig.model.type = form.type
            rig.model.priceText = form.price
            #expect(rig.model.validationMessage != nil, "\(form)")

            #expect(rig.model.balanceHint == nil, "\(form)")
        }

        let control = await startedTicket(cash: 0)
        #expect(control.model.balanceHint != nil, "the same account with a form that is valid")
    }

    @Test func noHintWithoutAnEstimate() async {
        let rest = FakeRest(accounts: [.account(accountDTO(cash: 0, held: [:]))])
        let buy = TicketRig(rest: rest, feedsPrices: false)
        await buy.start()
        #expect(buy.model.estimatedCost == "—")

        #expect(buy.model.balanceHint == nil)

        let sellRest = FakeRest(accounts: [.account(accountDTO(cash: 0, held: [:]))])
        let sell = TicketRig(side: .sell, rest: sellRest, feedsPrices: false)
        await sell.start()
        #expect(sell.model.balanceHint == nil)
    }

    @Test func aLimitOrderIsJudgedAtItsLimitPrice() async {
        // 100 shares at 35.00 cost 3,500.00: more than the 3,460.00 of cash, though the ask of 34.50 is affordable.
        let rig = await startedTicket(cash: 346_000)
        #expect(rig.model.balanceHint == nil)
        rig.model.type = .limit
        rig.model.priceText = "35.00"

        #expect(rig.model.balanceHint == OrderMessages.cashHint(estimate: 350_000, cash: 346_000))
    }

    @Test func theWordsOfTheWarningsNameWhatTheyCompare() {
        let cash = OrderMessages.cashHint(estimate: 345_000, cash: 100_000)
        #expect(cash.contains("฿3,450.00"))
        #expect(cash.contains("฿1,000.00"))
        #expect(cash.contains("may"))
        let position = OrderMessages.positionHint(held: 1_000, ticker: "PTT")
        #expect(position.contains("1,000"))
        #expect(position.contains("PTT"))
        #expect(position.contains("may"))
        let negative = OrderMessages.cashHint(estimate: 345_000, cash: -50_000)
        #expect(negative.contains("-฿500.00"))
    }
}

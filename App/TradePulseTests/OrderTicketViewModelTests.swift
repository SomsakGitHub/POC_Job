import Contracts
import Foundation
import Observation
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// The order ticket's model: when an order can be sent and why not, what it sends, and how it follows the order it
/// sent.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OrderTicketViewModelTests {
    // MARK: Whether the ticket can send

    @Test func submitDisabledWhenMarketDataStale() {
        let rig = TicketRig()
        #expect(rig.model.canSubmit(tradingConnected: true))

        rig.makeStale()

        #expect(!rig.model.canSubmit(tradingConnected: true))
        #expect(rig.model.blockedReason(tradingConnected: true) == OrderMessages.marketStale)
        rig.makeFresh()
        #expect(rig.model.canSubmit(tradingConnected: true))
    }

    @Test func marketDataIsFreshUpToThreeSecondsOldAndStaleAfterThat() {
        let rig = TicketRig()
        #expect(OrderTicketViewModel.maxMarketAgeNs == 3_000_000_000)

        rig.clock.set(TicketRig.frameReceivedNs + OrderTicketViewModel.maxMarketAgeNs)
        #expect(rig.model.canSubmit(tradingConnected: true))

        rig.clock.set(TicketRig.frameReceivedNs + OrderTicketViewModel.maxMarketAgeNs + 1)
        #expect(!rig.model.canSubmit(tradingConnected: true))
    }

    @Test func marketDataIsNotFreshBeforeTheFirstFrame() {
        let rig = TicketRig(feedsPrices: false)
        #expect(!rig.model.canSubmit(tradingConnected: true))
        #expect(rig.model.blockedReason(tradingConnected: true) == OrderMessages.marketStale)

        rig.market.feed()

        #expect(rig.model.canSubmit(tradingConnected: true))
    }

    @Test func submitDisabledWhenTradingDisconnected() {
        let rig = TicketRig()
        #expect(rig.model.canSubmit(tradingConnected: true))

        #expect(!rig.model.canSubmit(tradingConnected: false))
        #expect(rig.model.blockedReason(tradingConnected: false) == OrderMessages.tradingDisconnected)
    }

    @Test func submitDisabledWhileInFlight() async {
        let rig = TicketRig(submits: [.hold])
        let model = rig.model
        #expect(!model.inFlight)

        async let first: Void = model.submit()
        await waitFor("the first order is held by the client") { rig.client.heldSubmitCount == 1 }

        #expect(model.inFlight)
        #expect(!model.canSubmit(tradingConnected: true))
        await model.submit()
        #expect(rig.client.drafts.count == 1, "a second tap while the first is out sends nothing")

        rig.client.releaseSubmit(call: 0, .success(acceptedAnswer))
        await first

        #expect(!model.inFlight)
        #expect(model.canSubmit(tradingConnected: true))
        await model.submit()
        #expect(rig.client.drafts.count == 2, "once the answer is in, the next tap sends again")
    }

    @Test func blockedReasonIsTheFirstOfTheFourConditionsAndCanSubmitIsItsAbsence() async {
        let busy = OrderMessages.orderInFlight
        let down = OrderMessages.tradingDisconnected
        let old = OrderMessages.marketStale
        let wrong = OrderMessages.enterQuantity
        // An order in flight, the trading connection up, the market data fresh, the form valid: the reason is the
        // first of in flight, down, old and wrong that holds.
        let table: [(inFlight: Bool, connected: Bool, fresh: Bool, valid: Bool, reason: String?)] = [
            (false, true, true, true, nil), (false, true, true, false, wrong),
            (false, true, false, true, old), (false, true, false, false, old),
            (false, false, true, true, down), (false, false, true, false, down),
            (false, false, false, true, down), (false, false, false, false, down),
            (true, true, true, true, busy), (true, true, true, false, busy),
            (true, true, false, true, busy), (true, true, false, false, busy),
            (true, false, true, true, busy), (true, false, true, false, busy),
            (true, false, false, true, busy), (true, false, false, false, busy),
        ]
        let combinations = Set(
            table.map { ($0.inFlight ? 8 : 0) + ($0.connected ? 4 : 0) + ($0.fresh ? 2 : 0) + ($0.valid ? 1 : 0) }
        )
        #expect(table.count == 16)
        #expect(combinations.count == 16)
        for row in table {
            let rig = TicketRig(submits: [.hold])
            let model = rig.model
            var sending: Task<Void, Never>?
            if row.inFlight {
                sending = Task { await model.submit() }
                await waitFor("the order is held by the client") { rig.client.heldSubmitCount == 1 }
            }
            if !row.fresh { rig.makeStale() }
            if !row.valid { model.quantityText = "" }

            let reason = model.blockedReason(tradingConnected: row.connected)
            let canSubmit = model.canSubmit(tradingConnected: row.connected)

            #expect(reason == row.reason, "\(row)")
            #expect(canSubmit == (row.reason == nil), "\(row)")
            if let sending {
                rig.client.releaseSubmit(call: 0, .success(acceptedAnswer))
                await sending.value
            }
        }
    }

    @Test func theReasonsAreSentencesAPersonCanActOn() {
        let reasons = [OrderMessages.orderInFlight, OrderMessages.tradingDisconnected, OrderMessages.marketStale]

        #expect(Set(reasons).count == 3)
        #expect(!reasons.contains(""))
        let disconnected = "The order service is not connected. Orders are paused until it is back."
        #expect(OrderMessages.tradingDisconnected == disconnected)
        let stale = "Prices are out of date. Orders are paused until the market feed is back."
        #expect(OrderMessages.marketStale == stale)
    }

    // MARK: What the form needs

    @Test func limitRequiresPrice() {
        let rig = TicketRig()
        rig.model.type = .limit
        rig.model.priceText = ""

        #expect(rig.model.validationMessage == OrderMessages.enterPrice)
        #expect(!rig.model.canSubmit(tradingConnected: true))

        rig.model.priceText = "34.25"
        #expect(rig.model.validationMessage == nil)
        #expect(rig.model.canSubmit(tradingConnected: true))
    }

    @Test func quantityMustBeMultipleOfLot() {
        let rig = TicketRig()
        rig.model.quantityText = "150"

        let message = rig.model.validationMessage

        #expect(message?.contains("100") == true)
        #expect(message == OrderMessages.text(for: .invalidLot))
        #expect(!rig.model.canSubmit(tradingConnected: true))
        rig.model.quantityText = "200"
        #expect(rig.model.validationMessage == nil)
    }

    @Test func nonNumericQuantityIsInvalid() {
        let rig = TicketRig()
        let texts = ["", "abc", "1e3", "-100", "100.5"]
        #expect(texts.count == 5)
        for text in texts {
            rig.model.quantityText = text
            #expect(rig.model.validationMessage != nil, "\(text.debugDescription)")
            #expect(!rig.model.canSubmit(tradingConnected: true), "\(text.debugDescription)")
        }

        rig.model.quantityText = "100"
        #expect(rig.model.validationMessage == nil)
        #expect(rig.model.canSubmit(tradingConnected: true))
    }

    @Test func priceOffTickMessage() {
        let rig = TicketRig()
        rig.model.type = .limit
        rig.model.priceText = "44.52"

        let message = rig.model.validationMessage

        #expect(message?.contains("0.25") == true)
        #expect(message == OrderMessages.priceStep(satang(25)))
        #expect(!rig.model.canSubmit(tradingConnected: true))
        rig.model.priceText = "44.50"
        #expect(rig.model.validationMessage == nil)
    }

    // MARK: What is sent

    @Test func draftMapsFieldsExactly() async {
        let rig = TicketRig(symbol: sampleSymbols[0], side: .sell)
        rig.model.type = .limit
        rig.model.quantityText = "300"
        rig.model.priceText = "34.25"

        await rig.model.submit()

        let expected = OrderDraft(
            clientOrderId: "order-1", symbolId: 4, side: .sell, type: .limit, quantity: 300,
            limitPrice: Price(satang: 3_425)
        )
        #expect(rig.client.drafts == [expected])
    }

    @Test func aMarketDraftHasNoLimitPriceWhateverTheFieldHolds() async {
        let rig = TicketRig(symbol: sampleSymbols[1])
        rig.model.priceText = "garbage"

        await rig.model.submit()

        let expected = OrderDraft(
            clientOrderId: "order-1", symbolId: 2, side: .buy, type: .market, quantity: 100, limitPrice: nil
        )
        #expect(rig.client.drafts == [expected])
    }

    @Test func theTicketOpensOnTheSideItWasAskedFor() async {
        let rig = TicketRig(side: .sell)
        #expect(rig.model.side == .sell)

        await rig.model.submit()

        #expect(rig.client.drafts.map(\.side) == [.sell])
        #expect(TicketRig().model.side == .buy)
    }

    @Test func freshUuidPerSubmitButRetryReusesId() async throws {
        let rig = TicketRig(submits: [.failure(TestFailure())])
        await rig.start()
        let clock = rig.clock
        let model = OrderTicketViewModel(
            symbol: sampleSymbols[0], store: rig.store, marketState: rig.market.state, now: { clock.read() }
        )

        await model.submit()
        let first = try #require(model.lastClientOrderId)
        #expect(rig.store.state.orders.first?.status == .unknown, "the client threw: the order is unconfirmed")

        await rig.store.retryUnconfirmed(clientOrderId: first)
        await model.submit()
        let second = try #require(model.lastClientOrderId)
        await model.submit()
        let third = try #require(model.lastClientOrderId)

        let drafts = rig.client.drafts
        try #require(drafts.count == 4)
        #expect(drafts[1] == drafts[0], "the retry is the same order with the same id")
        #expect(drafts[0].clientOrderId == first)
        #expect(drafts[2].clientOrderId == second)
        #expect(drafts[3].clientOrderId == third)
        #expect(Set([first, second, third]).count == 3)
        for id in [first, second, third] {
            #expect(UUID(uuidString: id) != nil, "\(id) is a UUID")
        }
    }

    @Test func invalidFormSendsNothing() async {
        let forms: [(quantity: String, type: OrderType, price: String)] = [
            ("", .market, ""), ("abc", .market, ""), ("150", .market, ""), ("0", .market, ""),
            ("100", .limit, ""), ("100", .limit, "44.52"), ("100", .limit, "50"), ("100", .limit, "0"),
        ]
        #expect(forms.count == 8)
        for form in forms {
            let rig = TicketRig()
            rig.model.quantityText = form.quantity
            rig.model.type = form.type
            rig.model.priceText = form.price
            #expect(rig.model.validationMessage != nil, "\(form)")

            await rig.model.submit()

            #expect(rig.client.drafts.isEmpty, "\(form)")
            #expect(rig.store.state.orders.isEmpty, "\(form)")
            #expect(rig.model.lastClientOrderId == nil, "\(form)")
            #expect(!rig.model.inFlight, "\(form)")
        }

        let control = TicketRig()
        await control.model.submit()
        #expect(control.client.drafts.count == 1)
    }

    @Test func staleMarketSendsNothing() async {
        let cases: [(name: String, rig: TicketRig)] = [
            ("data that is too old", TicketRig()),
            ("no data yet", TicketRig(feedsPrices: false)),
        ]
        for (name, rig) in cases {
            rig.makeStale()

            await rig.model.submit()

            #expect(rig.client.drafts.isEmpty, "\(name)")
            #expect(rig.store.state.orders.isEmpty, "\(name)")
            #expect(!rig.model.inFlight, "\(name)")
        }

        let control = TicketRig()
        control.makeStale()
        control.makeFresh()
        await control.model.submit()
        #expect(control.client.drafts.count == 1)
    }

    @Test func aSubmitThatTheTradingConnectionCouldNotCarryEndsAsAnUnconfirmedRow() async {
        // The model cannot see the connection, so a tap that races a dropped connection is sent; the store turns the
        // order that got no answer into an unconfirmed one.
        let rig = TicketRig(submits: [.failure(URLError(.networkConnectionLost))])

        await rig.model.submit()

        #expect(rig.client.drafts.count == 1)
        #expect(rig.model.lastOrder?.status == .unknown)
        #expect(!rig.model.inFlight)
    }

    @Test func inFlightEndsWhenTheTaskThatSentTheOrderWasCancelled() async {
        let rig = TicketRig(submits: [.hold])
        let model = rig.model
        let sending = Task { await model.submit() }
        await waitFor("the order is held by the client") { rig.client.heldSubmitCount == 1 }
        #expect(model.inFlight)

        sending.cancel()
        rig.client.releaseSubmit(call: 0, .success(acceptedAnswer))
        await sending.value

        #expect(!model.inFlight)
        #expect(model.canSubmit(tradingConnected: true))
    }

    // MARK: Following the order that was sent

    @Test func lastOrderFollowsTheStore() async throws {
        let rig = TicketRig()
        await rig.start()
        #expect(rig.model.lastOrder == nil)
        #expect(rig.model.lastClientOrderId == nil)

        await rig.model.submit()
        let sent = try #require(rig.model.lastOrder)
        #expect(sent.id == "order-1")
        #expect(sent.status == .pending, "the server's answer carries its id, and the event log moves the row on")

        try await rig.trading.deliver(acceptedEvent(1, client: "order-1", order: "O-order-1"))
        #expect(rig.model.lastOrder?.status == .accepted)
        #expect(rig.model.lastOrder?.orderId == "O-order-1")

        try await rig.trading.deliver(fillEvent(2, order: "O-order-1"))
        #expect(rig.model.lastOrder?.status == .filled)
        #expect(rig.model.lastOrder?.filledQuantity == 100)
        #expect(rig.model.lastOrder?.averageFillPrice == satang(3_425))
    }

    @Test func lastOrderIsTheOrderOfTheLastSubmitAndGoesWhenTheServerStartsOver() async throws {
        let rig = TicketRig()
        await rig.start()

        await rig.model.submit()
        await rig.model.submit()
        #expect(rig.model.lastOrder?.id == "order-2")
        #expect(rig.model.lastClientOrderId == "order-2")
        #expect(rig.store.state.orders.count == 2)

        try await rig.trading.deliverEpoch("E1")
        try await rig.trading.deliverEpoch("E2")

        #expect(rig.store.state.orders.map(\.id) == ["client-E2"], "only the order the new epoch began with is left")
        #expect(rig.model.lastClientOrderId == "order-2")
        #expect(rig.model.lastOrder == nil, "the row of an epoch the server has left is not shown")
    }

    @Test func lastOrderIsTheOrderThisTicketSentWhateverAnotherScreenSentAfterIt() async {
        let rig = TicketRig()
        await rig.start()
        await rig.model.submit()
        let elsewhere = OrderDraft(clientOrderId: "elsewhere", symbolId: 2, side: .sell, type: .market, quantity: 100)

        await rig.store.submit(elsewhere)

        #expect(rig.store.state.orders.first?.id == "elsewhere", "the other order is the newest of the store")
        #expect(rig.model.lastOrder?.id == "order-1")
    }

    @Test func aRefusalIsShownAsARejectedRowWithTheExchangesReason() async {
        let rig = TicketRig(submits: [.rejected(.insufficientFunds)])

        await rig.model.submit()

        let order = rig.model.lastOrder
        #expect(order?.status == .rejected)
        #expect(order?.rejectReason == .insufficientFunds)
        #expect(!rig.model.inFlight)
    }

    @Test func theReadersOfLastOrderAreToldWhenTheStoreMovesTheOrder() async throws {
        let rig = TicketRig()
        await rig.start()
        await rig.model.submit()
        let model = rig.model
        let told = Flag()
        withObservationTracking {
            _ = model.lastOrder
        } onChange: {
            told.set()
        }
        #expect(!told.isSet)

        try await rig.trading.deliver(acceptedEvent(1, client: "order-1", order: "O-order-1"))

        #expect(told.isSet)
    }

    // MARK: Telling the readers of the reason

    /// Watches what `blockedReason(tradingConnected:)` reads, and gives a flag that is set when any of it changes.
    private func watchBlockedReason(of model: OrderTicketViewModel) -> Flag {
        let told = Flag()
        withObservationTracking {
            _ = model.blockedReason(tradingConnected: true)
        } onChange: {
            told.set()
        }
        return told
    }

    @Test func theReadersOfTheReasonAreToldOnlyWhenTheMarketDataGoesOldOrYoung() {
        let rig = TicketRig()
        let model = rig.model
        let told = watchBlockedReason(of: model)

        // Frames keep arriving and the screen keeps looking: nothing changes for what is drawn.
        for last in [3_500, 3_450, 3_400] as [Int64] {
            rig.market.feed(last: last)
            model.noteMarket()
        }
        #expect(!told.isSet, "a look at data that is still fresh tells nobody")

        rig.makeStale()
        model.noteMarket()
        #expect(told.isSet, "data that went old is told")

        let youngAgain = watchBlockedReason(of: model)
        model.noteMarket()
        #expect(!youngAgain.isSet, "a second look at old data tells nobody")
        rig.makeFresh()
        model.noteMarket()
        #expect(youngAgain.isSet, "data that is young again is told")
    }

    @Test func aRefusedSubmitOnOldDataTellsTheReadersOfTheReason() async {
        let rig = TicketRig()
        let model = rig.model
        let told = watchBlockedReason(of: model)
        rig.makeStale()
        #expect(!told.isSet, "the model has not looked yet")

        await model.submit()

        #expect(rig.client.drafts.isEmpty)
        #expect(told.isSet, "the refusal is what makes the screen show why")
    }

    @Test func theReasonIsRightBeforeAnyLookAtTheMarket() {
        // The flag is only what tells readers to read again: the answer itself is worked out from the clock.
        let rig = TicketRig()
        rig.makeStale()
        #expect(rig.model.blockedReason(tradingConnected: true) == OrderMessages.marketStale)

        rig.makeFresh()
        #expect(rig.model.blockedReason(tradingConnected: true) == nil)
    }

    @Test func theReadersOfTheReasonAreToldWhenTheFormOrTheOrderInFlightChanges() async {
        let rig = TicketRig(submits: [.hold])
        let model = rig.model
        let formChanged = watchBlockedReason(of: model)
        model.quantityText = "150"
        #expect(formChanged.isSet)

        model.quantityText = "100"
        let sending = watchBlockedReason(of: model)
        async let first: Void = model.submit()
        await waitFor("the order is held by the client") { rig.client.heldSubmitCount == 1 }
        #expect(sending.isSet, "an order going out is told")

        rig.client.releaseSubmit(call: 0, .success(acceptedAnswer))
        await first
    }
}

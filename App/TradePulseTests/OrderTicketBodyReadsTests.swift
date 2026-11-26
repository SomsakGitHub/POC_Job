import Contracts
import Observation
import SwiftUI
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// What the body of the order ticket and of each part of it reads. A body that is evaluated again at the pace of the
/// prices makes the controls in it drop the touch they are tracking, so the ticket's body and the body of the send
/// button read nothing that moves with the prices, and what does move with them is read in parts of its own. These
/// tests evaluate a body once, under observation, make one change and say whether the change would have made SwiftUI
/// evaluate that body again. They do not see SwiftUI evaluate a body: that takes a device.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OrderTicketBodyReadsTests {
    /// One thing that happens while the ticket is open: what it is called, and what it does to the rig and the ticket.
    /// It says whether it did what its name says, so that a change that did nothing cannot pass for one that told
    /// nobody.
    private typealias Change = (name: String, apply: @MainActor (ScreenRig, OrderTicketScreen) async -> Bool)

    /// A frame with new prices arrives: the pump counts one more tick.
    private var aFrameCarryingPrices: Change {
        ("a frame that carried prices", { rig, _ in
            rig.frame(seq: 2, last: 3_500, at: 10)
            return rig.env.pump.tick == 2
        })
    }

    /// The last frame becomes older than the ticket allows, and the ticket is told to look at the market again.
    private var theMarketDataGoingOld: Change {
        ("the market data going old and the ticket noticing", { rig, screen in
            rig.clock.set(TicketRig.frameReceivedNs + OrderTicketViewModel.maxMarketAgeNs + 1)
            screen.model.noteMarket()
            return !screen.model.canSubmit(tradingConnected: true)
        })
    }

    /// A person types another quantity.
    private var aQuantityTyped: Change {
        ("a quantity typed", { _, screen in
            screen.model.quantityText = "200"
            return screen.model.quantityText == "200"
        })
    }

    /// The ticket sends its order and the exchange accepts it.
    private var anOrderSentAndAccepted: Change {
        ("an order sent and accepted", { rig, screen in
            await screen.model.submit()
            guard let id = screen.model.lastClientOrderId else { return false }
            try? await rig.deliver(acceptedEvent(1, client: id, order: "O1"))
            return screen.model.lastOrder?.status == .accepted
        })
    }

    /// The ticket's order is accepted, filled and booked, so its row and the cash both move.
    private var anOrderFilledAndTheAccountChanging: Change {
        ("an order filled and the account changing", { rig, screen in
            await screen.model.submit()
            guard let id = screen.model.lastClientOrderId else { return false }
            try? await rig.deliver(acceptedEvent(1, client: id, order: "O1"))
            try? await rig.deliver(fillEvent(2, order: "O1"))
            try? await rig.deliver(ledgerEvent(3, ledgerSeq: 1, order: "O1"))
            return screen.model.lastOrder?.status == .filled && rig.env.trading.state.cash == 99_657_449
        })
    }

    /// An order that another screen sent is accepted, filled and booked.
    private var anotherOrderFilled: Change {
        ("an order of another screen accepted and filled", { rig, _ in
            let draft = OrderDraft(clientOrderId: "other", symbolId: 4, side: .buy, type: .market, quantity: 100)
            await rig.env.trading.submit(draft)
            try? await rig.deliver(acceptedEvent(1, client: "other", order: "O9"))
            try? await rig.deliver(fillEvent(2, order: "O9"))
            try? await rig.deliver(ledgerEvent(3, ledgerSeq: 1, order: "O9"))
            return rig.env.trading.state.orders.first?.status == .filled
        })
    }

    /// The ledger books a fill, so the cash changes.
    private var theAccountChanging: Change {
        ("the account changing", { rig, _ in
            try? await rig.deliver(ledgerEvent(1, ledgerSeq: 1))
            return rig.env.trading.state.cash == 99_657_449
        })
    }

    /// The connections to the servers drop and start to reconnect.
    private var theConnectionsDropping: Change {
        ("the connections dropping", { rig, _ in
            await rig.push(.reconnecting(attempt: 1))
            return rig.env.tradingConnection == .reconnecting(attempt: 1)
        })
    }

    /// For each of `changes`: makes a new rig and ticket, evaluates the body of the view `make` builds over them,
    /// makes the change and checks that the body would (`expected`) or would not have been evaluated again.
    private func check<Content: View>(
        told expected: Bool, by changes: [Change], sourceLocation: SourceLocation = #_sourceLocation,
        make: (ScreenRig, OrderTicketScreen) -> Content
    ) async {
        #expect(!changes.isEmpty, sourceLocation: sourceLocation)
        for change in changes {
            let rig = await ScreenRig.started()
            let screen = rig.ticket()
            let told = watchBody(of: make(rig, screen))
            #expect(!told.isSet, "before \(change.name)", sourceLocation: sourceLocation)

            let took = await change.apply(rig, screen)

            #expect(took, "\(change.name) happened", sourceLocation: sourceLocation)
            #expect(told.isSet == expected, "\(change.name)", sourceLocation: sourceLocation)
        }
    }

    // MARK: The screen

    @Test func theScreensBodyIsNotEvaluatedAgainWhenAnythingThatMovesChanges() async {
        let moves = [
            aFrameCarryingPrices, theMarketDataGoingOld, anOrderSentAndAccepted, anOrderFilledAndTheAccountChanging,
            anotherOrderFilled, theAccountChanging, theConnectionsDropping,
        ]
        #expect(moves.count == 7)

        await check(told: false, by: moves) { _, screen in screen }
    }

    @Test func theScreensBodyIsNotEvaluatedAgainWhileAnOrderIsOnItsWay() async {
        let rig = await ScreenRig.started(submits: [.hold])
        let screen = rig.ticket()
        let told = watchBody(of: screen)

        let model = screen.model
        async let sending: Void = model.submit()
        await waitFor("the order is held by the client") { rig.rig.tradingClient.heldSubmitCount == 1 }

        #expect(model.inFlight)
        #expect(!told.isSet)

        rig.rig.tradingClient.releaseSubmit(call: 0, .success(acceptedAnswer))
        await sending
        #expect(!told.isSet)
    }

    @Test func theScreensBodyIsEvaluatedAgainWhenTheFormChanges() async {
        // The control for the tests above: a change to what the body does read is told.
        let changes: [Change] = [
            aQuantityTyped,
            ("a limit order chosen", { _, screen in
                screen.model.type = .limit
                return screen.model.type == .limit
            }),
        ]

        await check(told: true, by: changes) { _, screen in screen }
    }

    // MARK: The parts

    @Test func thePriceLineIsEvaluatedAgainByTheFramesAndByNothingElse() async {
        await check(told: true, by: [aFrameCarryingPrices]) { rig, screen in
            TicketPriceLine(model: screen.model, environment: rig.env)
        }
        let others = [
            aQuantityTyped, theMarketDataGoingOld, anOrderSentAndAccepted, theAccountChanging, theConnectionsDropping,
        ]
        await check(told: false, by: others) { rig, screen in
            TicketPriceLine(model: screen.model, environment: rig.env)
        }
    }

    @Test func theEstimateIsEvaluatedAgainByTheFramesTheFormAndTheAccountButNotByTheMarketBeingOld() async {
        let told = [aFrameCarryingPrices, aQuantityTyped, theAccountChanging, anOrderSentAndAccepted]
        await check(told: true, by: told) { rig, screen in
            TicketEstimateSection(model: screen.model, environment: rig.env)
        }
        let notTold = [theMarketDataGoingOld, theConnectionsDropping]
        await check(told: false, by: notTold) { rig, screen in
            TicketEstimateSection(model: screen.model, environment: rig.env)
        }
    }

    @Test func theSendButtonIsEvaluatedAgainOnlyByWhatChangesTheButton() async {
        let told = [aQuantityTyped, theMarketDataGoingOld, theConnectionsDropping, anOrderSentAndAccepted]
        await check(told: true, by: told) { rig, screen in
            TicketSubmitSection(model: screen.model, environment: rig.env)
        }
        // Frames, fills and the account move all the time and none of them changes the button.
        let notTold = [aFrameCarryingPrices, anotherOrderFilled, theAccountChanging]
        await check(told: false, by: notTold) { rig, screen in
            TicketSubmitSection(model: screen.model, environment: rig.env)
        }
    }

    @Test func theSendButtonIsEvaluatedAgainWhenAnOrderGoesOutAndWhenTheMarketDataIsYoungAgain() async {
        let rig = await ScreenRig.started(submits: [.hold])
        let screen = rig.ticket()
        let model = screen.model
        let sending = watchBody(of: TicketSubmitSection(model: model, environment: rig.env))

        async let submitted: Void = model.submit()
        await waitFor("the order is held by the client") { rig.rig.tradingClient.heldSubmitCount == 1 }
        #expect(sending.isSet, "an order going out is told")

        rig.rig.tradingClient.releaseSubmit(call: 0, .success(acceptedAnswer))
        await submitted

        rig.clock.set(TicketRig.frameReceivedNs + OrderTicketViewModel.maxMarketAgeNs + 1)
        model.noteMarket()
        let young = watchBody(of: TicketSubmitSection(model: model, environment: rig.env))
        rig.clock.set(TicketRig.frameReceivedNs + 1_000)
        model.noteMarket()
        #expect(young.isSet, "data that is young again is told")
    }

    @Test func theOrderRowIsEvaluatedAgainWhenTheOrderMovesOrTheConnectionChangesAndNotByTheFrames() async {
        let told = [anOrderSentAndAccepted, anOrderFilledAndTheAccountChanging, theConnectionsDropping]
        await check(told: true, by: told) { rig, screen in
            TicketOrderRow(model: screen.model, environment: rig.env)
        }
        let notTold = [
            aFrameCarryingPrices, aQuantityTyped, theMarketDataGoingOld, theAccountChanging, anotherOrderFilled,
        ]
        await check(told: false, by: notTold) { rig, screen in
            TicketOrderRow(model: screen.model, environment: rig.env)
        }
    }

    @Test func theBridgeIsEvaluatedAgainByTheFramesAndTheConnectionAndNotByTheForm() async {
        let told = [aFrameCarryingPrices, theConnectionsDropping]
        await check(told: true, by: told) { rig, screen in
            TicketBridge(model: screen.model, environment: rig.env)
        }
        let notTold = [aQuantityTyped, anOrderSentAndAccepted, theAccountChanging]
        await check(told: false, by: notTold) { rig, screen in
            TicketBridge(model: screen.model, environment: rig.env)
        }
    }
}

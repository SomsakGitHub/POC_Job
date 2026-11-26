import Contracts
import Observation
import SwiftUI
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// What the bodies of the Orders screen, the Portfolio screen, the banner and the recent fills of the detail screen
/// read. The screens hold controls and the prices move all the time, so the body of a screen reads nothing that
/// moves, and what has to follow the account or the orders is read in a part of its own. These tests evaluate a body
/// once, under observation, make one change and say whether the change would have made SwiftUI evaluate that body
/// again. They do not see SwiftUI evaluate a body: that takes a device.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OrderScreensBodyReadsTests {
    /// One thing that happens while a screen is open: what it is called, and what it does to the rig. It says whether
    /// it did what its name says, so that a change that did nothing cannot pass for one that told nobody.
    private typealias Change = (name: String, apply: @MainActor (ScreenRig) async -> Bool)

    /// A frame with new prices arrives: the pump counts one more tick.
    private var aFrameCarryingPrices: Change {
        ("a frame that carried prices", { rig in
            rig.frame(seq: 2, last: 3_500, at: 10)
            return rig.env.pump.tick == 2
        })
    }

    /// An order is sent and waits for the exchange's answer.
    private var anOrderSubmitted: Change {
        ("an order submitted", { rig in
            let draft = OrderDraft(clientOrderId: "own", symbolId: 4, side: .buy, type: .market, quantity: 100)
            await rig.env.trading.submit(draft)
            return rig.env.trading.state.orders.count == 1
        })
    }

    /// An order is sent, accepted, filled and booked in the ledger.
    private var anOrderAcceptedAndFilled: Change {
        ("an order accepted and filled", { rig in
            let draft = OrderDraft(clientOrderId: "own", symbolId: 4, side: .buy, type: .market, quantity: 100)
            await rig.env.trading.submit(draft)
            try? await rig.deliver(acceptedEvent(1, client: "own", order: "O1"))
            try? await rig.deliver(fillEvent(2, order: "O1"))
            try? await rig.deliver(ledgerEvent(3, ledgerSeq: 1, order: "O1"))
            return rig.env.trading.state.orders.first?.status == .filled && rig.env.trading.state.ledger.count == 1
        })
    }

    /// The ledger books a fill of the symbol, so the cash changes and a row joins the ledger.
    private var aFillOfTheLedger: Change {
        ("a fill of the ledger", { rig in
            try? await rig.deliver(ledgerEvent(1, ledgerSeq: 1))
            return rig.env.trading.state.ledger.count == 1 && rig.env.trading.state.cash == 99_657_449
        })
    }

    /// The server announces a second epoch, so the app has to reload what it knew.
    private var theServerStartingOver: Change {
        ("the server starting over", { rig in
            try? await rig.deliverEpoch("E1")
            try? await rig.deliverEpoch("E2")
            return rig.env.trading.state.epochChanges == 1
        })
    }

    /// The connections to the servers drop and start to reconnect.
    private var theConnectionsDropping: Change {
        ("the connections dropping", { rig in
            await rig.push(.reconnecting(attempt: 1))
            return rig.env.tradingConnection == .reconnecting(attempt: 1)
        })
    }

    /// For each of `changes`: makes a new rig, evaluates the body of the view `make` builds over it, makes the change
    /// and checks that the body would (`expected`) or would not have been evaluated again.
    private func check<Content: View>(
        told expected: Bool, by changes: [Change], sourceLocation: SourceLocation = #_sourceLocation,
        make: (ScreenRig) -> Content
    ) async {
        #expect(!changes.isEmpty, sourceLocation: sourceLocation)
        for change in changes {
            let rig = await ScreenRig.started()
            let told = watchBody(of: make(rig))
            #expect(!told.isSet, "before \(change.name)", sourceLocation: sourceLocation)

            let took = await change.apply(rig)

            #expect(took, "\(change.name) happened", sourceLocation: sourceLocation)
            #expect(told.isSet == expected, "\(change.name)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Orders

    @Test func theOrdersScreensBodyIsNotEvaluatedAgainWhenAnythingChanges() async {
        let moves = [
            aFrameCarryingPrices, anOrderSubmitted, anOrderAcceptedAndFilled, aFillOfTheLedger,
            theServerStartingOver, theConnectionsDropping,
        ]
        #expect(moves.count == 6)

        await check(told: false, by: moves) { rig in OrdersScreen(environment: rig.env) }
        // The control: what the screen leaves to the list is told.
        await check(told: true, by: [anOrderSubmitted]) { rig in OrdersList(environment: rig.env) }
    }

    @Test func theOrdersListIsEvaluatedAgainWhenTheTradingStateOrTheConnectionChangesAndNotByTheFrames() async {
        let told = [
            anOrderSubmitted, anOrderAcceptedAndFilled, aFillOfTheLedger, theServerStartingOver,
            theConnectionsDropping,
        ]
        await check(told: true, by: told) { rig in OrdersList(environment: rig.env) }
        await check(told: false, by: [aFrameCarryingPrices]) { rig in OrdersList(environment: rig.env) }
    }

    @Test func theBannerIsEvaluatedAgainWhenTheServerStartsOverAndNotByTheFrames() async {
        await check(told: true, by: [theServerStartingOver]) { rig in
            EpochBannerView(trading: rig.env.trading, state: .constant(EpochBannerState()))
        }
        await check(told: false, by: [aFrameCarryingPrices, theConnectionsDropping]) { rig in
            EpochBannerView(trading: rig.env.trading, state: .constant(EpochBannerState()))
        }
    }

    // MARK: Portfolio

    @Test func thePortfolioScreensBodyIsNotEvaluatedAgainWhenAnythingChanges() async {
        let moves = [
            aFrameCarryingPrices, anOrderSubmitted, anOrderAcceptedAndFilled, aFillOfTheLedger,
            theServerStartingOver, theConnectionsDropping,
        ]
        #expect(moves.count == 6)

        await check(told: false, by: moves) { rig in PortfolioScreen(environment: rig.env) }
        // The control: what the screen leaves to the account is told.
        await check(told: true, by: [aFillOfTheLedger]) { rig in
            PortfolioAccount(environment: rig.env, updatedAt: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func theAccountIsEvaluatedAgainWhenTheTradingStateChangesAndNotByTheFramesOrTheConnections() async {
        // The prices reach it through the timeline that draws it twice a second, not through the frames.
        let told = [anOrderAcceptedAndFilled, aFillOfTheLedger, theServerStartingOver]
        await check(told: true, by: told) { rig in
            PortfolioAccount(environment: rig.env, updatedAt: Date(timeIntervalSince1970: 0))
        }
        await check(told: false, by: [aFrameCarryingPrices, theConnectionsDropping]) { rig in
            PortfolioAccount(environment: rig.env, updatedAt: Date(timeIntervalSince1970: 0))
        }
    }

    @Test func theTransactionsAreEvaluatedAgainWhenAFillArrivesOrTheServerOrTheConnectionChanges() async {
        let told = [aFillOfTheLedger, anOrderAcceptedAndFilled, theServerStartingOver, theConnectionsDropping]
        await check(told: true, by: told) { rig in TransactionsSection(environment: rig.env) }
        await check(told: false, by: [aFrameCarryingPrices]) { rig in TransactionsSection(environment: rig.env) }
    }

    // MARK: The detail screen

    @Test func theDetailScreensBodyIsNotEvaluatedAgainWhenAFillArrivesAndTheFillsAre() async {
        let fills = [aFillOfTheLedger, anOrderAcceptedAndFilled]
        await check(told: false, by: fills) { rig in
            StockDetailScreen(symbol: sampleSymbols[0], environment: rig.env)
        }
        await check(told: true, by: fills) { rig in RecentFillsView(symbolId: 4, environment: rig.env) }
        await check(told: false, by: [aFrameCarryingPrices, theConnectionsDropping]) { rig in
            RecentFillsView(symbolId: 4, environment: rig.env)
        }
    }

    @Test func theTradeButtonsReadNothingThatChanges() async {
        let moves = [
            aFrameCarryingPrices, anOrderAcceptedAndFilled, aFillOfTheLedger, theServerStartingOver,
            theConnectionsDropping,
        ]

        await check(told: false, by: moves) { rig in
            TradeButtons(symbol: sampleSymbols[0], environment: rig.env)
        }
        // The control: the fills next to them are told.
        await check(told: true, by: [aFillOfTheLedger]) { rig in RecentFillsView(symbolId: 4, environment: rig.env) }
    }
}

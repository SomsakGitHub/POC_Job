import SwiftUI
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// Whether the money amounts and the share counts of the portfolio and order screens stay whole at the largest text
/// size: an amount is never broken across lines, two figures sit side by side only when they fit, and an order row is
/// never cut short. A layout is judged by the height it asks for: when narrowing the column makes a view taller,
/// something in it was broken, and when offering it less height makes it shorter, something in it was cut.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AmountLayoutTests {
    // MARK: Cash and equity

    @Test func theCashAndTheEquityOfAboutAMillionBahtAreNotBrokenAtTheLargestTextSize() {
        let figures = AccountFigures(cash: "฿1,000,169.82", equity: "฿1,003,594.82")
        let plain = Text("฿1,003,594.82").font(.title3.weight(.semibold).monospacedDigit())

        let wide = LayoutRig.height(of: figures, at: .accessibility5, width: 500)
        let narrow = LayoutRig.height(of: figures, at: .accessibility5, width: LayoutRig.contentWidth)
        let plainWide = LayoutRig.height(of: plain, at: .accessibility5, width: 500)
        let plainNarrow = LayoutRig.height(of: plain, at: .accessibility5, width: LayoutRig.contentWidth)

        #expect(plainNarrow > plainWide, "the control: that amount in a plain text is broken across lines")
        #expect(narrow <= wide + 1, "in a wide column the figures are \(wide) pt tall, in a narrow one \(narrow) pt")
    }

    @Test func theCashAndTheEquityStayBesideEachOtherWhileTheyFit() {
        let large = AccountFigures(cash: "฿1,000,169.82", equity: "฿1,003,594.82")
        let small = AccountFigures(cash: "฿5.00", equity: "฿5.00")

        let largeAtRegular = LayoutRig.height(of: large, at: .large, width: LayoutRig.contentWidth)
        let smallAtRegular = LayoutRig.height(of: small, at: .large, width: LayoutRig.contentWidth)
        let largeAtLargest = LayoutRig.height(of: large, at: .accessibility5, width: LayoutRig.contentWidth)
        let smallAtLargest = LayoutRig.height(of: small, at: .accessibility5, width: LayoutRig.contentWidth)

        #expect(abs(largeAtRegular - smallAtRegular) < 1, "one row at the regular size: \(largeAtRegular) pt")
        #expect(smallAtLargest > 1.5 * smallAtRegular, "the control: the largest size draws the figures larger")
        #expect(largeAtLargest > 1.8 * smallAtLargest, "two rows, where small amounts are one: \(largeAtLargest) pt")
    }

    @Test func theCashAndTheEquityStackAsSoonAsTheyDoNotFitEvenBelowTheAccessibilitySizes() {
        let large = AccountFigures(cash: "฿1,000,169.82", equity: "฿1,003,594.82")
        let small = AccountFigures(cash: "฿5.00", equity: "฿5.00")

        let largeAtBigText = LayoutRig.height(of: large, at: .xxxLarge, width: LayoutRig.contentWidth)
        let smallAtBigText = LayoutRig.height(of: small, at: .xxxLarge, width: LayoutRig.contentWidth)

        #expect(!DynamicTypeSize.xxxLarge.isAccessibilitySize, "the control: this is not an accessibility size")
        #expect(largeAtBigText > 1.9 * smallAtBigText, "two rows, where small amounts are one: \(largeAtBigText) pt")
    }

    // MARK: Transactions and positions

    /// A fill that changed the cash by `cashDelta` satang, as the transactions list draws it.
    private func fill(cashDelta: Int64) -> TransactionRowView {
        TransactionRowView(model: TransactionRowModel(row: ledgerRow(1, cashDelta: cashDelta), ticker: "PTT"))
    }

    /// A holding of PTT worth `value` satang, as the portfolio draws it.
    private func holding(worth value: Int64) -> PositionRowView {
        let row = PositionRow(id: 1, ticker: "PTT", quantity: 100, last: satang(5), marketValueSatang: value)
        return PositionRowView(row: row)
    }

    @Test func aCashChangeAndAPositionValueOfTenMillionBahtStayOnOneLineAtTheLargestTextSize() {
        let column = LayoutRig.contentWidth
        let plain = Text("-฿10,000,000.00").font(.subheadline.weight(.semibold).monospacedDigit())
        let plainWide = LayoutRig.height(of: plain, at: .accessibility5, width: 700)
        let plainNarrow = LayoutRig.height(of: plain, at: .accessibility5, width: column)

        let smallFill = LayoutRig.height(of: fill(cashDelta: -500), at: .accessibility5, width: column)
        let largeFill = LayoutRig.height(of: fill(cashDelta: -1_000_000_000), at: .accessibility5, width: column)
        let smallHolding = LayoutRig.height(of: holding(worth: 500), at: .accessibility5, width: column)
        let largeHolding = LayoutRig.height(of: holding(worth: 1_000_000_000), at: .accessibility5, width: column)

        #expect(fill(cashDelta: -1_000_000_000).model.cashChangeText == "-฿10,000,000.00")
        #expect(plainNarrow > plainWide, "the control: that amount in a plain text is broken across lines")
        #expect(largeFill <= smallFill + 1, "fills of -฿5.00 and -฿10,000,000.00: \(smallFill) pt, \(largeFill) pt")
        #expect(
            largeHolding <= smallHolding + 1,
            "holdings of ฿5.00 and ฿10,000,000.00: \(smallHolding) pt, \(largeHolding) pt"
        )
    }

    // MARK: Order ticket

    @Test func anEstimateOfMillionsOfBahtIsNotBrokenAtTheLargestTextSize() async throws {
        let rest = FakeRest(accounts: [.account(accountDTO(cash: 400_000_000))])
        let rig = await ScreenRig.started(rest: rest)
        let model = rig.ticket().model
        let section = TicketEstimateSection(model: model, environment: rig.env).padding(.horizontal, LayoutRig.margin)

        model.quantityText = "100"
        let shortEstimate = model.estimatedCost
        let shortHint = model.balanceHint
        let short = LayoutRig.height(of: section, at: .accessibility5, width: LayoutRig.screenWidth)
        model.quantityText = "100000"
        let longEstimate = model.estimatedCost
        let longHint = model.balanceHint
        let long = LayoutRig.height(of: section, at: .accessibility5, width: LayoutRig.screenWidth)

        #expect(rig.env.trading.state.cash == 400_000_000, "the account holds four million baht")
        #expect(shortHint == nil, "the account covers \(shortEstimate)")
        #expect(longHint == nil, "the account covers \(longEstimate)")
        #expect(longEstimate.count > shortEstimate.count + 3, "the control: \(longEstimate) is longer than the other")
        #expect(long <= short + 1, "\(shortEstimate) takes \(short) pt and \(longEstimate) takes \(long) pt")
    }

    // MARK: Orders

    /// A limit order of PTT that is partly filled, as the orders list draws it.
    private func partlyFilled(quantity: Int64, filled: Int64) -> some View {
        let order = OrderRow(
            id: "order-1", orderId: "O1", symbolId: 4, side: .buy, type: .limit, quantity: quantity,
            limitPrice: satang(3_425), filledQuantity: filled, averageFillPrice: satang(3_420),
            status: .partiallyFilled, rejectReason: nil, createdNs: 1
        )
        return OrderRowView(
            presentation: OrderRowPresentation(row: order, ticker: "PTT", tradingConnected: true),
            isCancelling: false, cancel: {}, retry: {}
        )
        .padding(.horizontal, LayoutRig.margin)
    }

    @Test func aLargeOrderKeepsItsSharesAndItsAveragePriceWholeAtTheLargestTextSize() {
        let few = partlyFilled(quantity: 100, filled: 30)
        let many = partlyFilled(quantity: 1_000_000, filled: 500_000)
        let plain = Text("500,000 / 1,000,000").font(.subheadline.monospacedDigit())

        let fewAtLargest = LayoutRig.height(of: few, at: .accessibility5, width: LayoutRig.screenWidth)
        let manyAtLargest = LayoutRig.height(of: many, at: .accessibility5, width: LayoutRig.screenWidth)
        let plainWide = LayoutRig.height(of: plain, at: .accessibility5, width: 700)
        let plainNarrow = LayoutRig.height(of: plain, at: .accessibility5, width: LayoutRig.contentWidth)

        #expect(plainNarrow > plainWide, "the control: that count of shares in a plain text takes two lines")
        #expect(manyAtLargest <= fewAtLargest + 1, "the orders are \(fewAtLargest) pt and \(manyAtLargest) pt tall")
    }

    @Test func theSharesAndTheAveragePriceStayOnOneRowAtTheRegularTextSize() {
        let few = partlyFilled(quantity: 100, filled: 30)
        let many = partlyFilled(quantity: 1_000_000, filled: 500_000)

        let fewAtRegular = LayoutRig.height(of: few, at: .large, width: LayoutRig.screenWidth)
        let manyAtRegular = LayoutRig.height(of: many, at: .large, width: LayoutRig.screenWidth)
        let manyAtLargest = LayoutRig.height(of: many, at: .accessibility5, width: LayoutRig.screenWidth)

        #expect(abs(manyAtRegular - fewAtRegular) < 1, "one row, whatever the count: \(fewAtRegular), \(manyAtRegular)")
        #expect(manyAtLargest > 2 * manyAtRegular, "the control: the largest size is another layout")
    }

    /// A market order of PTT that is filled, as the orders list draws it.
    private func filledMarket() -> some View {
        let order = OrderRow(
            id: "order-1", orderId: "O1", symbolId: 4, side: .buy, type: .market, quantity: 100,
            limitPrice: nil, filledQuantity: 100, averageFillPrice: satang(3_425),
            status: .filled, rejectReason: nil, createdNs: 1
        )
        return OrderRowView(
            presentation: OrderRowPresentation(row: order, ticker: "PTT", tradingConnected: true),
            isCancelling: false, cancel: {}, retry: {}
        )
        .padding(.horizontal, LayoutRig.margin)
    }

    @Test func anOrderRowKeepsAllItsLinesWhateverHeightTheListOffersIt() {
        let text = Text("Buy PTT \u{00B7} Limit 34.25 \u{00B7} Partly filled").font(.headline)
        let textNeeds = LayoutRig.height(of: text, at: .accessibility5, width: LayoutRig.contentWidth)
        let textTook = LayoutRig.height(
            of: text, at: .accessibility5, width: LayoutRig.contentWidth, offeredHeight: textNeeds / 2
        )
        #expect(textTook < textNeeds, "the control: a plain text offered half its height is cut, \(textTook) pt")

        let rows = [
            ("filled market order", AnyView(filledMarket())),
            ("partly filled limit order", AnyView(partlyFilled(quantity: 100, filled: 30))),
        ]
        for (name, row) in rows {
            let needed = LayoutRig.height(of: row, at: .accessibility5, width: LayoutRig.screenWidth)
            #expect(needed > 300, "the control: the \(name) is tall at the largest size, \(needed) pt")
            for share: CGFloat in [0.5, 1, 1.2, 1.5] {
                let took = LayoutRig.height(
                    of: row, at: .accessibility5, width: LayoutRig.screenWidth, offeredHeight: needed * share
                )
                #expect(abs(took - needed) < 1, "the \(name) needs \(needed) pt, took \(took) pt of \(needed * share)")
            }
        }
    }
}

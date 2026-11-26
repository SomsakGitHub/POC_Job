import Contracts
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// What an order row says on screen, the sentences for every reason an order can be refused, and the two small ways of
/// writing things that the order screens share.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OrderRowPresentationTests {
    /// An order of PTT (id 4) in `status`, with the fields a test wants to set.
    private func row(
        status: OrderStatus, side: Side = .buy, type: OrderType = .market, quantity: Int64 = 100, limit: Int64? = nil,
        filled: Int64 = 0, average: Int64? = nil, orderId: String? = "O1", reason: RejectReason? = nil
    ) -> OrderRow {
        OrderRow(
            id: "order-1", orderId: orderId, symbolId: 4, side: side, type: type, quantity: quantity,
            limitPrice: limit.map(satang), filledQuantity: filled, averageFillPrice: average.map(satang),
            status: status, rejectReason: reason, createdNs: 1
        )
    }

    /// The presentation of `row` as PTT, with the trading connection up unless said otherwise.
    private func present(_ row: OrderRow, connected: Bool = true) -> OrderRowPresentation {
        OrderRowPresentation(row: row, ticker: "PTT", tradingConnected: connected)
    }

    /// How a status is drawn.
    private typealias Kind = OrderRowPresentation.StatusKind

    /// Every reason an order can be refused for.
    private var allReasons: [RejectReason] {
        (1...9).compactMap { RejectReason(rawValue: Int32($0)) }
    }

    // MARK: Status

    @Test func everyStatusHasItsWordItsKindAndItsButtons() {
        let table: [(status: OrderStatus, text: String, kind: Kind, cancel: Bool, retry: Bool)] = [
            (.pending, "Sending", .working, false, false),
            (.accepted, "Open", .working, true, false),
            (.partiallyFilled, "Partly filled", .working, true, false),
            (.filled, "Filled", .done, false, false),
            (.cancelled, "Cancelled", .neutral, false, false),
            (.rejected, "Rejected", .failed, false, false),
            (.unknown, "Unconfirmed", .warning, false, true),
        ]
        #expect(table.count == 7)
        for entry in table {
            let presentation = present(row(status: entry.status))

            #expect(presentation.statusText == entry.text, "\(entry.status)")
            #expect(presentation.statusKind == entry.kind, "\(entry.status)")
            #expect(presentation.canCancel == entry.cancel, "\(entry.status)")
            #expect(presentation.canRetry == entry.retry, "\(entry.status)")
            #expect(presentation.id == "order-1")
            #expect(presentation.orderId == "O1")
        }
    }

    @Test func eachKindOfStatusHasItsOwnImage() {
        let kinds: [Kind] = [.working, .done, .neutral, .warning, .failed]
        let names = kinds.map(\.symbolName)

        #expect(names.count == 5)
        #expect(!names.contains(""))
        #expect(Set(names).count == 5, "colour is never the only cue: no two kinds share an image")
    }

    @Test func cancelNeedsTheServersIdForTheOrder() {
        let withId = present(row(status: .accepted, orderId: "O1"))
        let withoutId = present(row(status: .accepted, orderId: nil))
        let partlyWithout = present(row(status: .partiallyFilled, orderId: nil))

        #expect(withId.canCancel)
        #expect(!withoutId.canCancel)
        #expect(!partlyWithout.canCancel)
        #expect(withoutId.orderId == nil)
    }

    @Test func cancelNeedsTheTradingConnectionAndRetryDoesNot() {
        let open: [OrderStatus] = [.accepted, .partiallyFilled]
        for status in open {
            #expect(present(row(status: status), connected: true).canCancel, "\(status)")
            #expect(!present(row(status: status), connected: false).canCancel, "\(status)")
        }

        #expect(present(row(status: .unknown), connected: false).canRetry)
        #expect(present(row(status: .unknown), connected: true).canRetry)
        #expect(!present(row(status: .accepted), connected: true).canRetry)
    }

    // MARK: What the row says

    @Test func theTitleSaysSideTickerAndTypeWithTheLimitPrice() {
        let market = present(row(status: .pending))
        #expect(market.title == "Buy PTT · Market")

        let limit = present(row(status: .accepted, side: .sell, type: .limit, limit: 3_425))
        #expect(limit.title == "Sell PTT · Limit 34.25")

        let noPrice = present(row(status: .accepted, type: .limit, limit: nil))
        #expect(noPrice.title == "Buy PTT · Limit", "a limit order the server reported with no price")

        let other = OrderRowPresentation(row: row(status: .pending), ticker: "#12", tradingConnected: true)
        #expect(other.title == "Buy #12 · Market")
    }

    @Test func theQuantityIsWhatWasFilledOverWhatWasAskedWithGroups() {
        let table: [(filled: Int64, quantity: Int64, text: String)] = [
            (0, 100, "0 / 100"), (30, 100, "30 / 100"), (100, 100, "100 / 100"),
            (1_000, 10_000_000, "1,000 / 10,000,000"),
            (Int64.max, Int64.max, "9,223,372,036,854,775,807 / 9,223,372,036,854,775,807"),
        ]
        #expect(table.count == 5)
        for entry in table {
            let presentation = present(row(status: .partiallyFilled, quantity: entry.quantity, filled: entry.filled))

            #expect(presentation.quantityText == entry.text)
        }
    }

    @Test func theAverageIsThePriceOfTheFillsOrADashBeforeTheFirst() {
        #expect(present(row(status: .accepted)).averageText == "—")
        #expect(present(row(status: .partiallyFilled, filled: 30, average: 3_425)).averageText == "avg 34.25")
        #expect(present(row(status: .filled, filled: 100, average: 5)).averageText == "avg 0.05")
    }

    @Test func aRejectedRowSaysTheReasonInPlainEnglish() {
        for reason in allReasons {
            let presentation = present(row(status: .rejected, reason: reason))

            #expect(presentation.reasonText == OrderMessages.text(for: reason), "\(reason)")
            #expect(presentation.reasonText?.isEmpty == false, "\(reason)")
        }
        #expect(allReasons.count == 9)

        let withoutReason = present(row(status: .rejected, reason: nil))
        #expect(withoutReason.reasonText == OrderMessages.notAccepted)
        #expect(OrderMessages.notAccepted.contains("did not accept"))
    }

    @Test func aCancelledRowSaysItsReasonOnlyWhenTheExchangeGaveOne() {
        let noLiquidity = present(row(status: .cancelled, reason: .noLiquidity))
        #expect(noLiquidity.reasonText == OrderMessages.text(for: .noLiquidity))

        let ordinary = present(row(status: .cancelled, reason: nil))
        #expect(ordinary.reasonText == nil)
    }

    @Test func anUnconfirmedRowSaysTheExchangeHasNotAnsweredAndThatSendingAgainIsSafe() {
        let presentation = present(row(status: .unknown, orderId: nil))

        #expect(presentation.reasonText == OrderMessages.unconfirmed)
        #expect(OrderMessages.unconfirmed.contains("not answered"))
        #expect(OrderMessages.unconfirmed.contains("same order id"))
        #expect(OrderMessages.unconfirmed.contains("second order"))
    }

    @Test func everyOtherStatusHasNothingToExplain() {
        let others: [OrderStatus] = [.pending, .accepted, .partiallyFilled, .filled]
        for status in others {
            #expect(present(row(status: status)).reasonText == nil, "\(status)")
            #expect(present(row(status: status, reason: .invalidLot)).reasonText == nil, "\(status), a stray reason")
        }
    }

    @Test func theSpokenSummaryNamesTheOrderItsProgressAndItsReason() {
        let working = present(row(status: .partiallyFilled, type: .limit, limit: 3_425, filled: 30, average: 3_420))
        #expect(
            working.accessibilityText
                == "Buy PTT, limit 34.25, 30 of 100 shares, average price 34.20, Partly filled"
        )

        let market = present(row(status: .pending))
        #expect(market.accessibilityText == "Buy PTT, market, 0 of 100 shares, Sending")

        let rejected = present(row(status: .rejected, side: .sell, reason: .insufficientPosition))
        #expect(
            rejected.accessibilityText
                == "Sell PTT, market, 0 of 100 shares, Rejected. \(OrderMessages.text(for: .insufficientPosition))"
        )
    }

    @Test func twoPresentationsOfTheSameOrderAreEqualAndAChangeShows() {
        let one = present(row(status: .accepted))
        let same = present(row(status: .accepted))
        let moved = present(row(status: .partiallyFilled, filled: 30, average: 3_425))

        #expect(one == same)
        #expect(one != moved)
        #expect(one != present(row(status: .accepted), connected: false))
    }

    // MARK: The sentences for the reasons

    @Test func everyReasonHasItsOwnSentenceInPlainEnglish() {
        let texts = allReasons.map { OrderMessages.text(for: $0) }

        #expect(texts.count == 9)
        #expect(RejectReason(rawValue: 0) == nil)
        #expect(RejectReason(rawValue: 10) == nil, "a tenth reason needs a sentence and an entry in this table")
        #expect(!texts.contains(""))
        #expect(Set(texts).count == 9, "no two reasons share a sentence")
        for (reason, text) in zip(allReasons, texts) {
            #expect(!text.contains(String(describing: reason)), "\(reason): \(text)")
            let camelCase = zip(text, text.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
            #expect(!camelCase, "\(reason): \(text) has a word only the code uses")
            #expect(text.first?.isUppercase == true, "\(reason): \(text)")
            #expect(text.hasSuffix("."), "\(reason): \(text)")
        }
    }

    @Test func eachReasonSaysWhatIsWrong() {
        let facts: [(reason: RejectReason, words: [String])] = [
            (.invalidQuantity, ["100", "10,000,000", "shares"]),
            (.invalidLot, ["multiple of 100 shares"]),
            (.invalidTick, ["price step"]),
            (.outsidePriceBand, ["30%", "reference price"]),
            (.insufficientFunds, ["cash"]),
            (.insufficientPosition, ["shares"]),
            (.unknownSymbol, ["symbol"]),
            (.noLiquidity, ["No shares were available"]),
            (.invalidDuplicate, ["order id was already used", "different order"]),
        ]
        #expect(facts.count == 9)
        for fact in facts {
            let text = OrderMessages.text(for: fact.reason)
            for word in fact.words {
                #expect(text.contains(word), "\(fact.reason): \(text) should say \(word.debugDescription)")
            }
        }
    }

    @Test func theTicketBuildsItsDetailedSentencesOnTheBaseSentenceOfTheSameReason() {
        let band = satang(2_397)...satang(4_452)

        let step = OrderMessages.priceStep(satang(25))
        #expect(step.hasPrefix(OrderMessages.text(for: .invalidTick)))
        #expect(step.contains("0.25 at this price level"))

        let range = OrderMessages.priceBand(reference: satang(3_425), band: band)
        #expect(range.hasPrefix(OrderMessages.text(for: .outsidePriceBand)))
        #expect(range.contains("within 30% of 34.25: 23.97 to 44.52"))

        let fixed = [
            OrderMessages.enterQuantity, OrderMessages.quantityDigitsOnly, OrderMessages.quantityTooLarge,
            OrderMessages.enterPrice, OrderMessages.priceShape, OrderMessages.priceAboveZero,
        ]
        #expect(fixed.count == 6)
        #expect(!fixed.contains(""))
        #expect(Set(fixed).count == 6)
        #expect(OrderMessages.priceShape.contains("34.25"))
        #expect(OrderMessages.priceShape.contains("at most two decimals"))
        #expect(OrderMessages.priceAboveZero.contains("above zero"))
        #expect(OrderMessages.enterQuantity.contains("quantity"))
        #expect(OrderMessages.enterPrice.contains("limit price"))
    }

    // MARK: Shares and tickers

    @Test func sharesAreWrittenWithCommasAndNoLocale() {
        let table: [(shares: Int64, text: String)] = [
            (0, "0"), (7, "7"), (100, "100"), (999, "999"), (1_000, "1,000"), (12_345, "12,345"),
            (123_456, "123,456"), (1_234_567, "1,234,567"), (10_000_000, "10,000,000"),
            (Int64.max, "9,223,372,036,854,775,807"), (-1, "-1"), (-1_234, "-1,234"),
            (Int64.min, "-9,223,372,036,854,775,808"),
        ]
        #expect(table.count == 13)
        for entry in table {
            #expect(ShareFormat.grouped(entry.shares) == entry.text, "\(entry.shares)")
        }
    }

    @Test func aTickerIsLookedUpByIdAndAnUnknownOneShowsItsId() {
        #expect(sampleSymbols.ticker(for: 4) == "PTT")
        #expect(sampleSymbols.ticker(for: 2) == "AOT")
        #expect(sampleSymbols.ticker(for: 9) == "CPALL")
        #expect(sampleSymbols.ticker(for: 12) == "#12")
        #expect(sampleSymbols.ticker(for: 0) == "#0")
        #expect(sampleSymbols.ticker(for: UInt32.max) == "#4294967295")
        #expect([SymbolDTO]().ticker(for: 4) == "#4")
    }
}

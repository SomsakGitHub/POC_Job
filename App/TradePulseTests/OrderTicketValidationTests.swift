import Contracts
import Testing
import TradeCore
@testable import TradePulse

/// What the ticket accepts in its two text fields and what it says when it refuses: how the quantity and the price are
/// read, and the one sentence that tells the first thing wrong with the form. Whatever is typed, nothing traps.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OrderTicketValidationTests {
    /// PTT's reference price, 34.25, in satang: the band is 23.97 to 44.52.
    private let reference: Int64 = 3_425

    // MARK: Reading the quantity

    @Test func theQuantityIsReadAsAsciiDigitsAndNothingElse() {
        let thirtyZeros = String(repeating: "0", count: 30)
        let cases: [(text: String, expected: QuantityParse)] = [
            ("", .empty), ("   ", .empty), ("\t\n", .empty),
            ("abc", .notDigits), ("1e3", .notDigits), ("-100", .notDigits), ("+100", .notDigits),
            ("100.5", .notDigits), ("1 000", .notDigits), ("1,000", .notDigits), ("0x10", .notDigits),
            ("๑๐๐", .notDigits), ("１００", .notDigits), ("١٠٠", .notDigits),
            ("100\r", .notDigits), ("\u{00A0}100", .notDigits), ("\u{3000}100", .notDigits),
            ("1\u{200B}00", .notDigits),
            ("0", .value(0)), ("50", .value(50)), ("150", .value(150)), ("100", .value(100)), ("0100", .value(100)),
            (" 100 ", .value(100)), ("\t100\n", .value(100)), ("10000100", .value(10_000_100)),
            ("10000000", .value(10_000_000)), (thirtyZeros + "100", .value(100)),
            ("9223372036854775807", .value(Int64.max)),
            ("9223372036854775808", .tooLarge), ("99999999999999999999999", .tooLarge),
            ("99999999999999999999999x", .notDigits), ("x99999999999999999999999", .notDigits),
        ]
        #expect(cases.count == 33)
        for (text, expected) in cases {
            let parsed = OrderTicketViewModel.parseQuantity(text)
            #expect(parsed == expected, "\(text.debugDescription)")
        }
    }

    // MARK: Reading the price

    @Test func thePriceIsReadByThePriceParserAfterTwoChangesThatMakeTypingWork() {
        let cases: [(text: String, expected: PriceParse)] = [
            ("", .empty), ("  ", .empty), (".", .empty), (" . ", .empty),
            ("34.25", .value(satang(3_425))), (" 34.25 ", .value(satang(3_425))), ("34", .value(satang(3_400))),
            ("34.2", .value(satang(3_420))), ("34.", .value(satang(3_400))), (".5", .value(satang(50))),
            (".50", .value(satang(50))), ("0.5", .value(satang(50))), ("0", .value(satang(0))),
            ("0.00", .value(satang(0))), ("0.", .value(satang(0))),
            ("92233720368547758.07", .value(satang(Int64.max))),
            ("34.256", .unreadable), ("34,25", .unreadable), ("1e3", .unreadable), ("-5", .unreadable),
            ("+34", .unreadable), ("1,000", .unreadable), ("๓๔.๒๕", .unreadable), ("３４.２５", .unreadable),
            ("3.4.5", .unreadable), ("34..", .unreadable), ("..5", .unreadable), ("34.5.", .unreadable),
            (".5.", .unreadable), ("34 .25", .unreadable), ("3 4", .unreadable), ("34.25\r", .unreadable),
            ("99999999999999999999", .unreadable), ("92233720368547758.08", .unreadable),
        ]
        #expect(cases.count == 34)
        for (text, expected) in cases {
            let parsed = OrderTicketViewModel.parsePrice(text)
            #expect(parsed == expected, "\(text.debugDescription)")
        }
    }

    // MARK: The message for the quantity

    @Test func everyQuantityTheTicketRefusesGetsItsMessageAndNoOneCanSendIt() {
        let refused: [(text: String, message: String)] = [
            ("", OrderMessages.enterQuantity),
            ("abc", OrderMessages.quantityDigitsOnly), ("1e3", OrderMessages.quantityDigitsOnly),
            ("-100", OrderMessages.quantityDigitsOnly), ("100.5", OrderMessages.quantityDigitsOnly),
            ("+100", OrderMessages.quantityDigitsOnly), ("1 000", OrderMessages.quantityDigitsOnly),
            ("1,000", OrderMessages.quantityDigitsOnly), ("๑๐๐", OrderMessages.quantityDigitsOnly),
            ("１００", OrderMessages.quantityDigitsOnly),
            ("99999999999999999999999", OrderMessages.quantityTooLarge),
            ("0", OrderMessages.text(for: .invalidQuantity)), ("10000100", OrderMessages.text(for: .invalidQuantity)),
            ("50", OrderMessages.text(for: .invalidLot)), ("150", OrderMessages.text(for: .invalidLot)),
        ]
        let accepted = [" 100 ", "0100", "100", "200", "10000000"]
        #expect(refused.count == 15)
        #expect(accepted.count == 5)
        let rig = TicketRig()
        for (text, message) in refused {
            rig.model.quantityText = text
            #expect(rig.model.validationMessage == message, "\(text.debugDescription)")
            #expect(!rig.model.canSubmit(tradingConnected: true), "\(text.debugDescription)")
        }
        for text in accepted {
            rig.model.quantityText = text
            #expect(rig.model.validationMessage == nil, "\(text.debugDescription)")
            #expect(rig.model.canSubmit(tradingConnected: true), "\(text.debugDescription)")
        }
    }

    @Test func theMessagesForTheQuantityNameTheLimits() {
        #expect(OrderMessages.text(for: .invalidLot).contains("100"))
        #expect(OrderMessages.text(for: .invalidQuantity).contains("100"))
        #expect(OrderMessages.text(for: .invalidQuantity).contains("10,000,000"))
        #expect(OrderMessages.quantityTooLarge.contains("10,000,000"))
        #expect(OrderMessages.quantityDigitsOnly.contains("0-9"))
        #expect(OrderMessages.quantityDigitsOnly.contains("whole shares"))
    }

    // MARK: The message for the price

    @Test func everyPriceTheTicketRefusesGetsItsMessage() {
        let band = satang(2_397)...satang(4_452)
        let refused: [(text: String, message: String)] = [
            ("", OrderMessages.enterPrice), (".", OrderMessages.enterPrice), ("  ", OrderMessages.enterPrice),
            ("34.256", OrderMessages.priceShape), ("34,25", OrderMessages.priceShape),
            ("1e3", OrderMessages.priceShape), ("-5", OrderMessages.priceShape),
            ("99999999999999999999", OrderMessages.priceShape), ("3.4.5", OrderMessages.priceShape),
            ("๓๔.๒๕", OrderMessages.priceShape),
            ("0", OrderMessages.priceAboveZero), ("0.00", OrderMessages.priceAboveZero),
            ("0.", OrderMessages.priceAboveZero),
            ("44.52", OrderMessages.priceStep(satang(25))), ("34.26", OrderMessages.priceStep(satang(25))),
            ("44.75", OrderMessages.priceBand(reference: satang(reference), band: band)),
            (".5", OrderMessages.priceBand(reference: satang(reference), band: band)),
            ("23.90", OrderMessages.priceBand(reference: satang(reference), band: band)),
        ]
        let accepted = ["34.25", " 34.25 ", "34.", "34", "44.50", "24.00", "24"]
        #expect(refused.count == 18)
        #expect(accepted.count == 7)
        let rig = TicketRig()
        rig.model.type = .limit
        for (text, message) in refused {
            rig.model.priceText = text
            #expect(rig.model.validationMessage == message, "\(text.debugDescription)")
            #expect(!rig.model.canSubmit(tradingConnected: true), "\(text.debugDescription)")
        }
        for text in accepted {
            rig.model.priceText = text
            #expect(rig.model.validationMessage == nil, "\(text.debugDescription)")
            #expect(rig.model.canSubmit(tradingConnected: true), "\(text.debugDescription)")
        }
    }

    @Test func theStepMessageSaysThatTheStepHoldsAtThatPriceLevel() {
        let rig = TicketRig()
        rig.model.type = .limit
        rig.model.priceText = "44.52"

        let message = rig.model.validationMessage

        #expect(message?.contains("0.25 at this price level") == true)
    }

    @Test func theBandMessageNamesTheReferenceAndTheTwoEdges() {
        let rig = TicketRig()
        rig.model.type = .limit
        rig.model.priceText = "50"

        let message = rig.model.validationMessage

        #expect(message?.contains("within 30% of 34.25: 23.97 to 44.52") == true)
    }

    @Test func theStepInTheMessageIsTheStepAtTheTypedPrice() throws {
        // At 5,000.00 baht the step is 2.00, and at 3.00 baht it is 0.02. PTT's reference of 34.25 has a step of 0.25,
        // but a price of 24.99 is below 25.00 and has a step of 0.10: the step is the one at the price that was typed.
        let dear = SymbolDTO(id: 1, ticker: "DEAR", nameTh: "", nameEn: "", reference: 500_000, lot: 100)
        let cheap = SymbolDTO(id: 2, ticker: "CHEAP", nameTh: "", nameEn: "", reference: 300, lot: 100)
        let steps: [(symbol: SymbolDTO, price: String, stepText: String, step: Int64)] = [
            (dear, "5000.01", "2.00", 200), (cheap, "3.01", "0.02", 2), (sampleSymbols[0], "24.99", "0.10", 10),
        ]
        #expect(steps.count == 3)
        for (symbol, price, stepText, step) in steps {
            let rig = TicketRig(symbol: symbol)
            rig.model.type = .limit
            rig.model.priceText = price
            let message = try #require(rig.model.validationMessage, "\(price)")
            #expect(message.contains(stepText), "\(price): \(message)")
            #expect(message == OrderMessages.priceStep(satang(step)), "\(price)")
        }
    }

    // MARK: Which problem is told first

    @Test func theProblemsAreToldInTheOrderOfTheFieldsThenTheRules() {
        let rig = TicketRig()
        rig.model.type = .limit

        // A quantity that cannot be read comes before a price that cannot be read.
        rig.model.quantityText = "abc"
        rig.model.priceText = "xyz"
        #expect(rig.model.validationMessage == OrderMessages.quantityDigitsOnly)

        // Both texts are read before any rule is applied: an empty price is told before a quantity off the lot.
        rig.model.quantityText = "150"
        rig.model.priceText = ""
        #expect(rig.model.validationMessage == OrderMessages.enterPrice)
        rig.model.priceText = "34.256"
        #expect(rig.model.validationMessage == OrderMessages.priceShape)

        // The rules go in the order of the exchange: the quantity before the price.
        rig.model.priceText = "44.52"
        #expect(rig.model.validationMessage == OrderMessages.text(for: .invalidLot))
        rig.model.priceText = "0"
        #expect(rig.model.validationMessage == OrderMessages.text(for: .invalidLot))

        // With the quantity right, the same prices are told for what they are.
        rig.model.quantityText = "100"
        #expect(rig.model.validationMessage == OrderMessages.priceAboveZero)
        rig.model.priceText = "44.52"
        #expect(rig.model.validationMessage == OrderMessages.priceStep(satang(25)))
    }

    @Test func aMarketOrderNeverReadsThePriceField() {
        let rig = TicketRig()
        rig.model.type = .market
        for text in ["", "garbage", "-5", "0", "99999999999999999999", "44.52"] {
            rig.model.priceText = text
            #expect(rig.model.validationMessage == nil, "\(text.debugDescription)")
            #expect(rig.model.canSubmit(tradingConnected: true), "\(text.debugDescription)")
        }

        // The control: the same texts are refused once the order is a limit order.
        rig.model.type = .limit
        rig.model.priceText = "garbage"
        #expect(rig.model.validationMessage == OrderMessages.priceShape)
    }

    @Test func theFormStartsOnAMarketOrderOfOneLotAndSaysNothing() {
        let rig = TicketRig()

        #expect(rig.model.quantityText == "100")
        #expect(rig.model.priceText == "")
        #expect(rig.model.type == .market)
        #expect(rig.model.side == .buy)
        #expect(rig.model.validationMessage == nil)
        #expect(TicketRig(side: .sell).model.side == .sell)
    }

    // MARK: A message is never missing

    @Test func noTextTrapsAndEveryRefusalHasWords() {
        let texts = [
            "", " ", ".", "..", "-", "+", "0", "00", "1e3", "NaN", "inf", "9", "99999999999999999999999999",
            "🙂", "100\u{0000}", "１", "٣", "34.25.25", "0.", ".0", "-0", "1e-3", String(repeating: "9", count: 400),
        ]
        #expect(texts.count == 23)
        let rig = TicketRig()
        var refusals = 0
        for text in texts {
            for type in [OrderType.market, .limit] {
                rig.model.type = type
                rig.model.quantityText = text
                rig.model.priceText = text
                let message = rig.model.validationMessage
                if let message {
                    refusals += 1
                    #expect(!message.isEmpty, "\(text.debugDescription)")
                }
                let hint = rig.model.balanceHint
                let estimate = rig.model.estimatedCost
                #expect(!estimate.isEmpty, "\(text.debugDescription) \(String(describing: hint))")
            }
        }
        #expect(refusals == texts.count * 2, "the control: every text is refused, so every message was read")
    }
}

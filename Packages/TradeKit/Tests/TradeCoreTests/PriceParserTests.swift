import Testing
import TradeCore

struct PriceParserTests {
    @Test func parsesWholeAndFractionalBaht() {
        #expect(PriceParser.parse("34") == Price(satang: 3400))
        #expect(PriceParser.parse("34.2") == Price(satang: 3420))
        #expect(PriceParser.parse("34.25") == Price(satang: 3425))
    }

    @Test(arguments: [
        ("0", 0),
        ("0.0", 0),
        ("0.00", 0),
        ("0.05", 5),
        ("0.5", 50),
        ("0.50", 50),
        ("34.00", 3400),
        ("34.20", 3420),
        ("100", 10_000),
        ("100.05", 10_005),
        // Leading zeros are digits like any other and never count towards overflow.
        ("007", 700),
        ("0000000000000000000000000000000034", 3400),
    ] as [(String, Int64)])
    func acceptedForms(text: String, satang: Int64) {
        #expect(PriceParser.parse(text) == Price(satang: satang))
    }

    /// Strict grammar: `digit+ ("." digit{1,2})?`. Nothing else is a price, so nothing is guessed.
    @Test(arguments: [
        "",             // empty
        "-1",           // signs
        "+1",
        "-",
        "34.256",       // more than two fraction digits
        "34.250",       // ... even when the extra digit is a zero
        "abc",
        "1e3",          // exponents
        "1E3",
        "0x10",
        " 34",          // whitespace anywhere
        "34 ",
        "3 4",
        "34\n",
        "\t34",
        "34.",          // borderline: a dot must be followed by a fraction digit
        ".5",           // borderline: a dot must be preceded by a whole digit
        ".",
        "..",
        "3.4.5",        // a second dot
        "34..5",
        "34,25",        // a comma is not a decimal separator
        "1,000",        // and not a grouping separator
        "34.2a",
        "3_4",
        "٣٤",           // Arabic-Indic digits: digits, but not ASCII
        "３４",          // full-width digits
        "34\u{0301}",   // a digit plus a combining mark
        "34\0",
    ])
    func rejectedForms(text: String) {
        #expect(PriceParser.parse(text) == nil)
    }

    /// Int64.max satang is 92,233,720,368,547,758.07 baht.
    @Test func overflowIsNilNotATrap() {
        #expect(PriceParser.parse("92233720368547758.07") == Price(satang: .max))
        #expect(PriceParser.parse("92233720368547758.08") == nil)   // one satang too many
        #expect(PriceParser.parse("92233720368547758") == Price(satang: 9_223_372_036_854_775_800))
        #expect(PriceParser.parse("92233720368547759") == nil)      // whole baht overflow after scaling to satang
        #expect(PriceParser.parse("9223372036854775808") == nil)    // does not fit even before scaling
        #expect(PriceParser.parse("99999999999999999999999999999999999999") == nil)
        #expect(PriceParser.parse(String(repeating: "9", count: 10_000)) == nil)
        #expect(PriceParser.parse(String(repeating: "9", count: 10_000) + ".99") == nil)
    }

    @Test func roundTripsThroughDescription() {
        for satang: Int64 in [0, 1, 5, 50, 3400, 3425, 10_005, 99_999, 123_456_789, .max] {
            let price = Price(satang: satang)
            #expect(PriceParser.parse(price.description) == price)
        }
    }
}

import Testing
import TradeCore

struct MoneyFormatTests {
    @Test func formatsBahtWithGroupingAndTwoDecimals() {
        #expect(MoneyFormat.baht(satang: 100_000_000) == "฿1,000,000.00")
        #expect(MoneyFormat.baht(satang: -50_000) == "-฿500.00")
        #expect(MoneyFormat.baht(satang: 5) == "฿0.05")
    }

    @Test(arguments: [
        (0, "฿0.00"),          // zero has no sign
        (1, "฿0.01"),
        (-1, "-฿0.01"),
        (99, "฿0.99"),
        (100, "฿1.00"),
        (99_999, "฿999.99"),   // last amount before the first grouping separator
        (100_000, "฿1,000.00"),
        (-100_000, "-฿1,000.00"),
        (123_456_789, "฿1,234,567.89"),
        (99_999_999, "฿999,999.99"),
        // The extremes must not trap, and must keep the sign outside the symbol.
        (Int64.max, "฿92,233,720,368,547,758.07"),
        (Int64.min + 1, "-฿92,233,720,368,547,758.07"),
        (Int64.min, "-฿92,233,720,368,547,758.08"),
    ] as [(Int64, String)])
    func formatsAcrossTheRange(satang: Int64, expected: String) {
        #expect(MoneyFormat.baht(satang: satang) == expected)
    }

    /// U+0E3F THAI CURRENCY SYMBOL BAHT, not U+20BF (the bitcoin sign) or a look-alike.
    @Test func usesTheThaiBahtSign() {
        let text = MoneyFormat.baht(satang: 12_345)
        #expect(text.unicodeScalars.first?.value == 0x0E3F)
        #expect(MoneyFormat.baht(satang: -12_345).unicodeScalars.dropFirst().first?.value == 0x0E3F)
    }
}

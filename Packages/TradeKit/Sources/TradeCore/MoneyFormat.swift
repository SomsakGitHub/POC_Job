/// Money as text, for the UI edge. Integer arithmetic only, and fixed separators ("," between groups of three
/// digits, "." before the satang), never the current locale's.
public enum MoneyFormat: Sendable {
    /// Thai baht text for an amount in satang: "฿1,000,000.00", "-฿500.00", "฿0.05".
    ///
    /// The sign goes in front of the symbol and zero has none. Total over `Int64`: the magnitude is taken as
    /// `UInt64` instead of negating, so `Int64.min` is "-฿92,233,720,368,547,758.08" and `Int64.max`
    /// is "฿92,233,720,368,547,758.07".
    public static func baht(satang: Int64) -> String {
        (satang < 0 ? "-" : "") + bahtSign + decimal(hundredths: satang.magnitude, grouped: true)
    }

    /// Decimal text for a count of hundredths with exactly two fraction digits: 3425 -> "34.25", 5 -> "0.05".
    ///
    /// The shared core of `baht(satang:)`, `Price.description` and `PriceChange.percentText` (a basis point is a
    /// hundredth of a percent). It takes the magnitude so no caller ever negates a signed integer; the sign is theirs.
    static func decimal(hundredths: UInt64, grouped: Bool) -> String {
        let whole = String(hundredths / 100)
        let fraction = hundredths % 100
        return (grouped ? groupingThousands(whole) : whole) + (fraction < 10 ? ".0" : ".") + String(fraction)
    }

    /// U+0E3F THAI CURRENCY SYMBOL BAHT.
    private static let bahtSign = "\u{0E3F}"

    /// "1000000" -> "1,000,000". `digits` is ASCII digits only.
    private static func groupingThousands(_ digits: String) -> String {
        var grouped = ""
        var remaining = digits.utf8.count
        for digit in digits {
            if remaining % 3 == 0, !grouped.isEmpty {
                grouped.append(",")
            }
            grouped.append(digit)
            remaining -= 1
        }
        return grouped
    }
}

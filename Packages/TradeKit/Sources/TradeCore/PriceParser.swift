/// Turns typed text into a `Price`. Strict: it accepts one grammar and nothing else, so nothing is guessed.
public enum PriceParser: Sendable {
    /// `text` as baht to satang, or nil if it is not a price.
    ///
    /// The grammar is `digit+ ("." digit{1,2})?` with ASCII digits only: "34" is 3400, "34.2" is 3420 and "34.25"
    /// is 3425. Everything else is nil: the empty string, signs, whitespace, exponents ("1e3"), grouping
    /// separators ("1,000"), non-ASCII digits, a third fraction digit ("34.256", "34.250") and a second dot.
    ///
    /// Two borderline forms are rejected on purpose: "34." (a dot needs a fraction digit after it) and ".5"
    /// (a dot needs a whole digit before it). A caller that wants to be lenient while the user types can
    /// normalise first ("34." to "34", ".5" to "0.5").
    ///
    /// The syntax is all it checks: "0" parses to a zero price, which `TickRules` then refuses. A value that does not
    /// fit in `Int64` satang (more than 92,233,720,368,547,758.07 baht) is nil, however long the digit string.
    public static func parse(_ text: String) -> Price? {
        var digits: Int64 = 0  // every digit, whole and fraction alike, as one number
        var wholeCount = 0
        var fractionCount = 0
        var seenPoint = false

        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                if seenPoint {
                    guard fractionCount < 2 else { return nil }
                    fractionCount += 1
                } else {
                    wholeCount += 1
                }
                let (shifted, shiftOverflow) = digits.multipliedReportingOverflow(by: 10)
                let (next, addOverflow) = shifted.addingReportingOverflow(Int64(byte - UInt8(ascii: "0")))
                guard !shiftOverflow, !addOverflow else { return nil }
                digits = next
            case UInt8(ascii: "."):
                guard !seenPoint else { return nil }
                seenPoint = true
            default:
                return nil
            }
        }

        guard wholeCount > 0, !seenPoint || fractionCount > 0 else { return nil }

        // Scale to two fraction digits: "34" has none (x100), "34.2" has one (x10), "34.25" has two (x1).
        var satang = digits
        for _ in fractionCount..<2 {
            let (scaled, overflow) = satang.multipliedReportingOverflow(by: 10)
            guard !overflow else { return nil }
            satang = scaled
        }
        return Price(satang: satang)
    }
}

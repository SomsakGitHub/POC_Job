import TradeCore

/// What the quantity field's text means.
enum QuantityParse: Equatable {
    /// A whole number of shares.
    case value(Quantity)
    /// Nothing but white space.
    case empty
    /// Something that is not only the digits 0 to 9.
    case notDigits
    /// Only digits, but too many for any number of shares the app can hold.
    case tooLarge
}

/// What the price field's text means.
enum PriceParse: Equatable {
    /// A price.
    case value(Price)
    /// Nothing but white space, or a lone dot: the price has not been typed yet.
    case empty
    /// Text that is not a price.
    case unreadable
}

/// Reading the two text fields of the order ticket. These are plain functions of the text, so they need no ticket.
extension OrderTicketViewModel {
    /// Reads the quantity field. Leading and trailing space, tab and line feed are ignored and nothing else is
    /// cleaned: the rest must be one or more ASCII digits, so a sign, a dot, an exponent, a separator, a space inside,
    /// and the digits of other scripts (Thai, full-width) are all `.notDigits`. Leading zeros are fine. A digit string
    /// that does not fit in `Int64` is `.tooLarge`, never a trap.
    nonisolated static func parseQuantity(_ text: String) -> QuantityParse {
        let bytes = trimmed(text)
        guard !bytes.isEmpty else { return .empty }
        var value: Int64 = 0
        var overflowed = false
        // Every byte is looked at before an overflow is decided, so a long string with a letter at its end is not
        // a number that is too large but text that is not a number.
        for byte in bytes {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return .notDigits }
            let (shifted, shiftOverflow) = value.multipliedReportingOverflow(by: 10)
            let (next, addOverflow) = shifted.addingReportingOverflow(Int64(byte - UInt8(ascii: "0")))
            if shiftOverflow || addOverflow {
                overflowed = true
            } else {
                value = next
            }
        }
        return overflowed ? .tooLarge : .value(value)
    }

    /// Reads the price field with `PriceParser` after the two changes that make typing work: a leading dot gets a zero
    /// in front (".5" reads as "0.5") and a trailing dot is dropped ("34." reads as "34"). Leading and trailing space,
    /// tab and line feed are ignored first. Nothing else is cleaned, so what the parser refuses stays refused.
    nonisolated static func parsePrice(_ text: String) -> PriceParse {
        var bytes = Array(trimmed(text))
        guard !bytes.isEmpty else { return .empty }
        let dot = UInt8(ascii: ".")
        // Only a text with exactly one dot is changed: a second dot is a mistake the parser must still refuse.
        if bytes.filter({ $0 == dot }).count == 1 {
            if bytes.count == 1 {
                return .empty
            } else if bytes.first == dot {
                bytes.insert(UInt8(ascii: "0"), at: 0)
            } else if bytes.last == dot {
                bytes.removeLast()
            }
        }
        guard let price = PriceParser.parse(String(decoding: bytes, as: UTF8.self)) else { return .unreadable }
        return .value(price)
    }

    /// The bytes of `text` without the space, tab and line feed at its two ends.
    private nonisolated static func trimmed(_ text: String) -> ArraySlice<UInt8> {
        let blanks: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n")]
        let bytes = Array(text.utf8)
        var start = 0
        var end = bytes.count
        while start < end, blanks.contains(bytes[start]) { start += 1 }
        while end > start, blanks.contains(bytes[end - 1]) { end -= 1 }
        return bytes[start..<end]
    }
}

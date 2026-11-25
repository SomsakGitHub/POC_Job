import Contracts
import TradeCore

/// How a number of shares is written on screen.
enum ShareFormat {
    /// `shares` with a comma between groups of three digits and no locale in it: "0", "100", "10,000,000". A negative
    /// number keeps its sign, and every `Int64` can be written.
    static func grouped(_ shares: Quantity) -> String {
        // The magnitude is taken as `UInt64`, so `Int64.min` is never negated.
        let digits = String(shares.magnitude)
        var grouped = shares < 0 ? "-" : ""
        var remaining = digits.utf8.count
        for digit in digits {
            if remaining % 3 == 0, remaining != digits.utf8.count {
                grouped.append(",")
            }
            grouped.append(digit)
            remaining -= 1
        }
        return grouped
    }
}

/// Looking up a symbol's name in the list the server sent.
extension [SymbolDTO] {
    /// The ticker of the symbol with `id`, or "#" and the id (for example "#12") when the list does not have it. A
    /// screen that shows an order or a position of a symbol the app does not know still shows which one it is.
    func ticker(for id: UInt32) -> String {
        first { $0.id == id }?.ticker ?? "#\(id)"
    }
}

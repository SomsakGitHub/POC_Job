/// A price or a money amount in satang, the smallest unit: 1 THB = 100 satang.
///
/// Money is `Int64` satang everywhere in TradePulse (no `Double`, no `Decimal`); this wrapper adds ordering,
/// text and the notional multiply. No operation on it traps or wraps for any `Int64` value, `Int64.min` included.
public struct Price: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var satang: Int64

    public init(satang: Int64) {
        self.satang = satang
    }

    public static func < (lhs: Price, rhs: Price) -> Bool {
        lhs.satang < rhs.satang
    }

    /// Baht with exactly two decimals, no grouping and no currency symbol: "34.25", "0.01", "-0.50".
    /// (`MoneyFormat.baht` is the display form.) The magnitude is formatted as `UInt64`, so `Int64.min`
    /// is never negated: it reads "-92233720368547758.08".
    public var description: String {
        (satang < 0 ? "-" : "") + MoneyFormat.decimal(hundredths: satang.magnitude, grouped: false)
    }

    /// `satang * quantity`: the value of `quantity` shares at this price, in satang; nil if it does not fit in `Int64`.
    /// Plain checked multiplication. The quantity is not validated here (see `TickRules.validate`), so a negative
    /// quantity gives a negative amount.
    public func notional(quantity: Quantity) -> Int64? {
        let (product, overflow) = satang.multipliedReportingOverflow(by: quantity)
        return overflow ? nil : product
    }
}

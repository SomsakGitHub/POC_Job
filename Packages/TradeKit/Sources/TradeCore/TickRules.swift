/// The market rules the simulated exchange enforces and the order ticket pre-checks: board lot, tick size, price band
/// and order size. They are simulation parameters modelled on SET, not claims about the real exchange's rules.
///
/// Integer arithmetic only. Nothing here traps or overflows for any `Int64` input; the degenerate inputs
/// (zero or negative prices, huge references) are answered, not crashed on.
public enum TickRules: Sendable {
    /// Orders are a whole number of board lots, in shares.
    public static let boardLot: Quantity = 100

    /// The largest accepted order, in shares.
    public static let maxOrderQuantity: Quantity = 10_000_000

    /// The price step at `price`: 1 satang below 200, then 2 (from 200), 5 (500), 10 (1,000), 25 (2,500),
    /// 50 (10,000), 100 (20,000) and 200 satang from 40,000 (400.00 baht) up.
    ///
    /// A price of zero or less is in the first tier and gets 1; such a price is never valid (see `isOnTick`).
    public static func tickSize(at price: Price) -> Price {
        switch price.satang {
        case ..<200: Price(satang: 1)
        case ..<500: Price(satang: 2)
        case ..<1000: Price(satang: 5)
        case ..<2500: Price(satang: 10)
        case ..<10_000: Price(satang: 25)
        case ..<20_000: Price(satang: 50)
        case ..<40_000: Price(satang: 100)
        default: Price(satang: 200)
        }
    }

    /// Whether `price` is a positive whole multiple of the tick size at that price.
    /// Zero and negative prices are never on a tick.
    public static func isOnTick(_ price: Price) -> Bool {
        price.satang > 0 && price.satang % tickSize(at: price).satang == 0
    }

    /// The prices a limit order may name: `floor(reference * 70 / 100)` through `floor(reference * 130 / 100)`,
    /// both inclusive (+/-30%).
    ///
    /// The products are formed in `Int128`, so a huge reference cannot overflow; an upper edge above `Int64.max`
    /// saturates there. A reference of zero or less has no meaningful band: the result is the degenerate range
    /// `0...0`, which no positive price is in.
    public static func band(reference: Price) -> ClosedRange<Price> {
        guard reference.satang > 0 else {
            return Price(satang: 0)...Price(satang: 0)
        }
        return percentOf(reference, 70)...percentOf(reference, 130)
    }

    /// The first rule an order breaks, or nil if it is acceptable. The checks run in this order and the first
    /// failure wins:
    /// 1. `invalidQuantity`: `quantity` is not in `1...maxOrderQuantity`.
    /// 2. `invalidLot`: `quantity` is not a multiple of `boardLot`.
    /// 3. `invalidTick` (limit orders only): `limit` is nil, zero or negative, or not on a tick.
    /// 4. `outsidePriceBand` (limit orders only): `limit` is outside `band(reference:)`.
    ///
    /// A market order has no price: whatever `limit` holds is ignored.
    public static func validate(
        type: OrderType, quantity: Quantity, limit: Price?, reference: Price
    ) -> RejectReason? {
        guard (1...maxOrderQuantity).contains(quantity) else { return .invalidQuantity }
        guard quantity % boardLot == 0 else { return .invalidLot }
        switch type {
        case .market:
            return nil
        case .limit:
            guard let limit, isOnTick(limit) else { return .invalidTick }
            guard band(reference: reference).contains(limit) else { return .outsidePriceBand }
            return nil
        }
    }

    /// `reference * percent / 100`, floored (the reference is positive), saturating at `Int64.max`.
    private static func percentOf(_ reference: Price, _ percent: Int128) -> Price {
        Price(satang: Int64(clamping: Int128(reference.satang) * percent / 100))
    }
}

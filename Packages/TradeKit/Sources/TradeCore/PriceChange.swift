/// How far the last price has moved from the reference (the previous close), as an amount and as a percentage.
///
/// Integer arithmetic only. `basisPoints` is the move as a share of the reference, rounded to the NEAREST basis
/// point (1 bp = 0.01%), ties away from zero: 3450 against 3425 is 72.99 bp and reads "+0.73%"; truncating
/// would give "+0.72%".
///
/// Without a positive reference there is nothing to measure against, so the change is reported as nothing: `delta`
/// 0, 0 bp, "0.00%" and `.flat`. (For example, a client whose reference price has not arrived yet: this keeps the
/// whole price from showing up as a gain.)
///
/// Total over `Int64`: the difference is formed in `Int128`, `delta` saturates at the `Int64` bounds, and
/// `basisPoints` saturates at the `Int` bounds (it is exact unless the move is over 9.2e14 times the reference).
public struct PriceChange: Sendable {
    public enum Direction: Sendable {
        case up
        case down
        case flat
    }

    /// `last - reference`, saturating at the `Int64` bounds. Zero without a positive reference.
    public let delta: Price

    /// `delta` as a share of the reference in basis points, rounded to the nearest, ties away from zero.
    /// Zero without a positive reference.
    public let basisPoints: Int

    public init(last: Price, reference: Price) {
        guard reference.satang > 0 else {
            delta = Price(satang: 0)
            basisPoints = 0
            return
        }
        let difference = Int128(last.satang) - Int128(reference.satang)
        delta = Price(satang: Int64(clamping: difference))
        basisPoints = Int(clamping: Self.roundedBasisPoints(of: difference, over: Int128(reference.satang)))
    }

    /// The sign of `basisPoints`, so the arrow always agrees with `percentText`. A move under half a basis point
    /// reads "0.00%" and `.flat`; the exact difference is still in `delta`.
    public var direction: Direction {
        basisPoints > 0 ? .up : (basisPoints < 0 ? .down : .flat)
    }

    /// `basisPoints` as a percentage with two decimals and an explicit sign: "+0.73%", "-1.20%". Zero has no
    /// sign: "0.00%".
    public var percentText: String {
        let sign = basisPoints > 0 ? "+" : (basisPoints < 0 ? "-" : "")
        // `magnitude` instead of negating: `Int.min` has no positive counterpart.
        return sign + MoneyFormat.decimal(hundredths: UInt64(basisPoints.magnitude), grouped: false) + "%"
    }

    /// `difference * 10_000 / reference` rounded half away from zero. `reference` must be positive.
    private static func roundedBasisPoints(of difference: Int128, over reference: Int128) -> Int128 {
        // |difference| < 2^64, so negating it and the products below cannot overflow `Int128`.
        let magnitude = difference < 0 ? -difference : difference
        // floor(x + 1/2) as one integer division: (2n + d) / 2d is n/d rounded half up for n >= 0, d > 0.
        let rounded = (2 * magnitude * 10_000 + reference) / (2 * reference)
        return difference < 0 ? -rounded : rounded
    }
}

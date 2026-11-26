/// Latency as text for the HUD and the published results: "0.95 µs", "1.23 ms", "2.50 s", and "—" when there is
/// nothing to show.
///
/// Integer arithmetic only, rounding half up at two decimals, with the unit that fits: microseconds below 1 ms,
/// milliseconds below 1 s, seconds above (no thousands grouping, so a long wait reads "1000.00 s"). Exactly zero is
/// "0 ns", the only value shown in nanoseconds.
public enum LatencyFormat: Sendable {
    /// The text for a latency of `ns` nanoseconds.
    ///
    /// - No value, and any negative value (a latency taken across a clock that stepped back), give "—" (U+2014,
    ///   EM DASH): there is nothing true to show, and a minus sign is never printed.
    /// - Exactly 0 gives "0 ns"; 950 gives "0.95 µs"; 1_234_567 gives "1.23 ms"; 2_500_000_000 gives "2.50 s".
    /// - 1 to 4 ns are real but round to nothing at two decimals of a microsecond, so they print "0.00 µs" (and 5 ns
    ///   prints "0.01 µs"); "0 ns" stays reserved for exactly zero.
    /// - A value that would round up to 1000.00 of its unit moves to the next unit, so the text never shows
    ///   "1000.00 µs" or "1000.00 ms": 999_995 ns is "1.00 ms" and 999_995_000 ns is "1.00 s".
    /// - `Int64.max` prints in seconds ("9223372036.85 s") and cannot overflow.
    ///
    /// The micro sign is U+00B5 (MICRO SIGN), not the Greek letter mu (U+03BC).
    public static func string(ns: Int64?) -> String {
        guard let ns, ns >= 0 else {
            return noData
        }
        if ns == 0 {
            return "0 ns"
        }
        // `UInt64`, so that adding the rounding half below cannot overflow even for `Int64.max`.
        let value = UInt64(ns)
        let microseconds = hundredths(of: value, nanosPerHundredth: 10)
        if microseconds < thousand {
            return text(microseconds, unit: microSymbol + "s")
        }
        let milliseconds = hundredths(of: value, nanosPerHundredth: 10_000)
        if milliseconds < thousand {
            return text(milliseconds, unit: "ms")
        }
        return text(hundredths(of: value, nanosPerHundredth: 10_000_000), unit: "s")
    }

    /// U+2014 EM DASH.
    private static let noData = "\u{2014}"

    /// U+00B5 MICRO SIGN.
    private static let microSymbol = "\u{00B5}"

    /// 1000.00 of a unit, in hundredths of it: the value at which the next unit takes over.
    private static let thousand: UInt64 = 100_000

    /// `value` ns as hundredths of a unit, rounded half up, where a hundredth of the unit is `nanosPerHundredth` ns.
    private static func hundredths(of value: UInt64, nanosPerHundredth: UInt64) -> UInt64 {
        (value + nanosPerHundredth / 2) / nanosPerHundredth
    }

    private static func text(_ hundredths: UInt64, unit: String) -> String {
        MoneyFormat.decimal(hundredths: hundredths, grouped: false) + " " + unit
    }
}

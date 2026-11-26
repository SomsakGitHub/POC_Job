import Testing
import TradeCore

private func scalars(_ text: String) -> [UInt32] {
    text.unicodeScalars.map(\.value)
}

/// "12.34 ms" and "0 ns": an unsigned number (two decimals, except for the "0 ns" of exactly zero) and one of the
/// four units, separated by one space.
private func isUnsignedNumberWithUnit(_ text: String) -> Bool {
    let parts = text.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 2, ["ns", "µs", "ms", "s"].contains(String(parts[1])) else {
        return false
    }
    if parts[1] == "ns" {
        return parts[0] == "0"
    }
    let number = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard number.count == 2, number[1].count == 2 else {
        return false
    }
    return number.allSatisfy { digits in !digits.isEmpty && digits.allSatisfy { ("0"..."9").contains($0) } }
}

/// The nanoseconds a text stands for, in integers: "1.23 ms" is 123 hundredths of a millisecond.
private func nanoseconds(of text: String) -> Int128 {
    let parts = text.split(separator: " ")
    let hundredths = Int128(parts[0].filter { $0 != "." }) ?? -1
    switch parts[1] {
    case "ns": return hundredths
    case "µs": return hundredths * 10
    case "ms": return hundredths * 10_000
    default: return hundredths * 10_000_000
    }
}

struct LatencyFormatTests {
    /// The reference examples, one per unit and the dash for no data, with the symbols copied byte for byte.
    @Test func eachUnitAndTheNoDataDashAreFormattedAsExpected() {
        #expect(LatencyFormat.string(ns: nil) == "—")
        #expect(LatencyFormat.string(ns: 0) == "0 ns")
        #expect(LatencyFormat.string(ns: 950) == "0.95 µs")
        #expect(LatencyFormat.string(ns: 1_234_567) == "1.23 ms")
        #expect(LatencyFormat.string(ns: 2_500_000_000) == "2.50 s")
    }

    /// The micro sign is U+00B5, not the Greek letter mu (U+03BC): the two look the same on screen and in a
    /// source file, and differ only in the scalar. The no-data dash is the em dash U+2014, not a hyphen or an en
    /// dash. Pinned by scalar value because no reader could spot a slip.
    @Test func symbolsAreTheExactUnicodeScalars() {
        #expect(scalars(LatencyFormat.string(ns: nil)) == [0x2014])
        #expect(scalars(LatencyFormat.string(ns: 950)) == [0x30, 0x2E, 0x39, 0x35, 0x20, 0xB5, 0x73])
        #expect(scalars(LatencyFormat.string(ns: 0)) == [0x30, 0x20, 0x6E, 0x73])
        #expect(scalars(LatencyFormat.string(ns: 1_234_567)) == [0x31, 0x2E, 0x32, 0x33, 0x20, 0x6D, 0x73])
        #expect(scalars(LatencyFormat.string(ns: 2_500_000_000)) == [0x32, 0x2E, 0x35, 0x30, 0x20, 0x73])
        #expect(!LatencyFormat.string(ns: 950).unicodeScalars.contains("\u{03BC}"))
    }

    // MARK: Units

    /// Two decimals in the unit that fits: below 1 ms in microseconds, below 1 s in milliseconds, then seconds
    /// (which has no larger unit, so it can exceed 999.99). No thousands grouping.
    @Test(arguments: [
        (1_000, "1.00 µs"),
        (15_000, "15.00 µs"),
        (950, "0.95 µs"),
        (999_994, "999.99 µs"),
        (1_000_000, "1.00 ms"),
        (1_234_567, "1.23 ms"),
        (16_700_000, "16.70 ms"),
        (33_000_000, "33.00 ms"),
        (999_994_999, "999.99 ms"),
        (1_000_000_000, "1.00 s"),
        (2_500_000_000, "2.50 s"),
        (10_000_000_000, "10.00 s"),
        (59_999_999_999, "60.00 s"),
        (1_000_000_000_000, "1000.00 s"),
    ] as [(Int64, String)])
    func printsTwoDecimalsInTheUnitThatFits(ns: Int64, expected: String) {
        #expect(LatencyFormat.string(ns: ns) == expected)
    }

    /// 1 to 4 ns are real but round to 0.00 us at two decimals, so they print "0.00 µs": never "0 ns", which
    /// is kept for exactly zero (a latency clamped up from a negative one), and never a rounded-up figure that
    /// claims more than was measured. 5 ns is the first to print 0.01 us.
    @Test(arguments: [
        (1, "0.00 µs"),
        (2, "0.00 µs"),
        (3, "0.00 µs"),
        (4, "0.00 µs"),
        (5, "0.01 µs"),
        (9, "0.01 µs"),
        (14, "0.01 µs"),
        (15, "0.02 µs"),
    ] as [(Int64, String)])
    func aFewNanosecondsPrintAsZeroPointZeroZeroMicroseconds(ns: Int64, expected: String) {
        #expect(LatencyFormat.string(ns: ns) == expected)
    }

    // MARK: Rounding

    /// Half rounds up at the second decimal, in integer arithmetic (a Double would turn some of these ties
    /// the other way): 1005 ns is 1.005 us, a tie, and prints 1.01.
    @Test(arguments: [
        (994, "0.99 µs"),
        (1_004, "1.00 µs"),
        (1_005, "1.01 µs"),
        (1_006, "1.01 µs"),
        (1_234_499, "1.23 ms"),
        (1_234_999, "1.23 ms"),
        (1_235_000, "1.24 ms"),
        (2_494_999_999, "2.49 s"),
        (2_495_000_000, "2.50 s"),
    ] as [(Int64, String)])
    func halfRoundsUpAtTheSecondDecimal(ns: Int64, expected: String) {
        #expect(LatencyFormat.string(ns: ns) == expected)
    }

    /// A value that would print as 1000.00 of its unit prints as 1.00 of the next one instead, so the text never
    /// shows 1000.00 us or 1000.00 ms. The boundary is the rounding, not the unit: 999_994 ns is still microseconds.
    @Test(arguments: [
        (995, "1.00 µs"),
        (999, "1.00 µs"),
        (999_994, "999.99 µs"),
        (999_995, "1.00 ms"),
        (999_999, "1.00 ms"),
        (999_994_999, "999.99 ms"),
        (999_995_000, "1.00 s"),
        (999_999_999, "1.00 s"),
    ] as [(Int64, String)])
    func aValueThatRoundsUpToAThousandMovesToTheNextUnit(ns: Int64, expected: String) {
        #expect(LatencyFormat.string(ns: ns) == expected)
    }

    // MARK: No data and bad data

    /// A negative value (a latency measured across a clock that stepped back) has nothing true to show: the
    /// dash, like no value at all. A minus sign is never printed.
    @Test(arguments: [-1, -950, -1_234_567, -2_500_000_000, Int64.min + 1, Int64.min] as [Int64])
    func aNegativeValueIsTheDashNotAMinusSign(ns: Int64) {
        #expect(LatencyFormat.string(ns: ns) == "—")
    }

    /// `Int64.max` ns is about 292 years: it prints in seconds and must not overflow while rounding.
    @Test func theLargestValueIsInSecondsAndDoesNotTrap() {
        #expect(LatencyFormat.string(ns: .max) == "9223372036.85 s")
        #expect(LatencyFormat.string(ns: .max - 1) == "9223372036.85 s")
    }

    /// Whatever the value, the text is the dash (for a negative one) or a plain unsigned number with two decimals
    /// and a unit: never a minus sign, never "nan" or "inf", never a figure without its unit.
    @Test func everyTextIsTheDashOrAnUnsignedNumberWithAUnit() {
        var samples: [Int64] = [.min, .min + 1, -1, 0, 1, 4, 5, .max - 1, .max]
        var magnitude: Int64 = 1
        while magnitude < .max / 7 {
            samples += [magnitude, -magnitude, magnitude - 1, magnitude + 1, magnitude * 5 - 1, magnitude * 5]
            magnitude *= 7
        }
        var malformed: [String] = []
        for sample in samples {
            let text = LatencyFormat.string(ns: sample)
            let wellFormed = sample < 0 ? text == "—" : isUnsignedNumberWithUnit(text)
            if !wellFormed {
                malformed.append("\(sample) -> \(text)")
            }
        }
        #expect(malformed.isEmpty, "\(malformed.prefix(5))")
    }

    /// A larger latency never prints as a smaller one: the rounding and the change of unit keep the order.
    @Test func theTextNeverGoesBackwardsAsTheValueGrows() {
        var previous: Int128 = 0
        var value: Int64 = 0
        var regressions: [Int64] = []
        while value < 100_000_000_000 {
            let reading = nanoseconds(of: LatencyFormat.string(ns: value))
            if reading < previous {
                regressions.append(value)
            }
            previous = reading
            value += value / 211 + 1
        }
        #expect(regressions.isEmpty, "\(regressions.prefix(5))")
    }
}

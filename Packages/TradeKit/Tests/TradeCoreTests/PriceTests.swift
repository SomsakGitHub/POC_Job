import Testing
import TradeCore

private func price(_ satang: Int64) -> Price {
    Price(satang: satang)
}

struct PriceTests {
    @Test func descriptionIsBahtWithTwoDecimals() {
        #expect(price(3425).description == "34.25")
        #expect(price(1).description == "0.01")
        #expect(price(-50).description == "-0.50")
    }

    @Test(arguments: [
        (0, "0.00"),
        (9, "0.09"),
        (10, "0.10"),
        (99, "0.99"),
        (100, "1.00"),
        (-1, "-0.01"),
        (-100, "-1.00"),
        (-101, "-1.01"),
        // No thousands grouping: that belongs to MoneyFormat.
        (123_456_789, "1234567.89"),
        // The extremes must not trap: the magnitude of Int64.min does not fit in Int64.
        (Int64.max, "92233720368547758.07"),
        (Int64.min + 1, "-92233720368547758.07"),
        (Int64.min, "-92233720368547758.08"),
    ] as [(Int64, String)])
    func descriptionAcrossTheRange(satang: Int64, expected: String) {
        #expect(price(satang).description == expected)
    }

    @Test func notionalIsPriceTimesQuantityInSatang() {
        #expect(price(3425).notional(quantity: 100) == 342_500)
        #expect(price(3425).notional(quantity: 0) == 0)
    }

    @Test func notionalIsNilWhenTheProductDoesNotFitInInt64() {
        #expect(price(.max).notional(quantity: 2) == nil)
    }

    @Test(arguments: [
        (Int64.max, 1, Int64.max),
        (Int64.max, 0, 0),
        (Int64.max, -1, -Int64.max),
        (Int64.min, 1, Int64.min),
        (Int64.min, 0, 0),
        (0, Int64.max, 0),
        (1, Int64.max, Int64.max),
        // The largest square that fits, and the next one up.
        (3_037_000_499, 3_037_000_499, 9_223_372_030_926_249_001),
        // Plain checked multiplication: the quantity is not validated here.
        (3425, -100, -342_500),
    ] as [(Int64, Int64, Int64)])
    func notionalAtTheBoundaries(satang: Int64, quantity: Quantity, expected: Int64) {
        #expect(price(satang).notional(quantity: quantity) == expected)
    }

    @Test(arguments: [
        (Int64.max, 2),
        (Int64.min, 2),
        // Int64.min * -1 is the classic overflow: the result is 2^63.
        (Int64.min, -1),
        (-1, Int64.min),
        (3_037_000_500, 3_037_000_500),
    ] as [(Int64, Int64)])
    func notionalOverflowIsNil(satang: Int64, quantity: Quantity) {
        #expect(price(satang).notional(quantity: quantity) == nil)
    }

    @Test func ordersByAmount() {
        #expect(price(2397) < price(2400))
        #expect(!(price(5) < price(5)))
        #expect(price(.min) < price(.max))
        #expect([price(30), price(-5), price(12)].sorted() == [price(-5), price(12), price(30)])
    }

    @Test func equalPricesAreEqualAndHashTogether() {
        #expect(price(3425) == price(3425))
        #expect(price(3425) != price(3426))
        #expect(Set([price(3425), price(3425), price(3426)]).count == 2)
    }
}

struct PriceChangeTests {
    @Test func upMove() {
        let change = PriceChange(last: price(3450), reference: price(3425))
        #expect(change.delta == price(25))
        #expect(change.basisPoints == 73)
        #expect(change.percentText == "+0.73%")
        #expect(change.direction == .up)
    }

    @Test func downMove() {
        let change = PriceChange(last: price(9880), reference: price(10_000))
        #expect(change.delta == price(-120))
        #expect(change.basisPoints == -120)
        #expect(change.percentText == "-1.20%")
        #expect(change.direction == .down)
    }

    @Test func unchangedHasNoSign() {
        let change = PriceChange(last: price(3425), reference: price(3425))
        #expect(change.delta == price(0))
        #expect(change.basisPoints == 0)
        #expect(change.percentText == "0.00%")
        #expect(change.direction == .flat)
    }

    /// Basis points are rounded to the nearest, ties away from zero, in integer arithmetic.
    /// Truncation would turn 72.99 bp into 72 and -119.7 bp into -119.
    @Test(arguments: [
        (3450, 3425, 73, "+0.73%"),      // 72.99 bp
        (3384, 3425, -120, "-1.20%"),    // -119.71 bp
        (3425, 3375, 148, "+1.48%"),     // 148.15 bp
        (3426, 3425, 3, "+0.03%"),       // 2.92 bp
        (4, 3, 3333, "+33.33%"),         // 3333.33 bp
        (2, 3, -3333, "-33.33%"),        // -3333.33 bp
        (0, 3425, -10_000, "-100.00%"),
        (6850, 3425, 10_000, "+100.00%"),
        (20_003, 20_000, 2, "+0.02%"),   // exactly 1.5 bp: tie rounds up, away from zero
        (19_997, 20_000, -2, "-0.02%"),  // exactly -1.5 bp: tie rounds down, away from zero
        (20_001, 20_000, 1, "+0.01%"),   // exactly 0.5 bp
        (19_999, 20_000, -1, "-0.01%"),  // exactly -0.5 bp
        (20_002, 20_001, 0, "0.00%"),    // 0.49997 bp: just below the tie
        (20_000, 20_001, 0, "0.00%"),    // -0.49998 bp
    ] as [(Int64, Int64, Int, String)])
    func roundsToTheNearestBasisPointTiesAwayFromZero(
        last: Int64, reference: Int64, basisPoints: Int, text: String
    ) {
        let change = PriceChange(last: price(last), reference: price(reference))
        #expect(change.basisPoints == basisPoints)
        #expect(change.percentText == text)
    }

    /// The direction is the sign of the rounded basis points, so it always agrees with `percentText`.
    /// A move below half a basis point reads "0.00%" and `.flat`; the exact difference stays in `delta`.
    @Test func directionFollowsTheRoundedBasisPoints() {
        let tiny = PriceChange(last: price(20_002), reference: price(20_001))
        #expect(tiny.delta == price(1))
        #expect(tiny.percentText == "0.00%")
        #expect(tiny.direction == .flat)

        #expect(PriceChange(last: price(20_001), reference: price(20_000)).direction == .up)
        #expect(PriceChange(last: price(19_999), reference: price(20_000)).direction == .down)
    }

    /// Without a positive reference there is no baseline to measure against, so the change is reported as nothing:
    /// delta 0, 0 bp, "0.00%", flat. This keeps a not-yet-loaded reference from showing the whole price as a gain.
    @Test(arguments: [
        (3450, 0),
        (0, 0),
        (3450, -100),
        (-3450, -100),
        (Int64.max, 0),
        (Int64.max, Int64.min),
        (Int64.min, Int64.min),
        (Int64.min, 0),
    ] as [(Int64, Int64)])
    func zeroOrNegativeReferenceMeansNoChange(last: Int64, reference: Int64) {
        let change = PriceChange(last: price(last), reference: price(reference))
        #expect(change.delta == price(0))
        #expect(change.basisPoints == 0)
        #expect(change.percentText == "0.00%")
        #expect(change.direction == .flat)
    }

    @Test func extremeInputsNeverTrap() {
        // delta fits, basis points exceed Int and saturate: the text still formats, with no sign flip.
        let huge = PriceChange(last: price(.max), reference: price(1))
        #expect(huge.delta == price(.max - 1))
        #expect(huge.basisPoints == Int.max)
        #expect(huge.percentText == "+92233720368547758.07%")
        #expect(huge.direction == .up)

        // Int.min has no positive counterpart in Int: percentText must not negate it.
        let crash = PriceChange(last: price(.min), reference: price(1))
        #expect(crash.delta == price(.min))
        #expect(crash.basisPoints == Int.min)
        #expect(crash.percentText == "-92233720368547758.08%")
        #expect(crash.direction == .down)

        // The true difference (-2^64 + 1) does not fit in Int64: delta saturates, basis points stay exact.
        let swing = PriceChange(last: price(.min), reference: price(.max))
        #expect(swing.delta == price(.min))
        #expect(swing.basisPoints == -20_000)
        #expect(swing.percentText == "-200.00%")

        let toZero = PriceChange(last: price(0), reference: price(.max))
        #expect(toZero.delta == price(-.max))
        #expect(toZero.basisPoints == -10_000)

        let same = PriceChange(last: price(.max), reference: price(.max))
        #expect(same.delta == price(0))
        #expect(same.direction == .flat)

        // One satang of difference on the largest reference rounds to zero basis points.
        let sliver = PriceChange(last: price(.max), reference: price(.max - 1))
        #expect(sliver.delta == price(1))
        #expect(sliver.basisPoints == 0)
        #expect(sliver.direction == .flat)
    }
}

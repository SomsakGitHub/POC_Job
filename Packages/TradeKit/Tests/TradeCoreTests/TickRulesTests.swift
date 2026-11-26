import Testing
import TradeCore

private func price(_ satang: Int64) -> Price {
    Price(satang: satang)
}

/// `TickRules.validate` with prices in satang. The reference defaults to 3425 (34.25 baht).
private func validate(
    _ type: OrderType, _ quantity: Quantity, _ limit: Int64?, reference: Int64 = 3425
) -> RejectReason? {
    TickRules.validate(type: type, quantity: quantity, limit: limit.map(price), reference: price(reference))
}

struct TickRulesTests {
    @Test func boardLotAndMaximumOrderQuantity() {
        #expect(TickRules.boardLot == 100)
        #expect(TickRules.maxOrderQuantity == 10_000_000)
    }

    // MARK: tickSize and isOnTick

    /// Every tier boundary, on both sides.
    @Test(arguments: [
        (1, 1), (199, 1),
        (200, 2), (499, 2),
        (500, 5), (999, 5),
        (1000, 10), (2499, 10),
        (2500, 25), (9999, 25),
        (10_000, 50), (19_999, 50),
        (20_000, 100), (39_999, 100),
        (40_000, 200), (1_000_000, 200), (Int64.max, 200),
    ] as [(Int64, Int64)])
    func tickSizeByPriceTier(satang: Int64, tick: Int64) {
        #expect(TickRules.tickSize(at: price(satang)) == price(tick))
    }

    /// Below 200 satang the tick is 1, and that includes prices that are not valid prices at all.
    @Test(arguments: [0, -1, -10_000, Int64.min] as [Int64])
    func tickSizeBelowTheFirstTierIsOneSatang(satang: Int64) {
        #expect(TickRules.tickSize(at: price(satang)) == price(1))
    }

    @Test func isOnTickAtTheHundredBahtTierChange() {
        #expect(TickRules.isOnTick(price(10_000)))
        #expect(TickRules.isOnTick(price(9975)))      // tick 25 below 100.00
        #expect(!TickRules.isOnTick(price(10_025)))   // tick 50 from 100.00 up
        #expect(TickRules.isOnTick(price(10_050)))
    }

    @Test(arguments: [
        (1, true), (199, true),
        (200, true), (201, false), (202, true), (499, false),
        (500, true), (501, false), (505, true), (999, false),
        (1000, true), (1005, false), (1010, true), (2490, true),
        (2500, true), (2510, false), (2525, true), (9975, true),
        (20_000, true), (20_050, false), (20_100, true),
        (40_000, true), (40_100, false), (40_200, true),
        (9_223_372_036_854_775_800, true),   // a huge on-tick price
        (Int64.max, false),                  // 7 satang past a tick: no trap
    ] as [(Int64, Bool)])
    func isOnTickAcrossTheTiers(satang: Int64, expected: Bool) {
        #expect(TickRules.isOnTick(price(satang)) == expected)
    }

    /// Zero and negative prices are never on a tick, even though 0 and negative multiples of the tick divide evenly.
    @Test(arguments: [0, -1, -25, -50, -10_000, Int64.min] as [Int64])
    func nonPositivePricesAreNotOnTick(satang: Int64) {
        #expect(!TickRules.isOnTick(price(satang)))
    }

    // MARK: band

    @Test func bandIsPlusMinusThirtyPercentFlooredToSatang() {
        // 3425 * 70 / 100 = 2397.5 and 3425 * 130 / 100 = 4452.5: both floored.
        #expect(TickRules.band(reference: price(3425)) == price(2397)...price(4452))
        #expect(TickRules.band(reference: price(10_000)) == price(7000)...price(13_000))
        #expect(TickRules.band(reference: price(100)) == price(70)...price(130))
        #expect(TickRules.band(reference: price(1)) == price(0)...price(1))
    }

    /// No positive reference means no meaningful band: the degenerate range 0...0, which no positive price is in.
    @Test(arguments: [0, -1, -3425, Int64.min] as [Int64])
    func nonPositiveReferenceGivesTheEmptyBand(reference: Int64) {
        let band = TickRules.band(reference: price(reference))
        #expect(band == price(0)...price(0))
        #expect(!band.contains(price(1)))
    }

    /// `reference * 130` overflows Int64 from about 7.09e16 up, long before the band edge itself (`* 1.3`) does,
    /// so the intermediate product must be wide. These bands are still exact.
    @Test func largeReferencesDoNotOverflowTheIntermediateProduct() {
        #expect(
            TickRules.band(reference: price(100_000_000_000_000_000))
                == price(70_000_000_000_000_000)...price(130_000_000_000_000_000))
        #expect(
            TickRules.band(reference: price(7_000_000_000_000_000_000))
                == price(4_900_000_000_000_000_000)...price(9_100_000_000_000_000_000))
    }

    /// When 130% of the reference no longer fits in Int64 the upper edge saturates at Int64.max; the lower edge,
    /// being below the reference, is always exact.
    @Test func upperEdgeSaturatesAtInt64Max() {
        let big = TickRules.band(reference: price(8_000_000_000_000_000_000))
        #expect(big.lowerBound == price(5_600_000_000_000_000_000))
        #expect(big.upperBound == price(.max))

        let widest = TickRules.band(reference: price(.max))
        #expect(widest.lowerBound == price(6_456_360_425_798_343_064))
        #expect(widest.upperBound == price(.max))
    }

    // MARK: validate

    @Test func acceptsValidOrders() {
        #expect(validate(.limit, 100, 4450) == nil)
        #expect(validate(.market, 100, nil) == nil)
        #expect(validate(.limit, 100, 2400) == nil)   // first on-tick price above the lower band edge (2397)
    }

    @Test func rejectsOffTickLimitsBeforeTheBand() {
        #expect(validate(.limit, 100, 4452) == .invalidTick)   // inside the band (upper edge) but 2 satang off the tick
        #expect(validate(.limit, 100, 4476) == .invalidTick)   // off tick AND outside the band: tick is checked first
    }

    @Test func rejectsLimitsOutsideTheBand() {
        #expect(validate(.limit, 100, 4475) == .outsidePriceBand)   // on tick, 23 satang above the upper edge
        #expect(validate(.limit, 100, 2390) == .outsidePriceBand)   // on tick, 7 satang below the lower edge
    }

    /// With reference 10,000 both band edges (7,000 and 13,000) are themselves valid ticks: exactly on the
    /// edge is in, one tick beyond it is out.
    @Test func bandEdgesAreInclusive() {
        #expect(validate(.limit, 100, 7000, reference: 10_000) == nil)
        #expect(validate(.limit, 100, 6975, reference: 10_000) == .outsidePriceBand)
        #expect(validate(.limit, 100, 13_000, reference: 10_000) == nil)
        #expect(validate(.limit, 100, 13_050, reference: 10_000) == .outsidePriceBand)
    }

    /// The tick size changes at 100.00: 25 satang below it, 50 from it up.
    @Test func tickSizeChangesAtOneHundredBaht() {
        #expect(validate(.limit, 100, 9975, reference: 10_000) == nil)
        #expect(validate(.limit, 100, 10_000, reference: 10_000) == nil)
        #expect(validate(.limit, 100, 10_025, reference: 10_000) == .invalidTick)
        #expect(validate(.limit, 100, 10_050, reference: 10_000) == nil)
        #expect(validate(.limit, 100, 9990, reference: 10_000) == .invalidTick)
    }

    /// A limit order must carry a positive limit price that sits on a tick.
    @Test(arguments: [nil, 0, -25, -2400, Int64.min] as [Int64?])
    func limitOrderWithoutAUsablePriceIsInvalidTick(limit: Int64?) {
        #expect(validate(.limit, 100, limit) == .invalidTick)
    }

    @Test(arguments: [0, -100, -1, Int64.min, 20_000_000, 10_000_100, 10_000_001, Int64.max] as [Int64])
    func zeroNegativeOrOversizedQuantityIsInvalidQuantity(quantity: Int64) {
        #expect(validate(.limit, quantity, 4450) == .invalidQuantity)
        #expect(validate(.market, quantity, nil) == .invalidQuantity)
    }

    @Test(arguments: [1, 99, 101, 150, 9_999_999] as [Int64])
    func quantityOffTheBoardLotIsInvalidLot(quantity: Int64) {
        #expect(validate(.limit, quantity, 4450) == .invalidLot)
        #expect(validate(.market, quantity, nil) == .invalidLot)
    }

    @Test(arguments: [100, 200, 5_000, 9_999_900, 10_000_000] as [Int64])
    func wholeLotQuantitiesUpToTheMaximumAreAccepted(quantity: Int64) {
        #expect(validate(.limit, quantity, 4450) == nil)
        #expect(validate(.market, quantity, nil) == nil)
    }

    /// Checks run in order: quantity, lot, tick, band. The first failure wins.
    @Test func checksRunInOrder() {
        #expect(validate(.limit, -150, 4452) == .invalidQuantity)       // negative AND off the lot AND off tick
        #expect(validate(.limit, 20_000_001, 4452) == .invalidQuantity) // too large AND off the lot AND off tick
        #expect(validate(.limit, 150, 4452) == .invalidLot)             // off the lot AND off tick
        #expect(validate(.limit, 150, nil) == .invalidLot)              // off the lot AND no price
        #expect(validate(.limit, 100, 4476) == .invalidTick)            // off tick AND outside the band
    }

    /// A market order has no price: whatever `limit` carries is ignored, only the quantity is checked.
    @Test(arguments: [nil, 0, -1, 4452, 4475, 1, Int64.max] as [Int64?])
    func marketOrderIgnoresTheLimit(limit: Int64?) {
        #expect(validate(.market, 100, limit) == nil)
    }

    /// No positive reference means an empty band, so no positive limit is inside it; nothing traps.
    @Test(arguments: [0, -3425, Int64.min] as [Int64])
    func limitAgainstANonPositiveReferenceIsOutsideTheBand(reference: Int64) {
        #expect(validate(.limit, 100, 2400, reference: reference) == .outsidePriceBand)
        #expect(validate(.limit, 100, 0, reference: reference) == .invalidTick)
        #expect(validate(.market, 100, nil, reference: reference) == nil)
    }

    /// Reference Int64.max: the band is 6_456_360_425_798_343_064...Int64.max and the tick size there is 200.
    @Test func hugeReferenceDoesNotTrap() {
        #expect(validate(.limit, 100, 9_223_372_036_854_775_800, reference: .max) == nil)
        #expect(validate(.limit, 100, .max, reference: .max) == .invalidTick)   // the edge itself is 7 satang off tick
        #expect(validate(.limit, 100, 6_456_360_425_798_343_200, reference: .max) == nil)
        #expect(validate(.limit, 100, 6_456_360_425_798_343_000, reference: .max) == .outsidePriceBand)
    }
}

import Testing
import TradeCore
@testable import ExchangeCore

private func price(_ satang: Int64) -> Price {
    Price(satang: satang)
}

/// The symbol ids mean nothing to the ledger, which keeps whatever it is given.
private let symbolA: UInt32 = 1
private let symbolB: UInt32 = 2

private extension Ledger {
    /// A reservation that must be accepted. The check is made here and not inside `#expect`, which cannot wrap a
    /// call that mutates its receiver.
    mutating func expectReserved(
        _ id: String, _ side: Side, _ quantity: Quantity, at satang: Int64, symbol: UInt32 = symbolA,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let accepted = reserve(orderId: id, side: side, symbolId: symbol, quantity: quantity, price: price(satang))
        #expect(accepted, "reserving \(id) was refused", sourceLocation: sourceLocation)
    }

    /// A reservation that must be refused.
    mutating func expectNotReserved(
        _ id: String, _ side: Side, _ quantity: Quantity, at satang: Int64, symbol: UInt32 = symbolA,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let accepted = reserve(orderId: id, side: side, symbolId: symbol, quantity: quantity, price: price(satang))
        #expect(!accepted, "reserving \(id) was accepted", sourceLocation: sourceLocation)
    }

    /// `applyFill` for an order of symbol A, with the arguments in the order a test reads them.
    mutating func fillOrder(
        _ id: String, _ side: Side, _ quantity: Quantity, at satang: Int64, tsNs: Int64, symbol: UInt32 = symbolA
    ) -> LedgerEntry? {
        applyFill(orderId: id, symbolId: symbol, side: side, quantity: quantity, price: price(satang), tsNs: tsNs)
    }

    /// Reserves `quantity` shares to buy at `satang` each and fills all of them at that price in one fill, so the
    /// reservation ends with the fill. Both steps must be accepted.
    @discardableResult
    mutating func buyAtOnce(
        _ id: String, _ quantity: Quantity, at satang: Int64, symbol: UInt32 = symbolA
    ) throws -> LedgerEntry {
        let reserved = reserve(orderId: id, side: .buy, symbolId: symbol, quantity: quantity, price: price(satang))
        try #require(reserved)
        let fill = applyFill(
            orderId: id, symbolId: symbol, side: .buy, quantity: quantity, price: price(satang), tsNs: 0
        )
        return try #require(fill)
    }

    /// The same for a sell of shares the ledger holds.
    @discardableResult
    mutating func sellAtOnce(
        _ id: String, _ quantity: Quantity, at satang: Int64, symbol: UInt32 = symbolA
    ) throws -> LedgerEntry {
        let reserved = reserve(orderId: id, side: .sell, symbolId: symbol, quantity: quantity, price: price(satang))
        try #require(reserved)
        let fill = applyFill(
            orderId: id, symbolId: symbol, side: .sell, quantity: quantity, price: price(satang), tsNs: 0
        )
        return try #require(fill)
    }
}

private extension LedgerEntry {
    /// A copy with some fields changed. The fields are `let`, so a test that corrupts the log builds a new entry.
    func changing(
        ledgerSeq: UInt64? = nil, commission: Int64? = nil, cashAfter: Int64? = nil, positionAfter: Quantity? = nil
    ) -> LedgerEntry {
        LedgerEntry(
            ledgerSeq: ledgerSeq ?? self.ledgerSeq, orderId: orderId, symbolId: symbolId, side: side,
            quantity: quantity, price: price, commission: commission ?? self.commission, cashDelta: cashDelta,
            cashAfter: cashAfter ?? self.cashAfter, positionAfter: positionAfter ?? self.positionAfter, tsNs: tsNs
        )
    }
}

/// 1,000,000 satang at 15 bps, with 300 shares of symbol A bought at 10.00 (300,000 and 450 commission, so cash is
/// 699,550), a resting buy "buy" for 200 shares at 10.00 (it holds 200,300) and a resting sell "sell" for 100 of the
/// shares. That leaves 499,250 satang and 200 shares free.
private func busyLedger() throws -> Ledger {
    var ledger = Ledger(startingCash: 1_000_000)
    try ledger.buyAtOnce("seed", 300, at: 1000)
    let buy = ledger.reserve(orderId: "buy", side: .buy, symbolId: symbolA, quantity: 200, price: price(1000))
    try #require(buy)
    let sell = ledger.reserve(orderId: "sell", side: .sell, symbolId: symbolA, quantity: 100, price: price(1000))
    try #require(sell)
    return ledger
}

struct LedgerTests {
    // MARK: - Commission

    /// 15 basis points of 342,500 satang is 513.75, which is charged as 514. Exactly one half rounds up as well
    /// (517.5 is 518, 0.5 is 1) and anything below it rounds down.
    @Test(arguments: [
        // notional, bps, commission
        (342_500, 15, 514),         // 513.75
        (345_000, 15, 518),         // 517.5: exactly half rounds up
        (1000, 5, 1),               // 0.5: exactly half rounds up
        (3000, 5, 2),               // 1.5
        (999, 5, 0),                // 0.4995: just under half rounds down
        (4999, 1, 0),               // 0.4999: the nearest figure under half still rounds down
        (1001, 5, 1),               // 0.5005
        (666, 15, 1),               // 0.999
        (1, 15, 0),                 // a single satang pays nothing
        (690_000, 15, 1035),        // 1035.0 exactly
        (10_000, 5, 5),
        (342_500, 10_000, 342_500), // 100%: the whole amount
    ] as [(Int64, Int, Int64)])
    func commissionRoundsHalfUp(notional: Int64, bps: Int, expected: Int64) {
        #expect(Commission.compute(notional: notional, bps: bps) == expected)
    }

    /// A zero or negative notional or rate has nothing to charge on, or at: no commission, down to the extremes.
    @Test(arguments: [
        (0, 15), (-1, 15), (-342_500, 15), (Int64.min, 15), (342_500, 0), (342_500, -15), (342_500, Int.min),
        (Int64.min, Int.min), (0, 0),
    ] as [(Int64, Int)])
    func commissionIsZeroWhenThereIsNothingToChargeOnOrAt(notional: Int64, bps: Int) {
        #expect(Commission.compute(notional: notional, bps: bps) == 0)
    }

    /// The product is formed in 128 bits, so even the largest notional at the largest rate does not overflow on the
    /// way, and a commission too large for `Int64` is cut at `Int64.max`.
    @Test(arguments: [
        // notional, bps, commission
        (Int64.max, Int.max, Int64.max),
        (Int64.max, 20_000, Int64.max),  // twice the notional does not fit
        (Int64.max, 10_000, Int64.max),  // the whole amount fits exactly
        (Int64.max, 15, 13_835_058_055_282_164),
        (Int64.max, 1, 922_337_203_685_478),
        (1, Int.max, 922_337_203_685_478),
    ] as [(Int64, Int, Int64)])
    func commissionDoesNotOverflowAtTheExtremes(notional: Int64, bps: Int, expected: Int64) {
        #expect(Commission.compute(notional: notional, bps: bps) == expected)
    }

    // MARK: - Fills move cash and positions

    @Test func aNewLedgerStartsWithOneMillionBaht() {
        let ledger = Ledger()

        #expect(ledger.cash == 100_000_000)
        #expect(ledger.availableCash == 100_000_000)
        #expect(ledger.positions.isEmpty)
        #expect(ledger.entries.isEmpty)
        #expect(ledger.availableQuantity(symbolId: symbolA) == 0)
        #expect(ledger.invariantsHold())
    }

    /// 100 shares at 34.25 are 342,500 satang, and the default 15 bps of that (513.75) is charged as 514.
    @Test func buyReducesCashAddsPosition() throws {
        var ledger = Ledger()
        ledger.expectReserved("b1", .buy, 100, at: 3425)

        let fill = ledger.applyFill(
            orderId: "b1", symbolId: symbolA, side: .buy, quantity: 100, price: price(3425),
            tsNs: 1_700_000_000_123_456_789
        )

        let entry = try #require(fill)
        #expect(entry == LedgerEntry(
            ledgerSeq: 1, orderId: "b1", symbolId: symbolA, side: .buy, quantity: 100, price: price(3425),
            commission: 514, cashDelta: -343_014, cashAfter: 99_656_986, positionAfter: 100,
            tsNs: 1_700_000_000_123_456_789
        ))
        #expect(ledger.cash == 99_656_986)
        #expect(ledger.positions == [symbolA: 100])
        #expect(ledger.entries == [entry])
        #expect(ledger.availableCash == ledger.cash, "the reservation ended with the fill")
        #expect(ledger.invariantsHold())
    }

    /// 40 shares at 35.00 are 140,000 satang and the commission is exactly 210. A sell reserves shares, not cash.
    @Test func sellAddsCashReducesPosition() throws {
        var ledger = Ledger()
        try ledger.buyAtOnce("b1", 100, at: 3425)
        ledger.expectReserved("s1", .sell, 40, at: 3500)
        #expect(ledger.availableQuantity(symbolId: symbolA) == 60)
        #expect(ledger.availableCash == ledger.cash)

        let fill = ledger.fillOrder("s1", .sell, 40, at: 3500, tsNs: 2)

        let entry = try #require(fill)
        #expect(entry == LedgerEntry(
            ledgerSeq: 2, orderId: "s1", symbolId: symbolA, side: .sell, quantity: 40, price: price(3500),
            commission: 210, cashDelta: 139_790, cashAfter: 99_796_776, positionAfter: 60, tsNs: 2
        ))
        #expect(ledger.cash == 99_796_776)
        #expect(ledger.positions == [symbolA: 60])
        #expect(ledger.availableQuantity(symbolId: symbolA) == 60, "the 40 shares are gone, not held")
        #expect(ledger.invariantsHold())
    }

    /// A position that returns to zero is removed from `positions`, and the fill's entry says 0.
    @Test func aPositionThatReturnsToZeroIsRemoved() throws {
        var ledger = Ledger()
        try ledger.buyAtOnce("b1", 100, at: 3425)
        try ledger.buyAtOnce("b2", 300, at: 3425, symbol: symbolB)

        let closing = try ledger.sellAtOnce("s1", 100, at: 3500)

        #expect(closing.positionAfter == 0)
        #expect(ledger.positions == [symbolB: 300])
        #expect(ledger.availableQuantity(symbolId: symbolA) == 0)
        #expect(ledger.invariantsHold())
    }

    /// `ledgerSeq` counts the fills 1, 2, 3 and so on whatever the order or symbol. Reserving, releasing and refused
    /// calls add nothing to the log.
    @Test func theLogNumbersFillsFromOneWithoutGaps() throws {
        var ledger = Ledger()
        try ledger.buyAtOnce("b1", 100, at: 3425)
        ledger.expectNotReserved("none", .buy, 0, at: 1)
        ledger.expectReserved("b2", .buy, 100, at: 3425)
        ledger.release(orderId: "b2")
        try ledger.buyAtOnce("b3", 200, at: 3000, symbol: symbolB)
        try ledger.sellAtOnce("s1", 50, at: 3500)

        #expect(ledger.entries.map(\.ledgerSeq) == [1, 2, 3])
        #expect(ledger.entries.map(\.orderId) == ["b1", "b3", "s1"])
    }

    /// The timestamp is the caller's and is kept exactly as given, negative and extreme values included.
    @Test(arguments: [Int64.min, -1, 0, 1_700_000_000_123_456_789, Int64.max])
    func theTimestampIsKeptAsGiven(tsNs: Int64) throws {
        var ledger = Ledger()
        ledger.expectReserved("b1", .buy, 100, at: 3425)

        let fill = ledger.fillOrder("b1", .buy, 100, at: 3425, tsNs: tsNs)

        let entry = try #require(fill)
        #expect(entry.tsNs == tsNs)
    }

    // MARK: - Reservations

    /// 100 shares at 60.00 are 600,000 satang, and the reservation holds the 900 satang commission as well.
    @Test func cannotOverCommitCashAcrossRestingBuys() {
        var ledger = Ledger(startingCash: 1_000_000)

        ledger.expectReserved("b1", .buy, 100, at: 6000)
        #expect(ledger.availableCash == 399_100)
        ledger.expectNotReserved("b2", .buy, 100, at: 6000)

        #expect(ledger.availableCash == 399_100)
        #expect(ledger.cash == 1_000_000, "reserving moves no cash")
        #expect(ledger.invariantsHold())
    }

    @Test func cannotOversellAcrossRestingSells() throws {
        var ledger = Ledger()
        try ledger.buyAtOnce("seed", 300, at: 1000)

        ledger.expectReserved("s1", .sell, 200, at: 1100)
        #expect(ledger.availableQuantity(symbolId: symbolA) == 100)
        ledger.expectNotReserved("s2", .sell, 200, at: 1100)
        ledger.expectReserved("s3", .sell, 100, at: 1100)
        #expect(ledger.availableQuantity(symbolId: symbolA) == 0)
        ledger.expectNotReserved("s4", .sell, 100, at: 1100)

        #expect(ledger.positions == [symbolA: 300], "reserving moves no shares")
        #expect(ledger.invariantsHold())
    }

    @Test func releaseRestoresAvailable() throws {
        var ledger = Ledger()
        try ledger.buyAtOnce("seed", 300, at: 1000)
        let cash = ledger.cash
        ledger.expectReserved("b1", .buy, 200, at: 3450)
        ledger.expectReserved("s1", .sell, 250, at: 3500)
        #expect(ledger.availableCash < ledger.cash)
        #expect(ledger.availableQuantity(symbolId: symbolA) == 50)

        ledger.release(orderId: "b1")
        ledger.release(orderId: "s1")

        #expect(ledger.availableCash == ledger.cash)
        #expect(ledger.availableQuantity(symbolId: symbolA) == 300)
        #expect(ledger.cash == cash, "nothing was spent")
        #expect(ledger.invariantsHold())
    }

    /// What a partly filled order has not used comes back on release: a buy's cash and commission for the shares
    /// still to fill, a sell's shares still to sell. What the fill already did stays done.
    @Test(arguments: [Side.buy, Side.sell])
    func releasingAfterAPartialFillReturnsWhatIsLeft(side: Side) throws {
        var ledger = Ledger()
        try ledger.buyAtOnce("seed", 200, at: 3450)
        let cashBefore = ledger.cash
        ledger.expectReserved("o", side, 200, at: 3450)
        let fill = ledger.fillOrder("o", side, 100, at: 3450, tsNs: 1)
        let entry = try #require(fill)
        #expect(side == .buy ? ledger.availableCash < ledger.cash : ledger.availableQuantity(symbolId: symbolA) == 0)

        ledger.release(orderId: "o")

        #expect(ledger.availableCash == ledger.cash)
        #expect(ledger.availableQuantity(symbolId: symbolA) == ledger.positions[symbolA])
        #expect(ledger.cash == cashBefore + entry.cashDelta)
        #expect(ledger.positions == [symbolA: side == .buy ? 300 : 100])
        #expect(ledger.invariantsHold())
    }

    /// A market buy is reserved at the worst price of its sweep (35.00) for all the shares swept, then filled level by
    /// level at that price or better. Its commissions add up to the commission on the whole value (1,037,500 satang
    /// pays 1,556), and what was held beyond the exact cost (12,519 satang) comes back with the last fill.
    @Test func aMarketBuySweepingSeveralLevelsPaysExactlyItsCost() throws {
        var ledger = Ledger()
        ledger.expectReserved("m1", .buy, 300, at: 3500)
        #expect(ledger.availableCash == 100_000_000 - 1_051_575)

        var fills: [LedgerEntry] = []
        for (quantity, satang) in [(100, 3425), (100, 3450), (100, 3500)] as [(Int64, Int64)] {
            let fill = ledger.fillOrder("m1", .buy, quantity, at: satang, tsNs: 1)
            fills.append(try #require(fill))
        }

        #expect(fills.map(\.commission) == [514, 517, 525])
        #expect(fills.map(\.cashDelta) == [-343_014, -345_517, -350_525])
        #expect(ledger.cash == 100_000_000 - 1_039_056)
        #expect(ledger.availableCash == ledger.cash)
        #expect(ledger.invariantsHold())
    }

    /// The limit is 34.50: 100 shares are 345,000 satang and the commission is 518 (517.5), so 345,518 are held. The
    /// fill at 34.25 costs 342,500 + 514 = 343,014, and the 2,504 satang that were held but not needed come back.
    @Test func fillAtBetterPriceReleasesDifference() throws {
        var ledger = Ledger()
        ledger.expectReserved("b1", .buy, 100, at: 3450)
        #expect(ledger.availableCash == 100_000_000 - 345_518)

        let fill = ledger.fillOrder("b1", .buy, 100, at: 3425, tsNs: 1)

        let entry = try #require(fill)
        #expect(entry.cashDelta == -343_014)
        #expect(ledger.cash == 100_000_000 - 343_014)
        #expect(ledger.availableCash == 100_000_000 - 343_014)
        #expect(ledger.invariantsHold())
    }

    /// Each fill pays out of its own reservation, so a partial fill leaves `availableCash` where it was. What the
    /// cheaper fills left of the reservation comes back when the last share fills, not before: here 200 shares are
    /// reserved at 34.50 (691,035 held) and fill at 34.25 in two halves of 343,014 each, so 5,007 come back at the end.
    @Test func theSurplusOfCheaperFillsComesBackWhenTheLastShareFills() throws {
        var ledger = Ledger()
        ledger.expectReserved("b1", .buy, 200, at: 3450)
        let available = ledger.availableCash
        #expect(available == 100_000_000 - 691_035)

        let first = ledger.fillOrder("b1", .buy, 100, at: 3425, tsNs: 1)

        let firstEntry = try #require(first)
        #expect(firstEntry.cashDelta == -343_014)
        #expect(ledger.availableCash == available)
        let second = ledger.fillOrder("b1", .buy, 100, at: 3425, tsNs: 2)
        // The commission on the whole 685,000 is 1,028 (1,027.5), of which the first fill paid 514.
        let secondEntry = try #require(second)
        #expect(secondEntry.commission == 514)
        #expect(ledger.cash == 100_000_000 - 686_028)
        #expect(ledger.availableCash == ledger.cash)
        #expect(ledger.invariantsHold())
    }

    /// The commission is charged on the order's cumulative notional less what earlier fills paid, so partial fills
    /// add up to exactly the commission on the whole: two fills of 345,000 pay 518 and 517, which is the 1,035 of
    /// 690,000. Rounding each fill on its own would charge 518 twice. A sell is charged the same way.
    @Test(arguments: [Side.buy, Side.sell])
    func partialFillsPayExactlyTheCommissionOnTheTotal(side: Side) throws {
        var ledger = Ledger()
        if side == .sell {
            try ledger.buyAtOnce("seed", 200, at: 3450)
        }
        let reserved = ledger.reserve(orderId: "o", side: side, symbolId: symbolA, quantity: 200, price: price(3450))
        try #require(reserved)

        var fills: [LedgerEntry] = []
        for tsNs in [Int64(1), 2] {
            let fill = ledger.fillOrder("o", side, 100, at: 3450, tsNs: tsNs)
            fills.append(try #require(fill))
        }

        #expect(fills.map(\.commission) == [518, 517])
        #expect(fills.map(\.commission).reduce(0, +) == Commission.compute(notional: 690_000, bps: 15))
        #expect(fills.map(\.cashDelta) == (side == .buy ? [-345_518, -345_517] : [344_482, 344_483]))
        #expect(ledger.invariantsHold())
    }

    /// An order id is free again once its reservation has ended, by a last fill or by `release`. The new reservation
    /// starts clean: its commission is counted from zero, not from what the earlier one paid.
    @Test func anOrderIdCanBeReservedAgainOnceItsReservationHasEnded() throws {
        var ledger = Ledger()
        let first = try ledger.buyAtOnce("o", 100, at: 3450)
        ledger.expectReserved("o", .buy, 200, at: 3450)
        ledger.release(orderId: "o")
        ledger.expectReserved("o", .buy, 100, at: 3450)

        let again = ledger.fillOrder("o", .buy, 100, at: 3450, tsNs: 1)

        let second = try #require(again)
        #expect(first.commission == 518)
        #expect(second.commission == 518)
        #expect(ledger.entries.map(\.ledgerSeq) == [1, 2])
        #expect(ledger.invariantsHold())
    }

    // MARK: - Setup

    /// A negative starting cash is taken as none, so a ledger never starts below zero.
    @Test(arguments: [-1, -100_000_000, Int64.min] as [Int64])
    func aNegativeStartingCashIsTakenAsNone(startingCash: Int64) {
        let ledger = Ledger(startingCash: startingCash)

        #expect(ledger.cash == 0)
        #expect(ledger.availableCash == 0)
        #expect(ledger.invariantsHold())
    }

    /// A negative commission rate is taken as none: the reservation holds no commission and the fill pays none.
    @Test(arguments: [-1, -15, Int.min])
    func aNegativeCommissionRateIsTakenAsNone(bps: Int) throws {
        var ledger = Ledger(commissionBps: bps)
        ledger.expectReserved("b1", .buy, 100, at: 3425)
        #expect(ledger.availableCash == 100_000_000 - 342_500)

        let fill = ledger.fillOrder("b1", .buy, 100, at: 3425, tsNs: 1)

        let entry = try #require(fill)
        #expect(ledger.commissionBps == 0, "the rate the ledger keeps")
        #expect(entry.commission == 0)
        #expect(entry.cashDelta == -342_500)
        #expect(ledger.invariantsHold())
    }

    /// A rate above 100% (10,000 bps) is taken as 100%. A larger one would let a sell pay out less than nothing, and
    /// cash and `availableCash` could go negative. At 100% a sell's whole proceeds go to commission and no more.
    @Test(arguments: [10_000, 10_001, 20_000, Int.max])
    func aCommissionRateAboveOneHundredPercentIsTakenAsOneHundredPercent(bps: Int) throws {
        var ledger = Ledger(commissionBps: bps)

        let buy = try ledger.buyAtOnce("b1", 100, at: 3425)
        let sell = try ledger.sellAtOnce("s1", 100, at: 3425)

        #expect(ledger.commissionBps == 10_000, "the rate the ledger keeps")
        #expect(buy.commission == 342_500)
        #expect(buy.cashDelta == -685_000)
        #expect(sell.commission == 342_500)
        #expect(sell.cashDelta == 0)
        #expect(ledger.invariantsHold())
    }

    // MARK: - Random operations

    /// 10,000 seeded operations: reserves, fills (partial, whole, at better prices), releases, and every kind of
    /// refusal, with an order id sometimes reused after its reservation ended. After each step `invariantsHold()`
    /// must be true and the ledger must agree with a model kept beside it. The run counts what happened and every
    /// kind of step must have happened, so it cannot pass by never reaching a case.
    @Test func randomizedOperationsKeepInvariants() {
        var run = RandomRun(seed: 7)
        var steps = 0

        while steps < 10_000, run.problems.isEmpty {
            run.advance()
            steps += 1
        }

        #expect(run.problems.isEmpty, "\(run.problems.prefix(3))")
        #expect(steps == 10_000)
        for outcome in RandomRun.Outcome.allCases {
            #expect(run.counts[outcome, default: 0] > 0, "\(outcome) never happened: \(run.counts)")
        }
        let fills = run.counts[.partialFill, default: 0] + run.counts[.finalFill, default: 0]
        #expect(run.ledger.entries.count == fills, "each applied fill is one entry")
    }
}

// MARK: - Refusals

extension LedgerTests {
    struct Refusals {
        /// A call that is refused changes nothing, down to the ledger's hidden reservations: the whole ledger is
        /// equal to what it was.
        @Test(arguments: [
            // what, side, symbol, quantity, price in satang
            ("no shares", .buy, symbolA, 0, 1000),
            ("no shares", .sell, symbolA, 0, 1000),
            ("a negative quantity", .buy, symbolA, -100, 1000),
            ("a negative quantity", .sell, symbolA, -100, 1000),
            ("the smallest quantity", .buy, symbolA, Int64.min, 1000),
            ("the smallest quantity", .sell, symbolA, Int64.min, 1000),
            ("a price of nothing", .buy, symbolA, 100, 0),
            ("a price of nothing", .sell, symbolA, 100, 0),
            ("a negative price", .buy, symbolA, 100, -1000),
            ("a negative price", .sell, symbolA, 100, -1000),
            ("the smallest price", .buy, symbolA, 100, Int64.min),
            ("the smallest price", .sell, symbolA, 100, Int64.min),
            ("more than the free cash: 500,750 needed, 499,250 free", .buy, symbolA, 500, 1000),
            ("more than the free shares: 201 of 200", .sell, symbolA, 201, 1000),
            ("a symbol with no position", .sell, symbolB, 100, 1000),
            ("a value that overflows", .buy, symbolB, Int64.max, 1000),
            ("a value that overflows", .buy, symbolB, 100, Int64.max),
        ] as [(String, Side, UInt32, Int64, Int64)])
        func aRefusedReservationChangesNothing(
            what: String, side: Side, symbol: UInt32, quantity: Quantity, satang: Int64
        ) throws {
            var ledger = try busyLedger()
            let before = ledger

            let accepted = ledger.reserve(
                orderId: "new", side: side, symbolId: symbol, quantity: quantity, price: price(satang)
            )

            #expect(!accepted, "\(what)")
            #expect(ledger == before)
        }

        /// An order id that has a live reservation cannot reserve again, whatever else the call says, and the live
        /// reservation is not touched.
        @Test(arguments: ["buy", "sell"], [Side.buy, Side.sell])
        func anOrderIdWithALiveReservationCannotReserveAgain(id: String, side: Side) throws {
            var ledger = try busyLedger()
            let before = ledger

            let accepted = ledger.reserve(orderId: id, side: side, symbolId: symbolA, quantity: 100, price: price(1000))

            #expect(!accepted)
            #expect(ledger == before)
        }

        /// What is just inside the limits is accepted: a buy that takes exactly all the free cash (here 343,014: the
        /// 342,500 of 100 shares at 34.25 and the 514 commission) and one satang more is not; a sell of exactly all
        /// the free shares; the smallest buy; and a sell at a price whose value would overflow, because a sell
        /// reserves shares and never multiplies its price.
        @Test func reservationsJustInsideTheLimitsAreAccepted() throws {
            var exact = Ledger(startingCash: 343_014)
            exact.expectReserved("o", .buy, 100, at: 3425)
            #expect(exact.availableCash == 0)
            var short = Ledger(startingCash: 343_013)
            short.expectNotReserved("o", .buy, 100, at: 3425)

            var ledger = try busyLedger()
            ledger.expectReserved("tiny", .buy, 1, at: 1)
            ledger.expectReserved("dear", .sell, 100, at: Int64.max)
            ledger.expectReserved("rest", .sell, 100, at: 1000)
            #expect(ledger.availableQuantity(symbolId: symbolA) == 0)
            #expect(ledger.invariantsHold())
        }

        /// A fill that is refused changes nothing, and returns nil.
        @Test(arguments: [
            // what, order id, side, symbol, quantity, price in satang
            ("an unknown order", "nope", .buy, symbolA, 100, 1000),
            ("a buy filled as a sell", "buy", .sell, symbolA, 100, 1000),
            ("a sell filled as a buy", "sell", .buy, symbolA, 100, 1000),
            ("another symbol", "buy", .buy, symbolB, 100, 1000),
            ("another symbol", "sell", .sell, symbolB, 100, 1000),
            ("no shares", "buy", .buy, symbolA, 0, 1000),
            ("no shares", "sell", .sell, symbolA, 0, 1000),
            ("a negative quantity", "buy", .buy, symbolA, -100, 1000),
            ("the smallest quantity", "sell", .sell, symbolA, Int64.min, 1000),
            ("more than remains: 201 of 200", "buy", .buy, symbolA, 201, 1000),
            ("more than remains: 101 of 100", "sell", .sell, symbolA, 101, 1000),
            ("the largest quantity", "buy", .buy, symbolA, Int64.max, 1000),
            ("a price of nothing", "buy", .buy, symbolA, 100, 0),
            ("a price of nothing", "sell", .sell, symbolA, 100, 0),
            ("a negative price", "buy", .buy, symbolA, 100, -1),
            ("the smallest price", "sell", .sell, symbolA, 100, Int64.min),
            ("a buy one satang above its reserved price", "buy", .buy, symbolA, 100, 1001),
            ("a buy far above its reserved price", "buy", .buy, symbolA, 100, 2000),
            ("a value that overflows", "sell", .sell, symbolA, 100, Int64.max),
        ] as [(String, String, Side, UInt32, Int64, Int64)])
        func aRefusedFillReturnsNilAndChangesNothing(
            what: String, id: String, side: Side, symbol: UInt32, quantity: Quantity, satang: Int64
        ) throws {
            var ledger = try busyLedger()
            let before = ledger

            let fill = ledger.applyFill(
                orderId: id, symbolId: symbol, side: side, quantity: quantity, price: price(satang), tsNs: 1
            )

            #expect(fill == nil, "\(what)")
            #expect(ledger == before)
        }

        /// The edges of what a fill may be: the whole remainder at exactly the reserved price, one share, a buy at
        /// the smallest price, and a sell at any positive price: the reserved price of a sell is only a record and
        /// is not a limit, since a market sell sweeps down through the bids.
        @Test(arguments: [
            // what, order id, side, quantity, price in satang
            ("the whole remainder at the reserved price", "buy", .buy, 200, 1000),
            ("one share", "buy", .buy, 1, 1000),
            ("a buy at one satang", "buy", .buy, 200, 1),
            ("a sell under the reserved price", "sell", .sell, 100, 1),
            ("a sell over the reserved price", "sell", .sell, 100, 5000),
            ("a sell of one share", "sell", .sell, 1, 1000),
        ] as [(String, String, Side, Int64, Int64)])
        func fillsJustInsideTheLimitsAreAccepted(
            what: String, id: String, side: Side, quantity: Quantity, satang: Int64
        ) throws {
            var ledger = try busyLedger()

            let fill = ledger.applyFill(
                orderId: id, symbolId: symbolA, side: side, quantity: quantity, price: price(satang), tsNs: 1
            )

            #expect(fill != nil, "\(what)")
            #expect(ledger.invariantsHold())
        }

        /// A fill for an order whose reservation has ended is refused like one for an unknown order: after the last
        /// share, and after `release`.
        @Test func aFillAfterTheReservationEndedIsRefused() throws {
            var ledger = try busyLedger()
            let last = ledger.fillOrder("buy", .buy, 200, at: 1000, tsNs: 1)
            _ = try #require(last)
            ledger.release(orderId: "sell")
            let before = ledger

            for (id, side) in [("buy", Side.buy), ("sell", Side.sell)] {
                let fill = ledger.applyFill(
                    orderId: id, symbolId: symbolA, side: side, quantity: 1, price: price(1000), tsNs: 2
                )
                #expect(fill == nil, "\(id)")
            }

            #expect(ledger == before)
        }

        /// `release` of an order with no reservation (unknown, never reserved, or already ended) is a no-op.
        @Test(arguments: ["nope", "", "seed"])
        func releasingAnOrderWithoutAReservationChangesNothing(id: String) throws {
            var ledger = try busyLedger()
            let before = ledger

            ledger.release(orderId: id)

            #expect(ledger == before)
        }

        @Test func releasingTwiceIsTheSameAsOnce() throws {
            var ledger = try busyLedger()
            ledger.release(orderId: "buy")
            let once = ledger

            ledger.release(orderId: "buy")

            #expect(ledger == once)
            #expect(ledger.availableCash == ledger.cash)
        }
    }
}

// MARK: - Overflow

/// No operation traps for any `Int64`: a result that does not fit is a refusal, with nothing changed. Each of these
/// builds the state in which one particular amount would overflow.
extension LedgerTests {
    struct Overflow {
        /// A buy whose value overflows, and one whose value fits but not together with its commission, are refused.
        /// A buy of exactly `Int64.max` with no commission fits.
        @Test func aReservationThatDoesNotFitInInt64IsRefused() {
            var rich = Ledger(startingCash: Int64.max)
            let before = rich

            let overflowing = rich.reserve(
                orderId: "o", side: .buy, symbolId: symbolA, quantity: Int64.max, price: price(2)
            )
            let withCommission = rich.reserve(
                orderId: "o", side: .buy, symbolId: symbolA, quantity: Int64.max, price: price(1)
            )

            #expect(!overflowing)
            #expect(!withCommission)
            #expect(rich == before)
            var free = Ledger(startingCash: Int64.max, commissionBps: 0)
            free.expectReserved("o", .buy, Int64.max, at: 1)
            #expect(free.availableCash == 0)
            #expect(free.invariantsHold())
        }

        /// A sell whose proceeds would not fit in the cash is refused and the reservation stays. After buying one share
        /// for one satang cash is `Int64.max - 1`: a sale for 2 satang would make it one too many, and a sale for 1
        /// fits exactly.
        @Test func aSellWhoseProceedsWouldOverflowCashIsRefused() throws {
            var ledger = Ledger(startingCash: Int64.max, commissionBps: 0)
            try ledger.buyAtOnce("b1", 1, at: 1)
            ledger.expectReserved("s1", .sell, 1, at: 1)
            let before = ledger

            let tooMuch = ledger.fillOrder("s1", .sell, 1, at: 2, tsNs: 1)

            #expect(tooMuch == nil)
            #expect(ledger == before)
            let exact = ledger.fillOrder("s1", .sell, 1, at: 1, tsNs: 2)
            let entry = try #require(exact)
            #expect(entry.cashAfter == Int64.max)
            #expect(ledger.invariantsHold())
        }

        /// A buy that would take a position past `Int64.max` is refused, with the reservation left as it was: the
        /// first share of two fills lands exactly on `Int64.max`, the second would overflow.
        @Test func aBuyThatWouldOverflowThePositionIsRefused() throws {
            var ledger = Ledger(startingCash: Int64.max, commissionBps: 0)
            try ledger.buyAtOnce("all", Int64.max, at: 1)
            try ledger.sellAtOnce("one", 1, at: 2)
            #expect(ledger.positions == [symbolA: Int64.max - 1])
            ledger.expectReserved("two", .buy, 2, at: 1)
            let first = ledger.fillOrder("two", .buy, 1, at: 1, tsNs: 1)
            _ = try #require(first)
            #expect(ledger.positions == [symbolA: Int64.max])
            let before = ledger

            let second = ledger.fillOrder("two", .buy, 1, at: 1, tsNs: 2)

            #expect(second == nil)
            #expect(ledger == before)
            ledger.release(orderId: "two")
            #expect(ledger.invariantsHold())
        }

        /// An order's fills together are worth more than `Int64.max`: refused, though each fill alone fits. At 100%
        /// commission a sell pays out nothing, so cash does not overflow first and only the total does.
        @Test func fillsWhoseTotalValueDoesNotFitAreRefused() throws {
            var ledger = Ledger(startingCash: 1_000_000, commissionBps: 10_000)
            try ledger.buyAtOnce("b1", 2, at: 1)
            ledger.expectReserved("s1", .sell, 2, at: 1)
            let first = ledger.fillOrder("s1", .sell, 1, at: Int64.max, tsNs: 1)
            let firstEntry = try #require(first)
            #expect(firstEntry.cashDelta == 0)
            let before = ledger

            let second = ledger.fillOrder("s1", .sell, 1, at: Int64.max, tsNs: 2)

            #expect(second == nil)
            #expect(ledger == before)
            #expect(ledger.invariantsHold())
        }
    }
}

// MARK: - Invariants

extension LedgerTests {
    struct Invariants {
        /// Three fills in the log (300 shares bought, 100 sold, then 100 more bought: 300 held), a buy "live-buy"
        /// with 100 of its 200 shares still to fill and a sell "live-sell" of 50 shares.
        private func ledgerToCorrupt() throws -> Ledger {
            var ledger = Ledger()
            try ledger.buyAtOnce("b1", 300, at: 1000)
            try ledger.sellAtOnce("s1", 100, at: 1200)
            ledger.expectReserved("live-buy", .buy, 200, at: 1000)
            let partial = ledger.fillOrder("live-buy", .buy, 100, at: 1000, tsNs: 3)
            _ = try #require(partial)
            ledger.expectReserved("live-sell", .sell, 50, at: 1100)
            return ledger
        }

        @Test func aLedgerThatNothingHasBrokenHolds() throws {
            let busy = try busyLedger()
            let corruptible = try ledgerToCorrupt()

            #expect(Ledger().invariantsHold())
            #expect(busy.invariantsHold())
            #expect(corruptible.invariantsHold())
            #expect(corruptible.entries.count == 3)
        }

        /// Each way the state can be wrong is noticed. The ledger is corrupted from outside, since no operation
        /// can do it.
        enum Corruption: CaseIterable, Sendable {
            case negativeCash
            case cashAtTheExtreme
            case reservedCashTotalAtTheExtreme
            case cashMovedWithoutAnEntry
            case wrongCashAfter
            case gapInTheNumbering
            case wrongPositionAfter
            case positionMovedWithoutAnEntry
            case positionDippedBelowZero
            case fillAtNoPrice
            case fillOfNoShares
            case negativeCommission
            case amountsThatDisagree
            case zeroPositionKept
            case negativePosition
            case reservedCashTotalDrifted
            case finishedReservationKept
            case moreCashReservedThanOwned
            case reservedSharesTotalDrifted
            case moreSharesReservedThanHeld
            case reservationTooSmallForItsRemainder
            case sellReservationHoldingCash

            func apply(to ledger: inout Ledger) {
                switch self {
                case .negativeCash:
                    ledger.cash = -1
                case .cashAtTheExtreme:
                    // Working out `availableCash` from this would overflow, so the check on cash has to come first.
                    ledger.cash = Int64.min
                case .reservedCashTotalAtTheExtreme:
                    ledger.totalReservedCash = Int64.min
                case .cashMovedWithoutAnEntry:
                    ledger.cash += 1
                case .wrongCashAfter:
                    ledger.entries[1] = ledger.entries[1].changing(cashAfter: ledger.entries[1].cashAfter + 1)
                case .gapInTheNumbering:
                    ledger.entries[1] = ledger.entries[1].changing(ledgerSeq: 5)
                case .wrongPositionAfter:
                    // The sell in the middle of the log. The buy after it still says 300, so the closing position
                    // and every total come out right, and only this entry's own figure is wrong.
                    ledger.entries[1] = ledger.entries[1].changing(positionAfter: 250)
                case .positionMovedWithoutAnEntry:
                    ledger.positions[symbolA] = 301
                case .positionDippedBelowZero:
                    // Sells 100 shares of a symbol that was never held and buys them back: cash and the final
                    // position come out right, so only the dip to -100 in between gives it away.
                    let cash = ledger.cash
                    ledger.entries.append(LedgerEntry(
                        ledgerSeq: 4, orderId: "x", symbolId: symbolB, side: .sell, quantity: 100, price: price(1000),
                        commission: 0, cashDelta: 100_000, cashAfter: cash + 100_000, positionAfter: -100, tsNs: 0
                    ))
                    ledger.entries.append(LedgerEntry(
                        ledgerSeq: 5, orderId: "y", symbolId: symbolB, side: .buy, quantity: 100, price: price(1000),
                        commission: 0, cashDelta: -100_000, cashAfter: cash, positionAfter: 0, tsNs: 0
                    ))
                case .fillAtNoPrice:
                    // 100 shares for nothing: every sum still adds up, so only the missing price gives it away.
                    ledger.entries.append(LedgerEntry(
                        ledgerSeq: 4, orderId: "x", symbolId: symbolB, side: .buy, quantity: 100, price: price(0),
                        commission: 0, cashDelta: 0, cashAfter: ledger.cash, positionAfter: 100, tsNs: 0
                    ))
                    ledger.positions[symbolB] = 100
                case .fillOfNoShares:
                    ledger.entries.append(LedgerEntry(
                        ledgerSeq: 4, orderId: "x", symbolId: symbolB, side: .buy, quantity: 0, price: price(1000),
                        commission: 0, cashDelta: 0, cashAfter: ledger.cash, positionAfter: 0, tsNs: 0
                    ))
                case .negativeCommission:
                    // 100 shares at 1,000 for 99,999 satang: the commission is -1. Cash is moved to match.
                    ledger.entries.append(LedgerEntry(
                        ledgerSeq: 4, orderId: "x", symbolId: symbolB, side: .buy, quantity: 100, price: price(1000),
                        commission: -1, cashDelta: -99_999, cashAfter: ledger.cash - 99_999, positionAfter: 100,
                        tsNs: 0
                    ))
                    ledger.cash -= 99_999
                    ledger.positions[symbolB] = 100
                case .amountsThatDisagree:
                    ledger.entries[0] = ledger.entries[0].changing(commission: ledger.entries[0].commission + 1)
                case .zeroPositionKept:
                    ledger.positions[symbolB] = 0
                case .negativePosition:
                    ledger.positions[symbolB] = -1
                case .reservedCashTotalDrifted:
                    ledger.totalReservedCash += 1
                case .finishedReservationKept:
                    ledger.reservations["live-buy"]?.remainingQuantity = 0
                case .moreCashReservedThanOwned:
                    ledger.reservations["huge"] = Reservation(
                        side: .buy, symbolId: symbolB, price: price(1), remainingQuantity: 1,
                        reservedCash: ledger.cash
                    )
                    ledger.totalReservedCash += ledger.cash
                case .reservedSharesTotalDrifted:
                    ledger.reservedShares[symbolA] = 10
                case .moreSharesReservedThanHeld:
                    ledger.reservations["live-sell"]?.remainingQuantity = 400
                    ledger.reservedShares[symbolA] = 400
                case .reservationTooSmallForItsRemainder:
                    ledger.reservations["live-buy"]?.reservedCash -= 1
                    ledger.totalReservedCash -= 1
                case .sellReservationHoldingCash:
                    // Cash that no total accounts for, held by an order that can only hold shares.
                    ledger.reservations["live-sell"]?.reservedCash = 5
                }
            }
        }

        @Test(arguments: Corruption.allCases)
        func aCorruptedLedgerIsNoticed(corruption: Corruption) throws {
            var ledger = try ledgerToCorrupt()
            #expect(ledger.invariantsHold(), "the ledger is sound before it is corrupted")

            corruption.apply(to: &ledger)

            #expect(!ledger.invariantsHold(), "\(corruption)")
        }
    }
}

// MARK: - The random run

/// A seeded run of mixed operations on one `Ledger`, with a model of what each must do kept beside it. The model
/// works from the public API only: what is free before a call decides whether it is due to be accepted, and each
/// fill's commission comes from `Commission.compute` on the order's cumulative value.
private struct RandomRun {
    /// What a step did. A run that never produced one of these has not tested it.
    enum Outcome: CaseIterable {
        case reservedBuy, reservedSell, reusedOrderId
        case refusedForCash, refusedForShares, refusedDuplicate, refusedInvalid
        case partialFill, finalFill, betterPriceFill, closedPosition
        case released, releaseIgnored
        case fillRefusedUnknown, fillRefusedTooLarge, fillRefusedTooDear, fillRefusedMismatch
    }

    /// A live reservation as the model sees it.
    struct Order {
        let id: String
        let side: Side
        let symbol: UInt32
        let limit: Int64
        var remaining: Quantity
        /// The cash the reservation should still hold: a buy's, never a sell's.
        var held: Int64
        var filledValue: Int64 = 0
        var feesCharged: Int64 = 0
    }

    private static let bps = 15
    private static let startingCash: Int64 = 50_000_000

    private(set) var ledger = Ledger(startingCash: RandomRun.startingCash, commissionBps: RandomRun.bps)
    private(set) var counts: [Outcome: Int] = [:]
    private(set) var problems: [String] = []
    private var generator: SeededGenerator
    private var live: [Order] = []
    private var finishedIds: [String] = []
    private var cash = RandomRun.startingCash
    private var positions: [UInt32: Quantity] = [:]
    private var fills = 0
    private var idCounter = 0
    private var step = 0

    init(seed: UInt64) {
        generator = SeededGenerator(seed: seed)
    }

    mutating func advance() {
        step += 1
        switch generator.below(100) {
        case 0..<30:
            reserveRandom()
        case 30..<50:
            live.isEmpty ? reserveRandom() : fillRandom()
        case 50..<58:
            live.isEmpty ? reserveRandom() : releaseRandom()
        case 58..<62:
            liquidateRandom()
        default:
            refuseRandom()
        }
        verify()
    }

    private mutating func note(_ problem: String) {
        problems.append("step \(step): \(problem)")
    }

    private mutating func record(_ outcome: Outcome) {
        counts[outcome, default: 0] += 1
    }

    private mutating func freshId() -> String {
        idCounter += 1
        return "order-\(idCounter)"
    }

    private mutating func randomLimit() -> Int64 {
        Int64(25 * (20 + generator.below(200)))
    }

    private mutating func reserveRandom() {
        let side: Side = generator.below(100) < 60 ? .buy : .sell
        let symbol = UInt32(1 + generator.below(3))
        let quantity: Quantity = generator.below(5) == 0
            ? Quantity(1 + generator.below(1999)) : Quantity(100 * (1 + generator.below(20)))
        _ = reserve(side: side, symbol: symbol, quantity: quantity, limit: randomLimit())
    }

    /// Reserves under a fresh id, or one time in five under the id of an order that has ended, and notes a problem if
    /// the ledger's answer is not what the free cash or shares say it must be. Returns whether it was accepted.
    private mutating func reserve(side: Side, symbol: UInt32, quantity: Quantity, limit: Int64) -> Bool {
        let reuse = !finishedIds.isEmpty && generator.below(100) < 20
        let id = reuse ? finishedIds.remove(at: generator.below(finishedIds.count)) : freshId()
        let value = limit * quantity
        let held = side == .buy ? value + Commission.compute(notional: value, bps: Self.bps) : 0
        let due = side == .buy ? held <= ledger.availableCash : quantity <= ledger.availableQuantity(symbolId: symbol)
        let before = ledger

        let accepted = ledger.reserve(
            orderId: id, side: side, symbolId: symbol, quantity: quantity, price: Price(satang: limit)
        )

        if accepted != due {
            note("reserve \(id) \(side) \(quantity) at \(limit) was \(accepted), due \(due)")
        }
        if accepted {
            live.append(Order(id: id, side: side, symbol: symbol, limit: limit, remaining: quantity, held: held))
            record(side == .buy ? .reservedBuy : .reservedSell)
            if reuse {
                record(.reusedOrderId)
            }
        } else {
            if ledger != before {
                note("a refused reservation changed the ledger")
            }
            if reuse {
                finishedIds.append(id)
            }
            record(side == .buy ? .refusedForCash : .refusedForShares)
        }
        return accepted
    }

    private mutating func fillRandom() {
        let index = generator.below(live.count)
        let remaining = live[index].remaining
        fill(index, quantity: generator.below(100) < 40 ? remaining : Quantity(1 + generator.below(Int(remaining))))
    }

    /// Sells every free share of one symbol in a single order and fills it at once, which closes the position if
    /// nothing else holds shares of it. Random fills hardly ever land on exactly zero.
    private mutating func liquidateRandom() {
        let symbol = UInt32(1 + generator.below(3))
        let free = ledger.availableQuantity(symbolId: symbol)
        if free > 0, reserve(side: .sell, symbol: symbol, quantity: free, limit: randomLimit()) {
            fill(live.count - 1, quantity: free)
        } else {
            reserveRandom()
        }
    }

    /// Fills `quantity` of the live order at `index`: a buy at its limit or up to three ticks better, a sell at any
    /// price. The ledger must give exactly the entry the model works out.
    private mutating func fill(_ index: Int, quantity: Quantity) {
        var order = live[index]
        let fillPrice = order.side == .buy
            ? max(order.limit - Int64(25 * generator.below(4)), 1) : Int64(25 * (1 + generator.below(240)))
        let value = fillPrice * quantity
        let fee = Commission.compute(notional: order.filledValue + value, bps: Self.bps) - order.feesCharged
        let delta = order.side == .buy ? -(value + fee) : value - fee
        let position = (positions[order.symbol] ?? 0) + (order.side == .buy ? quantity : -quantity)
        let tsNs = Int64(step) * 1_000_003

        let applied = ledger.applyFill(
            orderId: order.id, symbolId: order.symbol, side: order.side, quantity: quantity,
            price: Price(satang: fillPrice), tsNs: tsNs
        )

        guard let entry = applied else {
            note("a fill that is due was refused: \(order)")
            return
        }
        fills += 1
        cash += delta
        positions[order.symbol] = position == 0 ? nil : position
        let due = LedgerEntry(
            ledgerSeq: UInt64(fills), orderId: order.id, symbolId: order.symbol, side: order.side, quantity: quantity,
            price: Price(satang: fillPrice), commission: fee, cashDelta: delta, cashAfter: cash,
            positionAfter: position, tsNs: tsNs
        )
        if entry != due {
            note("the fill gave \(entry), due \(due)")
        }
        order.remaining -= quantity
        order.filledValue += value
        order.feesCharged += fee
        if order.side == .buy {
            order.held += delta
        }
        if order.remaining == 0 {
            live.remove(at: index)
            finishedIds.append(order.id)
            record(.finalFill)
        } else {
            live[index] = order
            record(.partialFill)
        }
        if order.side == .buy, fillPrice < order.limit {
            record(.betterPriceFill)
        }
        if order.side == .sell, position == 0 {
            record(.closedPosition)
        }
    }

    private mutating func releaseRandom() {
        let order = live.remove(at: generator.below(live.count))
        ledger.release(orderId: order.id)
        finishedIds.append(order.id)
        record(.released)
    }

    /// One call that must be refused, or ignored, and must change nothing.
    private mutating func refuseRandom() {
        let before = ledger
        let ended = finishedIds.isEmpty ? "ghost" : finishedIds[generator.below(finishedIds.count)]
        let idWithoutReservation = generator.below(2) == 0 ? "ghost" : ended
        // Most of these need a live order to aim at: without one, only the first three can be drawn.
        let kind = generator.below(live.isEmpty ? 3 : 8)

        switch kind {
        case 0: // a release for an id that has no reservation: never reserved, or ended
            ledger.release(orderId: idWithoutReservation)
            record(.releaseIgnored)
        case 1: // a fill for an id that has no reservation
            let applied = ledger.applyFill(
                orderId: idWithoutReservation, symbolId: 1, side: .buy, quantity: 100, price: Price(satang: 1000),
                tsNs: 0
            )
            expectRefused(applied, "a fill for an order with no reservation")
            record(.fillRefusedUnknown)
        case 2: // a reservation that is invalid whatever the ledger holds
            let broken = generator.below(3)
            let accepted = ledger.reserve(
                orderId: freshId(), side: generator.below(2) == 0 ? .buy : .sell, symbolId: 1,
                quantity: broken == 0 ? 0 : (broken == 1 ? -100 : 100), price: Price(satang: broken == 2 ? 0 : 1000)
            )
            expectRefused(reservation: accepted, "an invalid reservation")
            record(.refusedInvalid)
        case 3: // a reservation under the id of a live one
            let order = live[generator.below(live.count)]
            let accepted = ledger.reserve(
                orderId: order.id, side: order.side, symbolId: order.symbol, quantity: 100, price: Price(satang: 1000)
            )
            expectRefused(reservation: accepted, "a second reservation of \(order.id)")
            record(.refusedDuplicate)
        default: // a fill that does not fit the live order it names
            refuseFill(of: live[generator.below(live.count)], variant: kind)
        }
        if ledger != before {
            note("a refused call changed the ledger (kind \(kind))")
        }
    }

    private mutating func refuseFill(of order: Order, variant: Int) {
        var side = order.side
        var symbol = order.symbol
        var quantity = Quantity(1 + generator.below(Int(order.remaining)))
        var fillPrice = order.side == .buy ? order.limit : 1000
        let outcome: Outcome
        switch variant {
        case 4: // more than is left
            quantity = order.remaining + Quantity(1 + generator.below(3))
            outcome = .fillRefusedTooLarge
        case 5: // a buy above its reserved price; a sell has no such limit, so it is given another symbol instead
            if order.side == .buy {
                fillPrice = order.limit + Int64(1 + generator.below(100))
                outcome = .fillRefusedTooDear
            } else {
                symbol = symbol % 3 + 1
                outcome = .fillRefusedMismatch
            }
        case 6: // the other side
            side = order.side == .buy ? .sell : .buy
            outcome = .fillRefusedMismatch
        default: // another symbol
            symbol = symbol % 3 + 1
            outcome = .fillRefusedMismatch
        }
        let applied = ledger.applyFill(
            orderId: order.id, symbolId: symbol, side: side, quantity: quantity, price: Price(satang: fillPrice),
            tsNs: 0
        )
        expectRefused(applied, "\(outcome) for \(order.id)")
        record(outcome)
    }

    /// Notes a problem if a fill that is due to be refused (nil) was accepted.
    private mutating func expectRefused(_ fill: LedgerEntry?, _ what: String) {
        if fill != nil {
            note("\(what) was accepted")
        }
    }

    /// Notes a problem if a reservation that is due to be refused (false) was accepted.
    private mutating func expectRefused(reservation accepted: Bool, _ what: String) {
        if accepted {
            note("\(what) was accepted")
        }
    }

    /// The ledger agrees with the model, and says that its own invariants hold.
    private mutating func verify() {
        guard problems.isEmpty else { return }
        if !ledger.invariantsHold() {
            note("invariantsHold() is false")
        }
        if ledger.cash != cash {
            note("cash is \(ledger.cash), due \(cash)")
        }
        let held = live.reduce(0) { $0 + $1.held }
        if ledger.availableCash != cash - held {
            note("availableCash is \(ledger.availableCash), due \(cash - held)")
        }
        if ledger.positions != positions {
            note("positions are \(ledger.positions), due \(positions)")
        }
        for symbol in UInt32(1)...3 {
            let reserved = live.filter { $0.side == .sell && $0.symbol == symbol }.reduce(0) { $0 + $1.remaining }
            let free = (positions[symbol] ?? 0) - reserved
            if ledger.availableQuantity(symbolId: symbol) != free {
                note("availableQuantity of \(symbol) is \(ledger.availableQuantity(symbolId: symbol)), due \(free)")
            }
        }
        if ledger.entries.count != fills {
            note("the log holds \(ledger.entries.count) entries after \(fills) fills")
        }
    }
}

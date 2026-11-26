import Contracts
import Testing
import TradeCore
import TradeNetworking

/// Fills of one order, as (shares, price) pairs, and the average price they must give.
struct AverageCase: Sendable, CustomTestStringConvertible {
    let note: String
    let fills: [(quantity: Int64, price: Int64)]
    let expected: Int64

    var testDescription: String { note }
}

/// A fill of `quantity` shares into an order of 200 that leaves `remaining` unfilled, and the status that gives.
struct RemainingCase: Sendable, CustomTestStringConvertible {
    let quantity: Int64
    let remaining: Int64
    let expected: OrderStatus

    var testDescription: String { "fill \(quantity) of 200, server says \(remaining) left" }
}

/// The reason a cancel carries on the wire and the reason the row shows.
struct CancelCase: Sendable, CustomTestStringConvertible {
    let wire: Tp_RejectReason
    let reason: RejectReason?

    var testDescription: String { "\(wire)" }
}

extension TradingReducerTests {
    // MARK: The average price

    /// The average comes from the exact total, not from the rounded average of the fills before: fills of 1 share at 1,
    /// 2 and 1 satang average 1, where an average of rounded averages would say 2.
    @Test func threeFillsGiveTheExactAverageNotTheAverageOfAverages() {
        var state = reduced(events: [acceptedEvent(1, quantity: 4)])
        var averages: [Price?] = []
        for (index, price) in [Int64(1), 2, 1].enumerated() {
            let fill = fillEvent(UInt64(index) + 2, quantity: 1, price: price, remaining: 3 - Int64(index))
            state = reduced(events: [fill], from: state)
            averages.append(state.order("C-1")?.averageFillPrice)
        }
        // 1; then (1 + 2) / 2 = 1.5, which rounds up to 2; then (1 + 2 + 1) / 3 = 1.33, which rounds down to 1.
        #expect(averages == [Price(satang: 1), Price(satang: 2), Price(satang: 1)])
    }

    /// The average is the volume-weighted mean of all fills, rounded half up to a whole satang.
    @Test(arguments: [
        AverageCase(note: "one fill is its own price", fills: [(100, 3_425)], expected: 3_425),
        AverageCase(note: "a tie rounds up", fills: [(1, 1), (1, 2)], expected: 2),
        AverageCase(note: "a tie with other weights rounds up", fills: [(2, 1), (2, 2)], expected: 2),
        AverageCase(note: "below a half rounds down", fills: [(1, 1), (1, 1), (1, 2)], expected: 1),
        AverageCase(note: "above a half rounds up", fills: [(1, 1), (1, 2), (1, 2)], expected: 2),
        AverageCase(note: "the bigger fill weighs more", fills: [(3, 1), (1, 2)], expected: 1),
        AverageCase(note: "100 at 34.25 and 100 at 34.50", fills: [(100, 3_425), (100, 3_450)], expected: 3_438),
        AverageCase(note: "a price of zero is a price", fills: [(1, 0), (1, 1)], expected: 1),
        AverageCase(note: "a price of zero alone", fills: [(5, 0)], expected: 0),
        AverageCase(note: "a small fill after a big one", fills: [(1_000_000, 3_425), (1, 3_426)], expected: 3_425),
    ])
    func theAverageIsTheHalfUpWeightedMeanOfAllFills(example: AverageCase) throws {
        var state = reduced(events: [acceptedEvent(1, quantity: 10_000_000)])
        var seq: UInt64 = 1
        var total: Int64 = 0
        for fill in example.fills {
            seq += 1
            total += fill.quantity
            state = reduced(
                events: [fillEvent(seq, quantity: fill.quantity, price: fill.price, remaining: 5_000_000)], from: state)
        }
        let row = try #require(state.order("C-1"))
        #expect(row.averageFillPrice == Price(satang: example.expected))
        #expect(row.filledQuantity == total)
    }

    // MARK: Fills the rules cannot use

    /// A fill of no shares is no fill: the row is left alone even if the server says nothing remains.
    @Test(arguments: [0, -1, Int64.min] as [Int64])
    func aFillOfNoSharesLeavesTheRowAlone(quantity: Int64) {
        let open = reduced(events: [
            acceptedEvent(1, quantity: 200), fillEvent(2, quantity: 100, price: 3_425, remaining: 100),
        ])
        var expected = open
        expected.lastEventSeq = 3
        #expect(reduced(events: [fillEvent(3, quantity: quantity, price: 3_450, remaining: 0)], from: open) == expected)
        // One share of the same fill does change the row.
        let control = reduced(events: [fillEvent(3, quantity: 1, price: 3_450, remaining: 0)], from: open)
        #expect(control.order("C-1")?.status == .filled)
        #expect(control.order("C-1")?.filledQuantity == 101)
    }

    /// A negative price is malformed and leaves the row alone; a price of 0 is a price.
    @Test(arguments: [-1, Int64.min] as [Int64])
    func aFillWithANegativePriceLeavesTheRowAlone(price: Int64) throws {
        let open = reduced(events: [
            acceptedEvent(1, quantity: 200), fillEvent(2, quantity: 100, price: 3_425, remaining: 100),
        ])
        var expected = open
        expected.lastEventSeq = 3
        #expect(reduced(events: [fillEvent(3, quantity: 100, price: price, remaining: 0)], from: open) == expected)

        let free = reduced(events: [fillEvent(3, quantity: 100, price: 0, remaining: 0)], from: open)
        let row = try #require(free.order("C-1"))
        #expect(row.filledQuantity == 200)
        // 100 at 34.25 and 100 at 0: 1712.5, rounded up.
        #expect(row.averageFillPrice == Price(satang: 1_713))
        #expect(row.status == .filled)
    }

    /// A fill for an order the state has no row for leaves the rows alone, and the ledger entry that follows it still
    /// sets cash and the position, because those come from the ledger and never from the fill.
    @Test func aFillForAnUnknownOrderLeavesTheRowsAloneButTheLedgerEntryStillSetsCash() {
        let open = reduced(
            [.localSubmitted(draft("C-2"), createdNs: 50)],
            from: reduced(events: [acceptedEvent(1, quantity: 200)]))
        let strayFill = fillEvent(2, order: "O-000099", quantity: 100, price: 3_425, remaining: 0)
        var expected = open
        expected.lastEventSeq = 2
        let afterFill = reduced(events: [strayFill], from: open)
        #expect(afterFill == expected)
        // The pending row has no server id yet, and an empty id is not "no id".
        let emptyId = fillEvent(2, order: "", quantity: 100, price: 3_425, remaining: 0)
        #expect(reduced(events: [emptyId], from: open) == expected)

        let ledger = ledgerEvent(
            3, ledgerSeq: 1, order: "O-000099", quantity: 100, price: 3_425, commission: 342, cashDelta: -342_842,
            cashAfter: 99_657_158, positionAfter: 100)
        let afterLedger = reduced(events: [ledger], from: afterFill)
        #expect(afterLedger.cash == 99_657_158)
        #expect(afterLedger.positions == [1: 100])
        #expect(afterLedger.orders == open.orders)
        #expect(afterLedger.ledger.count == 1)

        // A fill for the order that exists is applied.
        let control = reduced(events: [fillEvent(2, quantity: 100, price: 3_425, remaining: 100)], from: open)
        #expect(control.order("C-1")?.filledQuantity == 100)
        #expect(control.order("C-2")?.filledQuantity == 0)
    }

    /// A fill finds its row by the server's order id: the fills of two open orders go to their own rows.
    @Test func eachFillGoesToItsOwnOrder() {
        let open = reduced(events: [
            acceptedEvent(1, client: "C-1", order: "O-000001", quantity: 200),
            acceptedEvent(2, client: "C-2", order: "O-000002", quantity: 500),
        ])
        let first = reduced(
            events: [fillEvent(3, order: "O-000001", quantity: 80, price: 3_400, remaining: 120)], from: open)
        #expect(first.order("C-1")?.filledQuantity == 80)
        #expect(first.order("C-2")?.filledQuantity == 0)
        let second = reduced(
            events: [fillEvent(4, order: "O-000002", quantity: 500, price: 1_000, remaining: 0)], from: first)
        #expect(second.order("C-1")?.filledQuantity == 80)
        #expect(second.order("C-1")?.status == .partiallyFilled)
        #expect(second.order("C-2")?.filledQuantity == 500)
        #expect(second.order("C-2")?.status == .filled)
    }

    // MARK: The status after a fill

    /// What the server says is left decides the status, not a comparison of the filled shares with the order's.
    @Test(arguments: [
        RemainingCase(quantity: 100, remaining: 100, expected: .partiallyFilled),
        RemainingCase(quantity: 200, remaining: 0, expected: .filled),
        RemainingCase(quantity: 100, remaining: 0, expected: .filled),
        RemainingCase(quantity: 200, remaining: 50, expected: .partiallyFilled),
        RemainingCase(quantity: 100, remaining: -1, expected: .filled),
        RemainingCase(quantity: 100, remaining: Int64.min, expected: .filled),
        RemainingCase(quantity: 100, remaining: Int64.max, expected: .partiallyFilled),
        RemainingCase(quantity: 1, remaining: 1, expected: .partiallyFilled),
    ])
    func remainingDecidesPartiallyFilledOrFilled(example: RemainingCase) throws {
        let open = reduced(events: [acceptedEvent(1, quantity: 200)])
        let after = reduced(
            events: [fillEvent(2, quantity: example.quantity, price: 3_425, remaining: example.remaining)], from: open)
        let row = try #require(after.order("C-1"))
        #expect(row.status == example.expected)
        #expect(row.filledQuantity == example.quantity)
    }

    // MARK: Cancels

    /// A cancel ends an open order and keeps what it had filled and the average of it. The reason the engine gave for
    /// cutting the order short is kept; an ordinary cancel gives none, and a reason this build does not know is none.
    @Test(arguments: [
        CancelCase(wire: .unspecified, reason: nil),
        CancelCase(wire: .noLiquidity, reason: .noLiquidity),
        CancelCase(wire: .insufficientFunds, reason: .insufficientFunds),
        CancelCase(wire: .UNRECOGNIZED(42), reason: nil),
    ])
    func aCancelKeepsTheFilledDataAndTheReasonTheEngineGave(example: CancelCase) throws {
        let state = reduced(events: [
            acceptedEvent(1, quantity: 200),
            fillEvent(2, quantity: 100, price: 3_425, remaining: 100),
            fillEvent(3, quantity: 50, price: 3_450, remaining: 50),
        ])
        let after = reduced(events: [cancelledEvent(4, remaining: 50, reason: example.wire)], from: state)

        let row = try #require(after.order("C-1"))
        #expect(row.status == .cancelled)
        #expect(row.filledQuantity == 150)
        // (100 * 3425 + 50 * 3450) / 150 is 3433.3.
        #expect(row.averageFillPrice == Price(satang: 3_433))
        #expect(row.quantity == 200)
        #expect(row.rejectReason == example.reason)
    }

    /// Only an open order can be cancelled: an unknown order id is ignored, and so is the order a pending row will
    /// become, which has no server id yet.
    @Test func aCancelForAnUnknownOrderIsIgnored() {
        let state = stateWithEveryStatus()
        var expected = state
        expected.lastEventSeq = 8
        #expect(reduced(events: [cancelledEvent(8, order: "O-000404", reason: .noLiquidity)], from: state) == expected)
        #expect(reduced(events: [cancelledEvent(8, order: "")], from: state) == expected)
        // An accepted row and a partly filled one can be cancelled.
        let cancelledOpen = reduced(events: [cancelledEvent(8, order: "O-000001")], from: state)
        let cancelledPart = reduced(events: [cancelledEvent(8, order: "O-000002")], from: state)
        #expect(cancelledOpen.order("C-open")?.status == .cancelled)
        #expect(cancelledPart.order("C-part")?.status == .cancelled)
    }

    // MARK: Extreme and hand-built rows

    /// Fills of the biggest numbers neither wrap nor trap: the shares saturate at `Int64.max`, the exact total (128
    /// bits) saturates too, and the average, clamped to `Int64`, stays the biggest price.
    @Test func hugeFillsSaturateInsteadOfTrapping() throws {
        var state = reduced(events: [acceptedEvent(1, quantity: Int64.max)])
        for seq in UInt64(2)...5 {
            let fill = fillEvent(seq, quantity: Int64.max, price: Int64.max, remaining: 1)
            state = reduced(events: [fill], from: state)
        }
        let row = try #require(state.order("C-1"))
        #expect(state.lastEventSeq == 5)
        #expect(row.filledQuantity == Int64.max)
        #expect(row.averageFillPrice == Price(satang: Int64.max))
        #expect(row.status == .partiallyFilled)
    }

    /// A row built by hand carries on from its average: the next fill is weighed against the shares and the price the
    /// row shows.
    @Test func aRowBuiltByHandContinuesFromItsAverage() throws {
        var state = TradingState()
        state.epoch = "E1"
        state.lastEventSeq = 1
        state.orders = [
            OrderRow(
                id: "C-1", orderId: "O-000001", symbolId: 1, side: .buy, type: .market, quantity: 400,
                filledQuantity: 100, averageFillPrice: Price(satang: 3_400), status: .partiallyFilled, createdNs: 5),
            OrderRow(
                id: "C-2", orderId: "O-000002", symbolId: 1, side: .buy, type: .market, quantity: 400,
                status: .accepted, createdNs: 6),
        ]
        let after = reduced(
            events: [
                fillEvent(2, order: "O-000001", quantity: 100, price: 3_450, remaining: 200),
                fillEvent(3, order: "O-000002", quantity: 100, price: 3_450, remaining: 300),
            ], from: state)
        // (100 * 3400 + 100 * 3450) / 200 is 3425; a row with nothing filled starts from the fill.
        #expect(after.order("C-1")?.averageFillPrice == Price(satang: 3_425))
        #expect(after.order("C-1")?.filledQuantity == 200)
        #expect(after.order("C-2")?.averageFillPrice == Price(satang: 3_450))
    }

    /// A row built by hand with a negative number of filled shares can end a fill with none: the average is then
    /// unknown (nil), never a division by zero or by a negative number.
    @Test(arguments: [5, 3] as [Int64])
    func aRowWithNegativeFilledSharesNeverDividesByZero(quantity: Int64) throws {
        var state = TradingState()
        state.epoch = "E1"
        state.lastEventSeq = 1
        state.orders = [
            OrderRow(
                id: "C-1", orderId: "O-000001", symbolId: 1, side: .buy, type: .market, quantity: 10,
                filledQuantity: -5, status: .accepted, createdNs: 5)
        ]
        let after = reduced(
            events: [fillEvent(2, quantity: quantity, price: 3_400, remaining: 1)], from: state)
        let row = try #require(after.order("C-1"))
        #expect(row.filledQuantity == quantity - 5)
        #expect(row.averageFillPrice == nil)
        #expect(row.status == .partiallyFilled)
    }
}

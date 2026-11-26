import Contracts
import Testing
import TradeCore
import TradeNetworking

/// An order row that differs from `fullRow()` in exactly one public property, the one named.
struct RowDifference: Sendable, CustomTestStringConvertible {
    let property: String
    let row: OrderRow

    var testDescription: String { property }
}

/// A row with a distinct value in every public property. An argument that is given replaces the value of that
/// property and of no other.
private func fullRow(
    id: String = "C-1", orderId: String? = "O-000001", symbolId: UInt32 = 1, side: Side = .buy,
    type: OrderType = .limit, quantity: Quantity = 200, limitPrice: Price? = Price(satang: 3_400),
    filledQuantity: Quantity = 100, averageFillPrice: Price? = Price(satang: 3_425),
    status: OrderStatus = .partiallyFilled, rejectReason: RejectReason? = .noLiquidity, createdNs: Int64 = 5
) -> OrderRow {
    OrderRow(
        id: id, orderId: orderId, symbolId: symbolId, side: side, type: type, quantity: quantity,
        limitPrice: limitPrice, filledQuantity: filledQuantity, averageFillPrice: averageFillPrice, status: status,
        rejectReason: rejectReason, createdNs: createdNs)
}

extension TradingReducerTests {
    // MARK: Equality of rows

    /// Rows are equal when every public property is equal, so a change to any one of them is a change to the row.
    @Test(arguments: [
        RowDifference(property: "id", row: fullRow(id: "C-2")),
        RowDifference(property: "orderId", row: fullRow(orderId: "O-000002")),
        RowDifference(property: "orderId absent", row: fullRow(orderId: nil)),
        RowDifference(property: "symbolId", row: fullRow(symbolId: 2)),
        RowDifference(property: "side", row: fullRow(side: .sell)),
        RowDifference(property: "type", row: fullRow(type: .market)),
        RowDifference(property: "quantity", row: fullRow(quantity: 201)),
        RowDifference(property: "limitPrice", row: fullRow(limitPrice: Price(satang: 3_401))),
        RowDifference(property: "limitPrice absent", row: fullRow(limitPrice: nil)),
        RowDifference(property: "filledQuantity", row: fullRow(filledQuantity: 101)),
        RowDifference(property: "averageFillPrice", row: fullRow(averageFillPrice: Price(satang: 3_426))),
        RowDifference(property: "averageFillPrice absent", row: fullRow(averageFillPrice: nil)),
        RowDifference(property: "status", row: fullRow(status: .filled)),
        RowDifference(property: "rejectReason", row: fullRow(rejectReason: .invalidLot)),
        RowDifference(property: "rejectReason absent", row: fullRow(rejectReason: nil)),
        RowDifference(property: "createdNs", row: fullRow(createdNs: 6)),
    ])
    func rowsThatDifferInOnePropertyAreNotEqual(example: RowDifference) {
        #expect(example.row != fullRow())
        // The same row built twice is equal, so the difference above is the one property.
        #expect(fullRow() == fullRow())
    }

    /// The exact total behind the average is not a property of the row. A row built by hand from the average that is
    /// shown equals the row the reducer built from the fills, although the two totals differ (687,500 satang from
    /// the fills, 687,600 from the rounded average).
    @Test func rowsThatDifferOnlyInTheExactTotalAreEqual() throws {
        let fromFills = reduced(events: [
            acceptedEvent(1, quantity: 200),
            fillEvent(2, quantity: 100, price: 3_425, remaining: 100),
            fillEvent(3, quantity: 100, price: 3_450, remaining: 0),
        ])
        let built = try #require(fromFills.order("C-1"))
        #expect(built.averageFillPrice == Price(satang: 3_438))

        let byHand = OrderRow(
            id: "C-1", orderId: "O-000001", symbolId: 1, side: .buy, type: .market, quantity: 200,
            filledQuantity: 200, averageFillPrice: Price(satang: 3_438), status: .filled, createdNs: 1_000)
        #expect(built == byHand)
    }

    // MARK: Initialisers

    /// Every initialiser keeps each value it is given in the property of that name. The tests of the reducer build
    /// the rows they expect with the same initialisers, so they would not see a value that went to the wrong place.
    @Test func aRowKeepsEveryValueItIsGiven() {
        let row = OrderRow(
            id: "C-7", orderId: "O-000007", symbolId: 7, side: .sell, type: .limit, quantity: 700,
            limitPrice: Price(satang: 7_001), filledQuantity: 70, averageFillPrice: Price(satang: 7_002),
            status: .cancelled, rejectReason: .invalidTick, createdNs: 77)
        #expect(row.id == "C-7")
        #expect(row.orderId == "O-000007")
        #expect(row.symbolId == 7)
        #expect(row.side == .sell)
        #expect(row.type == .limit)
        #expect(row.quantity == 700)
        #expect(row.limitPrice == Price(satang: 7_001))
        #expect(row.filledQuantity == 70)
        #expect(row.averageFillPrice == Price(satang: 7_002))
        #expect(row.status == .cancelled)
        #expect(row.rejectReason == .invalidTick)
        #expect(row.createdNs == 77)
    }

    /// A row given only what a submit knows is a pending row with nothing from the server and nothing filled.
    @Test func aRowStartsPendingWithNothingFromTheServer() {
        let row = OrderRow(id: "C-1", symbolId: 1, side: .buy, type: .market, quantity: 100)
        #expect(row.orderId == nil)
        #expect(row.limitPrice == nil)
        #expect(row.filledQuantity == 0)
        #expect(row.averageFillPrice == nil)
        #expect(row.status == .pending)
        #expect(row.rejectReason == nil)
        #expect(row.createdNs == 0)
    }

    /// A draft of a limit order keeps its limit price; a draft of a market order has none.
    @Test func aDraftKeepsEveryValueItIsGiven() {
        let limit = OrderDraft(
            clientOrderId: "C-7", symbolId: 7, side: .sell, type: .limit, quantity: 700,
            limitPrice: Price(satang: 7_001))
        #expect(limit.clientOrderId == "C-7")
        #expect(limit.symbolId == 7)
        #expect(limit.side == .sell)
        #expect(limit.type == .limit)
        #expect(limit.quantity == 700)
        #expect(limit.limitPrice == Price(satang: 7_001))

        let market = OrderDraft(clientOrderId: "C-8", symbolId: 8, side: .buy, type: .market, quantity: 800)
        #expect(market.limitPrice == nil)
        #expect(market.side == .buy)
        #expect(market.type == .market)
    }

    /// A ledger row keeps the commission and the cash change apart: two numbers of one type are easy to swap.
    @Test func aLedgerRowKeepsEveryValueItIsGiven() {
        let row = LedgerRow(
            id: 7, orderId: "O-000007", symbolId: 70, side: .sell, quantity: 700, price: Price(satang: 7_001),
            commission: 702, cashDelta: 703, tsNs: 704)
        #expect(row.id == 7)
        #expect(row.orderId == "O-000007")
        #expect(row.symbolId == 70)
        #expect(row.side == .sell)
        #expect(row.quantity == 700)
        #expect(row.price == Price(satang: 7_001))
        #expect(row.commission == 702)
        #expect(row.cashDelta == 703)
        #expect(row.tsNs == 704)
    }
}

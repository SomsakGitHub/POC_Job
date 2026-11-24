import Contracts
import Testing
import TradeCore
import TradeNetworking

/// An `accepted` event that lacks one thing the reducer needs to make a row out of it.
enum UnusableAccepted: String, CaseIterable, Sendable {
    case emptyClientId, emptyOrderId, unspecifiedSide, unrecognisedSide, unspecifiedType, unrecognisedType

    /// The event, numbered 1.
    var event: Tp_OrderEvent {
        switch self {
        case .emptyClientId: acceptedEvent(1, client: "")
        case .emptyOrderId: acceptedEvent(1, order: "")
        case .unspecifiedSide: acceptedEvent(1, side: .unspecified)
        case .unrecognisedSide: acceptedEvent(1, side: .UNRECOGNIZED(9))
        case .unspecifiedType: acceptedEvent(1, type: .unspecified)
        case .unrecognisedType: acceptedEvent(1, type: .UNRECOGNIZED(9))
        }
    }
}

/// A row that has ended, with the server id it has (or one nobody has, for a row the server never saw).
struct EndedRow: Sendable, CustomTestStringConvertible {
    let client: String
    let order: String

    var testDescription: String { client }
}

extension TradingReducerTests {
    // MARK: The row of a submit

    /// A submit makes a pending row with every field from the draft and nothing from the server, and touches nothing
    /// else: it is not an event of any epoch.
    @Test func localSubmittedCreatesAPendingRow() {
        let state = reduced([
            .localSubmitted(
                draft("C-1", symbol: 7, side: .sell, type: .limit, quantity: 300, limit: 3_450), createdNs: 1_234)
        ])
        let expected = OrderRow(
            id: "C-1", orderId: nil, symbolId: 7, side: .sell, type: .limit, quantity: 300,
            limitPrice: Price(satang: 3_450), filledQuantity: 0, averageFillPrice: nil, status: .pending,
            rejectReason: nil, createdNs: 1_234)
        var rowOnly = TradingState()
        rowOnly.orders = [expected]
        #expect(state == rowOnly)
    }

    /// Two submits with one client order id make one row. The second is ignored whole, so a retry cannot overwrite the
    /// first, and neither can the id of an order that was replayed from the log.
    @Test func localSubmittedTwiceWithOneIdLeavesOneRow() {
        let once = reduced([.localSubmitted(draft("C-1", quantity: 200), createdNs: 100)])
        #expect(once.orders.count == 1)
        let again = draft("C-1", symbol: 9, side: .sell, type: .limit, quantity: 900, limit: 5_000)
        #expect(reduced([.localSubmitted(again, createdNs: 999)], from: once) == once)

        let replayed = reduced(events: [acceptedEvent(1, client: "C-7", order: "O-000007")])
        #expect(replayed.orders.count == 1)
        #expect(reduced([.localSubmitted(draft("C-7"), createdNs: 999)], from: replayed) == replayed)

        // Another id is a new row.
        let both = reduced([.localSubmitted(draft("C-2"), createdNs: 200)], from: once)
        #expect(both.orders.map(\.id) == ["C-2", "C-1"])
    }

    /// A new row goes in front of the others and a row that changes keeps its place, so a list does not jump.
    @Test func newRowsGoFirstAndChangedRowsKeepTheirPlace() {
        var state = reduced([
            .localSubmitted(draft("C-1"), createdNs: 100),
            .localSubmitted(draft("C-2"), createdNs: 200),
            .localSubmitted(draft("C-3"), createdNs: 300),
        ])
        #expect(state.orders.map(\.id) == ["C-3", "C-2", "C-1"])

        state = reduced(
            events: [
                acceptedEvent(1, client: "C-2", order: "O-000002"),
                fillEvent(2, order: "O-000002", quantity: 200, price: 3_425, remaining: 0),
            ], from: state)
        #expect(state.orders.map(\.id) == ["C-3", "C-2", "C-1"])
        #expect(state.orders.map(\.status) == [.pending, .filled, .pending])

        // An order the app never saw goes in front too.
        state = reduced(events: [acceptedEvent(3, client: "C-4", order: "O-000004")], from: state)
        #expect(state.orders.map(\.id) == ["C-4", "C-3", "C-2", "C-1"])
    }

    // MARK: What the submit call answers

    /// A refusal ends a row that is waiting for its answer, whether it is pending or its answer was lost.
    @Test(arguments: ["C-pending", "C-unknown"])
    func submitRejectedEndsAnUnansweredRow(id: String) throws {
        let state = stateWithEveryStatus()
        let after = reduced([.submitRejected(clientOrderId: id, reason: .outsidePriceBand)], from: state)
        let expected = try state.editing(id) {
            $0.status = .rejected
            $0.rejectReason = .outsidePriceBand
        }
        #expect(after == expected)
    }

    /// Once the server has answered, a late refusal of the submit call must not rewrite the row.
    @Test(arguments: ["C-open", "C-part", "C-filled", "C-cancelled", "C-rejected"])
    func submitRejectedChangesNothingOnceTheServerHasAnswered(id: String) {
        let state = stateWithEveryStatus()
        #expect(reduced([.submitRejected(clientOrderId: id, reason: .invalidTick)], from: state) == state)
        // The same action does change a row that is still waiting, so the check above is not an accident.
        #expect(reduced([.submitRejected(clientOrderId: "C-pending", reason: .invalidTick)], from: state) != state)
    }

    /// A submit without an answer turns a pending row into `.unknown` and changes nothing else.
    @Test func submitUnconfirmedMarksAPendingRow() throws {
        let state = stateWithEveryStatus()
        let after = reduced([.submitUnconfirmed(clientOrderId: "C-pending")], from: state)
        let expected = try state.editing("C-pending") { $0.status = .unknown }
        #expect(after == expected)
    }

    /// Only a pending row can become unknown: an unknown row stays so, and an answered row keeps its answer.
    @Test(arguments: ["C-unknown", "C-open", "C-part", "C-filled", "C-cancelled", "C-rejected"])
    func submitUnconfirmedChangesNothingOnceTheRowMovedOn(id: String) {
        let state = stateWithEveryStatus()
        #expect(reduced([.submitUnconfirmed(clientOrderId: id)], from: state) == state)
        #expect(reduced([.submitUnconfirmed(clientOrderId: "C-pending")], from: state) != state)
    }

    /// An answer about an order the state has no row for is ignored; it does not make a row.
    @Test func answersForAnUnknownIdAreIgnored() {
        let state = stateWithEveryStatus()
        #expect(reduced([.submitRejected(clientOrderId: "C-404", reason: .invalidLot)], from: state) == state)
        #expect(reduced([.submitUnconfirmed(clientOrderId: "C-404")], from: state) == state)
        // The same answers about a row that exists are applied.
        #expect(reduced([.submitRejected(clientOrderId: "C-pending", reason: .invalidLot)], from: state) != state)
        #expect(reduced([.submitUnconfirmed(clientOrderId: "C-pending")], from: state) != state)
    }

    // MARK: The accepted event

    /// The server's answer is the truth about the order: its symbol, side, type, quantity and limit price replace the
    /// draft's, and the row keeps the time at which the app created it.
    @Test func acceptedTakesTheServersFieldsAndKeepsTheCreationTime() throws {
        let state = reduced([.localSubmitted(draft("C-1", quantity: 200), createdNs: 100)])
        let after = reduced(
            events: [
                acceptedEvent(
                    1, tsNs: 7_000, client: "C-1", order: "O-000042", symbol: 5, side: .sell, type: .limit,
                    quantity: 300, limitPrice: 3_450)
            ], from: state)

        #expect(after.orders.count == 1)
        let expected = OrderRow(
            id: "C-1", orderId: "O-000042", symbolId: 5, side: .sell, type: .limit, quantity: 300,
            limitPrice: Price(satang: 3_450), filledQuantity: 0, averageFillPrice: nil, status: .accepted,
            rejectReason: nil, createdNs: 100)
        #expect(after.order("C-1") == expected)
    }

    /// A side or a type this build does not know leaves the row's own value in place.
    @Test func anUnmappableSideOrTypeKeepsTheRowsOwn() throws {
        let state = reduced([
            .localSubmitted(draft("C-1", side: .sell, type: .limit, quantity: 200, limit: 3_450), createdNs: 100)
        ])
        let after = reduced(
            events: [acceptedEvent(1, side: .UNRECOGNIZED(9), type: .unspecified, quantity: 200, limitPrice: 3_450)],
            from: state)
        let row = try #require(after.order("C-1"))
        #expect(row.status == .accepted)
        #expect(row.side == .sell)
        #expect(row.type == .limit)
    }

    /// On the wire a limit price of 0 means there is none, so a market order never shows a price of 0.
    @Test func aLimitPriceOfZeroMeansNoLimitPrice() throws {
        let state = reduced([
            .localSubmitted(draft("C-1", type: .limit, quantity: 200, limit: 3_450), createdNs: 100),
            .localSubmitted(draft("C-2", type: .limit, quantity: 200, limit: 3_450), createdNs: 110),
        ])
        let after = reduced(
            events: [
                acceptedEvent(1, client: "C-1", order: "O-000001", type: .market, limitPrice: 0),
                acceptedEvent(2, client: "C-2", order: "O-000002", type: .limit, limitPrice: 3_400),
            ], from: state)
        #expect(after.order("C-1")?.limitPrice == nil)
        #expect(after.order("C-2")?.limitPrice == Price(satang: 3_400))
    }

    /// After a relaunch the log holds orders the app has no row for; the event makes the row, stamped with the
    /// server's time because that is the only time there is.
    @Test func acceptedCreatesARowForAnOrderTheAppNeverSaw() {
        let after = reduced(events: [
            acceptedEvent(
                1, tsNs: 8_888, client: "C-7", order: "O-000007", symbol: 4, side: .sell, type: .limit, quantity: 500,
                limitPrice: 3_450)
        ])
        let expected = OrderRow(
            id: "C-7", orderId: "O-000007", symbolId: 4, side: .sell, type: .limit, quantity: 500,
            limitPrice: Price(satang: 3_450), filledQuantity: 0, averageFillPrice: nil, status: .accepted,
            rejectReason: nil, createdNs: 8_888)
        #expect(after.orders == [expected])
        #expect(after.lastEventSeq == 1)
        #expect(after.epoch == "E1")
    }

    /// An event that cannot make a row (no client id, no server id, a side or type that does not map) is ignored, and
    /// still counts as the event it is.
    @Test(arguments: UnusableAccepted.allCases)
    func anAcceptedEventThatCannotMakeARowIsIgnored(kind: UnusableAccepted) {
        let after = reduced(events: [kind.event])
        #expect(after.orders.isEmpty)
        #expect(after.lastEventSeq == 1)
        #expect(after.epoch == "E1")
        // With every field usable the same event makes a row.
        #expect(reduced(events: [acceptedEvent(1)]).orders.count == 1)
    }

    /// Without a server id an accepted order could never be found again by its fills, so the row stays as it was.
    @Test func anAcceptedEventWithoutAServerIdLeavesAPendingRowPending() throws {
        let state = reduced([.localSubmitted(draft("C-1"), createdNs: 100)])
        let after = reduced(events: [acceptedEvent(1, client: "C-1", order: "")], from: state)
        var expected = state
        expected.epoch = "E1"
        expected.lastEventSeq = 1
        #expect(after == expected)
        // With a server id the row is accepted.
        #expect(reduced(events: [acceptedEvent(1, client: "C-1")], from: state).order("C-1")?.status == .accepted)
    }

    /// Only a row waiting for its answer takes an accepted event: a repeat for an accepted order, or one for an order
    /// that ended, changes nothing.
    @Test(arguments: ["C-open", "C-part", "C-filled", "C-cancelled", "C-rejected"])
    func acceptedChangesNothingOnceTheRowHasMovedOn(id: String) {
        let state = stateWithEveryStatus()
        let late = acceptedEvent(
            8, client: id, order: "O-000077", symbol: 9, side: .sell, type: .limit, quantity: 5, limitPrice: 1)
        var expected = state
        expected.lastEventSeq = 8
        #expect(reduced(events: [late], from: state) == expected)
        // A row that is waiting does take it.
        let waiting = acceptedEvent(8, client: "C-pending", order: "O-000077")
        #expect(reduced(events: [waiting], from: state).order("C-pending")?.status == .accepted)
    }

    // MARK: The rejected event

    /// The event log settles a submit the same way the call's answer does.
    @Test(arguments: ["C-pending", "C-unknown"])
    func aRejectedEventEndsAnUnansweredRow(id: String) throws {
        let state = stateWithEveryStatus()
        let after = reduced(events: [rejectedEvent(8, client: id, reason: .insufficientPosition)], from: state)
        var expected = try state.editing(id) {
            $0.status = .rejected
            $0.rejectReason = .insufficientPosition
        }
        expected.lastEventSeq = 8
        #expect(after == expected)
    }

    /// A reason this build does not know (or none) still ends the row, with no reason shown.
    @Test(arguments: [Tp_RejectReason.unspecified, .UNRECOGNIZED(77)])
    func aRejectionWithoutAKnownReasonStillEndsTheRow(wire: Tp_RejectReason) throws {
        let state = reduced([.localSubmitted(draft("C-1"), createdNs: 100)])
        let after = reduced(events: [rejectedEvent(1, client: "C-1", reason: wire)], from: state)
        let row = try #require(after.order("C-1"))
        #expect(row.status == .rejected)
        #expect(row.rejectReason == nil)
    }

    /// An order the app never saw has no side, type or quantity to show, so its rejection makes no row; and a row that
    /// was answered already is not rewritten.
    @Test(arguments: ["C-open", "C-part", "C-filled", "C-cancelled", "C-rejected", "C-404"])
    func aRejectedEventChangesNoRowThatAnsweredOrDoesNotExist(id: String) {
        let state = stateWithEveryStatus()
        var expected = state
        expected.lastEventSeq = 8
        #expect(reduced(events: [rejectedEvent(8, client: id, reason: .noLiquidity)], from: state) == expected)
        // A row that is waiting does take it.
        let waiting = reduced(events: [rejectedEvent(8, client: "C-pending")], from: state)
        #expect(waiting.order("C-pending")?.status == .rejected)
    }

    // MARK: Rows that have ended

    /// A filled, cancelled or rejected row never changes again, whatever the log or the app says about it later.
    @Test(arguments: [
        EndedRow(client: "C-filled", order: "O-000003"), EndedRow(client: "C-cancelled", order: "O-000004"),
        EndedRow(client: "C-rejected", order: "O-000099"),
    ])
    func anEndedRowNeverChanges(row: EndedRow) {
        let state = stateWithEveryStatus()
        let events = [
            acceptedEvent(
                8, client: row.client, order: "O-000077", symbol: 9, side: .sell, type: .limit, quantity: 5,
                limitPrice: 1),
            rejectedEvent(9, client: row.client, reason: .noLiquidity),
            fillEvent(10, order: row.order, quantity: 10, price: 1, remaining: 0),
            cancelledEvent(11, order: row.order, remaining: 0, reason: .noLiquidity),
        ]
        let afterEvents = reduced(events: events, from: state)
        let afterSubmits = reduced(
            [
                .submitRejected(clientOrderId: row.client, reason: .invalidLot),
                .submitUnconfirmed(clientOrderId: row.client),
                .localSubmitted(draft(row.client, quantity: 1), createdNs: 1),
            ], from: afterEvents)

        var expected = state
        expected.lastEventSeq = 11
        #expect(afterSubmits == expected)
        // The same events do move an open row, so the ended rows above were not skipped by accident.
        let fill = fillEvent(8, order: "O-000001", quantity: 10, price: 1, remaining: 0)
        #expect(reduced(events: [fill], from: state).order("C-open")?.status == .filled)
    }
}

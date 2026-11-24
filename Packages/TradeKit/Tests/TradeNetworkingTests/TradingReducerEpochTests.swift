import Contracts
import Testing
import TradeCore
import TradeNetworking

/// An event the gate must turn away whole, named for what is wrong with it.
struct MalformedEvent: Sendable, CustomTestStringConvertible {
    let note: String
    let event: Tp_OrderEvent

    var testDescription: String { note }
}

extension TradingReducerTests {
    // MARK: The event gate

    /// An event numbered 0 or without an epoch says nothing the state can trust, so it is ignored whole: not applied,
    /// not counted, and above all not allowed to start a new epoch and clear the rows.
    @Test(arguments: [
        MalformedEvent(note: "sequence 0", event: acceptedEvent(0, client: "C-2", order: "O-000002")),
        MalformedEvent(note: "empty epoch", event: acceptedEvent(3, epoch: "", client: "C-2", order: "O-000002")),
        MalformedEvent(
            note: "sequence 0 in a new epoch",
            event: acceptedEvent(0, epoch: "E2", client: "C-2", order: "O-000002")),
        MalformedEvent(
            note: "sequence 0 and an empty epoch",
            event: acceptedEvent(0, epoch: "", client: "C-2", order: "O-000002")),
    ])
    func aMalformedEventChangesNothing(example: MalformedEvent) {
        let state = reduced(events: [acceptedEvent(1), fillEvent(2, quantity: 100, price: 3_425, remaining: 100)])
        #expect(reduced(events: [example.event], from: state) == state)
        // A state that has seen nothing adopts nothing from it.
        #expect(reduced(events: [example.event]) == TradingState())

        // Well formed, the same payload is applied, and in a new epoch it clears first.
        let numbered = reduced(events: [acceptedEvent(3, client: "C-2", order: "O-000002")], from: state)
        #expect(numbered.orders.map(\.id) == ["C-2", "C-1"])
        let restarted = reduced(events: [acceptedEvent(1, epoch: "E2", client: "C-2", order: "O-000002")], from: state)
        #expect(restarted.orders.map(\.id) == ["C-2"])
        #expect(restarted.epochChanges == 1)
    }

    /// An event that carries nothing still happened: it takes its place in the numbering.
    @Test func anEventWithNoPayloadAdvancesTheSequence() {
        let state = reduced(events: [acceptedEvent(1), fillEvent(2, quantity: 100, price: 3_425, remaining: 100)])
        let after = reduced(events: [orderEvent(3)], from: state)
        var expected = state
        expected.lastEventSeq = 3
        #expect(after == expected)
        #expect(reduced(events: [orderEvent(3)], from: after) == after)

        let fresh = reduced(events: [orderEvent(1)])
        var launched = TradingState()
        launched.epoch = "E1"
        launched.lastEventSeq = 1
        #expect(fresh == launched)
    }

    /// A payload whose every field holds its default (an empty id, no shares, a side that is not one) is the emptiest
    /// message the schema allows. An accepted, rejected, fill or cancelled payload finds nothing to act on. A ledger
    /// entry is absolute, so it sets cash to 0, but it makes no row without a side and removes only the position of
    /// symbol 0, which is not held. None of them traps, and each event takes its place in the numbering.
    @Test func aPayloadOfDefaultValuesIsHarmless() {
        let state = reduced(
            events: [
                ledgerEvent(8, ledgerSeq: 1, quantity: 100, price: 3_430, cashAfter: 99_000_000, positionAfter: 100)
            ], from: stateWithEveryStatus())
        var expected = state
        expected.lastEventSeq = 9

        var accepted = orderEvent(9)
        accepted.accepted = Tp_OrderAccepted()
        var rejected = orderEvent(9)
        rejected.rejected = Tp_OrderRejected()
        var fill = orderEvent(9)
        fill.fill = Tp_OrderFill()
        var cancelled = orderEvent(9)
        cancelled.cancelled = Tp_OrderCancelled()
        let payloads = [("accepted", accepted), ("rejected", rejected), ("fill", fill), ("cancelled", cancelled)]
        for (kind, event) in payloads {
            #expect(reduced(events: [event], from: state) == expected, "a default \(kind) payload")
        }

        var entry = orderEvent(9)
        entry.ledgerEntry = Tp_LedgerEntry()
        expected.cash = 0
        #expect(reduced(events: [entry], from: state) == expected, "a default ledger entry payload")
    }

    /// Every number of a payload at its largest or smallest: the numbers are kept as the server sent them, and
    /// nothing wraps or traps. (The ledger entry and the sums of fills have tests of their own.)
    @Test func payloadsWithExtremeNumbersAreAppliedAsTheyCome() throws {
        let accepted = reduced(
            events: [
                acceptedEvent(
                    8, client: "C-9", order: "O-9", symbol: UInt32.max, side: .sell, type: .limit,
                    quantity: Int64.min, limitPrice: Int64.min)
            ], from: stateWithEveryStatus())
        let made = try #require(accepted.order("C-9"))
        #expect(made.status == .accepted)
        #expect(made.symbolId == UInt32.max)
        #expect(made.quantity == Int64.min)
        #expect(made.limitPrice == Price(satang: Int64.min))

        let ended = reduced(
            events: [
                rejectedEvent(9, client: "C-pending", reason: .UNRECOGNIZED(Int.max)),
                cancelledEvent(10, order: "O-000001", remaining: Int64.min, reason: .UNRECOGNIZED(Int.min)),
                fillEvent(
                    11, order: "O-9", symbol: UInt32.max, quantity: Int64.max, price: Int64.max,
                    remaining: Int64.min),
            ], from: accepted)
        #expect(ended.lastEventSeq == 11)
        #expect(ended.order("C-pending")?.status == .rejected)
        #expect(ended.order("C-pending")?.rejectReason == nil)
        #expect(ended.order("C-open")?.status == .cancelled)
        #expect(ended.order("C-open")?.rejectReason == nil)
        let filled = try #require(ended.order("C-9"))
        #expect(filled.status == .filled)
        #expect(filled.filledQuantity == Int64.max)
        #expect(filled.averageFillPrice == Price(satang: Int64.max))
    }

    /// Numbers can jump (events the app never received). The event is applied all the same: the ledger entries carry
    /// absolute cash and positions, so the state heals; the numbers in the gap are then repeats.
    @Test func aJumpInTheNumbersIsApplied() {
        let state = reduced(events: [
            acceptedEvent(1, quantity: 200),
            fillEvent(2, quantity: 100, price: 3_425, remaining: 100),
        ])

        let jumped = reduced(
            events: [
                ledgerEvent(10, ledgerSeq: 4, quantity: 100, price: 3_450, cashAfter: 98_000_000, positionAfter: 300)
            ], from: state)

        #expect(jumped.lastEventSeq == 10)
        #expect(jumped.cash == 98_000_000)
        #expect(jumped.positions == [1: 300])
        #expect(reduced(events: [orderEvent(5)], from: jumped) == jumped)
        #expect(reduced(events: [orderEvent(11)], from: jumped).lastEventSeq == 11)
    }

    /// A stale event changes nothing, not even the epoch: a state that holds sequence numbers but no epoch (built by
    /// hand) does not adopt the epoch of an event that is not newer than them.
    @Test func aStaleEventChangesNothingNotEvenTheEpoch() {
        var held = TradingState()
        held.lastEventSeq = 5
        #expect(reduced(events: [orderEvent(3, epoch: "E1")], from: held) == held)
        #expect(reduced(events: [orderEvent(5, epoch: "E1")], from: held) == held)

        let newer = reduced(events: [orderEvent(6, epoch: "E1")], from: held)
        #expect(newer.epoch == "E1")
        #expect(newer.lastEventSeq == 6)
        #expect(newer.epochChanges == 0)
    }

    // MARK: Epochs

    /// The first epoch the state sees is the one it is in, not a change: nothing is cleared (a submit made before the
    /// first event keeps its row) and nothing is counted.
    @Test func theFirstEpochIsAdoptedWithoutACount() {
        let submitted = reduced([.localSubmitted(draft("C-9"), createdNs: 5)])
        let after = reduced(events: [orderEvent(1, epoch: "E1")], from: submitted)

        #expect(after.epoch == "E1")
        #expect(after.epochChanges == 0)
        #expect(after.lastEventSeq == 1)
        #expect(after.orders == submitted.orders)
    }

    /// Every epoch different from the one held is a change: rows, ledger and positions go, cash stays, the sequence
    /// starts again, and the count goes up by one each time and never for an event inside the epoch.
    @Test func aDifferentEpochClearsRowsKeepsCashAndCounts() {
        var state = stateWithEveryStatus()
        state = reduced(
            events: [
                ledgerEvent(8, ledgerSeq: 1, quantity: 100, price: 3_430, cashAfter: 99_000_000, positionAfter: 100)
            ], from: state)
        #expect(state.orders.count == 7)
        #expect(state.ledger.count == 1)
        #expect(state.positions == [1: 100])
        #expect(state.epochChanges == 0)

        let second = reduced(events: [orderEvent(1, epoch: "E2")], from: state)
        #expect(second.orders.isEmpty)
        #expect(second.ledger.isEmpty)
        #expect(second.positions.isEmpty)
        #expect(second.cash == 99_000_000)
        #expect(second.lastEventSeq == 1)
        #expect(second.epoch == "E2")
        #expect(second.epochChanges == 1)
        // The same event again is a repeat inside the new epoch, not a second change.
        #expect(reduced(events: [orderEvent(1, epoch: "E2")], from: second) == second)

        let third = reduced(events: [orderEvent(1, epoch: "E3"), orderEvent(2, epoch: "E3")], from: second)
        #expect(third.epochChanges == 2)
        #expect(third.lastEventSeq == 2)
        // Going back to an earlier epoch is a change like any other.
        let back = reduced(events: [orderEvent(1, epoch: "E1")], from: third)
        #expect(back.epochChanges == 3)
        #expect(back.epoch == "E1")
    }

    /// The event that starts a new epoch is applied once the old rows are gone. A restarted server numbers its orders
    /// from O-000001 again, and the order the user had just submitted is made again from its own event, stamped with
    /// the server's time.
    @Test func anEventOfANewEpochIsAppliedAfterTheClear() throws {
        let old = reduced(
            [.localSubmitted(draft("C-1", quantity: 200), createdNs: 100)],
            from: reduced(events: [acceptedEvent(1, client: "C-old", order: "O-000001")]))
        #expect(old.orders.map(\.id) == ["C-1", "C-old"])

        let after = reduced(
            events: [acceptedEvent(1, epoch: "E2", tsNs: 9_000, client: "C-1", order: "O-000001", quantity: 200)],
            from: old)

        #expect(after.orders.map(\.id) == ["C-1"])
        let row = try #require(after.order("C-1"))
        #expect(row.status == .accepted)
        #expect(row.orderId == "O-000001")
        #expect(row.createdNs == 9_000)
        #expect(after.epoch == "E2")
        #expect(after.epochChanges == 1)
        #expect(after.lastEventSeq == 1)
    }
}

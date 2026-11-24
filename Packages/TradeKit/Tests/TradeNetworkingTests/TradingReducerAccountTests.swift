import Contracts
import Testing
import TradeCore
import TradeNetworking

extension TradingReducerTests {
    // MARK: Account snapshots of another epoch

    /// A snapshot of a different epoch is an epoch change like an event's: rows, ledger and positions are replaced,
    /// the count goes up, and the sequence starts again from 0, so that the new epoch's first event (numbered 1) is
    /// not taken for a repeat. With `adoptEventSeq` it starts from the snapshot's own number instead.
    @Test(arguments: [false, true])
    func anAccountOfADifferentEpochClearsRowsResetsTheSequenceAndCounts(adopt: Bool) {
        var server = ServerLog(epoch: "E1")
        for client in ["C-1", "C-2", "C-3"] {
            let order = server.accept(client: client, quantity: 100)
            server.fill(order, quantity: 100, price: 3_425, remaining: 0)
        }
        let state = reduced(events: server.events)
        #expect(state.orders.count == 3)
        #expect(state.ledger.count == 3)
        #expect(state.lastEventSeq == 9)

        let snapshot = accountSnapshot(
            epoch: "E2", cash: 50_000_000, positions: [(2, 70)], lastEventSeq: 3, lastLedgerSeq: 1)
        let after = reduced([.account(snapshot, adoptEventSeq: adopt)], from: state)

        #expect(after.orders.isEmpty)
        #expect(after.ledger.isEmpty)
        #expect(after.cash == 50_000_000)
        #expect(after.positions == [2: 70])
        #expect(after.epoch == "E2")
        #expect(after.epochChanges == 1)
        #expect(after.lastEventSeq == (adopt ? 3 : 0))
        if adopt {
            // The log is followed from the snapshot: 3 is known, 4 is new.
            #expect(reduced(events: [orderEvent(3, epoch: "E2")], from: after) == after)
            #expect(reduced(events: [orderEvent(4, epoch: "E2")], from: after).lastEventSeq == 4)
        } else {
            // The new epoch's first event is applied.
            #expect(reduced(events: [orderEvent(1, epoch: "E2")], from: after).lastEventSeq == 1)
        }
    }

    // MARK: Account snapshots of the same epoch

    /// A snapshot older than the state would undo newer events (its cash and positions) or replay events whose fills
    /// are counted already (its sequence), so it is ignored whole, whichever way the sequence is adopted. One that is
    /// not older is applied.
    @Test(arguments: [false, true])
    func anAccountOlderThanTheStateIsIgnoredInBothAdoptModes(adopt: Bool) {
        var server = ServerLog(epoch: "E1", cash: 100_000_000)
        let first = server.accept(client: "C-1", quantity: 100)
        server.fill(first, quantity: 100, price: 3_425, remaining: 0)
        let second = server.accept(client: "C-2", type: .limit, quantity: 100, limitPrice: 3_000)
        server.cancel(second, remaining: 100)
        let state = reduced(events: server.events)
        #expect(state.lastEventSeq == 5)

        let older = accountSnapshot(epoch: "E1", cash: 1, positions: [(9, 9)], lastEventSeq: 4)
        #expect(reduced([.account(older, adoptEventSeq: adopt)], from: state) == state)

        // The same snapshot at the state's own number, and at a newer one, is applied.
        let same = accountSnapshot(epoch: "E1", cash: 1, positions: [(9, 9)], lastEventSeq: 5)
        let atSame = reduced([.account(same, adoptEventSeq: adopt)], from: state)
        #expect(atSame.cash == 1)
        #expect(atSame.positions == [9: 9])
        #expect(atSame.lastEventSeq == 5)

        let newer = accountSnapshot(epoch: "E1", cash: 2, positions: [(8, 8)], lastEventSeq: 8)
        let atNewer = reduced([.account(newer, adoptEventSeq: adopt)], from: state)
        #expect(atNewer.cash == 2)
        #expect(atNewer.positions == [8: 8])
        #expect(atNewer.lastEventSeq == (adopt ? 8 : 5))
    }

    /// A snapshot of the epoch the state is in changes cash and positions and leaves the order rows and the ledger
    /// alone: the rows are rebuilt from the event log, which a snapshot does not carry.
    @Test func anAccountOfTheSameEpochLeavesOrdersAndLedgerAlone() {
        var server = ServerLog(epoch: "E1")
        let order = server.accept(client: "C-1", quantity: 200)
        server.fill(order, quantity: 100, price: 3_425, remaining: 100)
        let state = reduced(
            [.localSubmitted(draft("C-2"), createdNs: 1)], from: reduced(events: server.events))
        #expect(state.orders.count == 2)
        #expect(state.ledger.count == 1)

        let snapshot = accountSnapshot(epoch: "E1", cash: 77, positions: [(3, 30)], lastEventSeq: 3, lastLedgerSeq: 1)
        let after = reduced([.account(snapshot, adoptEventSeq: true)], from: state)
        #expect(after.orders == state.orders)
        #expect(after.ledger == state.ledger)
        #expect(after.cash == 77)
        #expect(after.positions == [3: 30])
        #expect(after.epochChanges == 0)
    }

    // MARK: Account snapshots in general

    /// The first snapshot is the epoch the state is in, not a change: nothing is cleared (a submit made before it keeps
    /// its row) and nothing is counted.
    @Test(arguments: [false, true])
    func aFirstAccountAdoptsItsEpochWithoutACount(adopt: Bool) {
        let submitted = reduced([.localSubmitted(draft("C-9"), createdNs: 5)])
        let snapshot = accountSnapshot(epoch: "E1", cash: 1_000, positions: [(1, 10)], lastEventSeq: 6)
        let after = reduced([.account(snapshot, adoptEventSeq: adopt)], from: submitted)

        #expect(after.epoch == "E1")
        #expect(after.epochChanges == 0)
        #expect(after.orders == submitted.orders)
        #expect(after.cash == 1_000)
        #expect(after.lastEventSeq == (adopt ? 6 : 0))
    }

    /// A snapshot without an epoch is malformed and ignored whole.
    @Test(arguments: [false, true])
    func anAccountWithoutAnEpochIsIgnored(adopt: Bool) {
        let state = stateWithEveryStatus()
        let snapshot = accountSnapshot(epoch: "", cash: 5, positions: [(1, 1)], lastEventSeq: 99)
        #expect(reduced([.account(snapshot, adoptEventSeq: adopt)], from: state) == state)
        #expect(reduced([.account(snapshot, adoptEventSeq: adopt)]) == TradingState())

        // With an epoch the same snapshot is applied.
        let named = accountSnapshot(epoch: "E1", cash: 5, positions: [(1, 1)], lastEventSeq: 99)
        #expect(reduced([.account(named, adoptEventSeq: adopt)], from: state).cash == 5)
    }

    /// Only quantities above 0 are kept, so a state seeded from a snapshot equals one built from events; when a symbol
    /// is listed twice the later entry wins.
    @Test func accountPositionsKeepOnlyQuantitiesAboveZeroAndTheLastEntryWins() {
        let snapshot = accountSnapshot(
            positions: [(1, 100), (2, 0), (3, -5), (4, Int64.min), (5, Int64.max), (1, 250), (6, 10), (6, 0)])
        let state = reduced([.account(snapshot, adoptEventSeq: false)])
        #expect(state.positions == [1: 250, 5: Int64.max, 6: 10])
    }

    /// A snapshot replaces the positions of the state: a symbol it does not list is no longer held.
    @Test func aSnapshotReplacesThePositionsItDoesNotList() {
        let held = reduced(events: [
            ledgerEvent(1, ledgerSeq: 1, symbol: 1, quantity: 100, price: 3_425, cashAfter: 1_000, positionAfter: 100)
        ])
        let snapshot = accountSnapshot(epoch: "E1", cash: 2_000, positions: [(2, 5)], lastEventSeq: 1)
        let after = reduced([.account(snapshot, adoptEventSeq: false)], from: held)
        #expect(held.positions == [1: 100])
        #expect(after.positions == [2: 5])
    }

    // MARK: Clear

    /// `.clear` is the state of a fresh launch except for one number: `epochChanges` is kept, so a screen that watches
    /// it never sees it go backwards.
    @Test func clearEmptiesTheStateButKeepsEpochChanges() {
        var state = stateWithEveryStatus()
        state = reduced(
            events: [
                ledgerEvent(8, ledgerSeq: 1, quantity: 100, price: 3_430, cashAfter: 99_000_000, positionAfter: 100),
                orderEvent(1, epoch: "E2"),
                acceptedEvent(2, epoch: "E2", client: "C-new", order: "O-000001"),
                ledgerEvent(
                    3, epoch: "E2", ledgerSeq: 1, quantity: 100, price: 3_430, cashAfter: 98_000_000,
                    positionAfter: 100),
            ], from: state)
        #expect(state.epochChanges == 1)
        #expect(state.epoch == "E2")
        #expect(state.orders.count == 1)
        #expect(state.ledger.count == 1)
        #expect(state.positions == [1: 100])
        #expect(state.cash == 98_000_000)
        #expect(state.lastEventSeq == 3)

        let cleared = reduced([.clear], from: state)

        var launch = TradingState()
        launch.epochChanges = 1
        #expect(cleared == launch)
        // The epoch is unknown again, so the epoch the state was in is adopted without another count.
        let again = reduced(events: [orderEvent(1, epoch: "E2")], from: cleared)
        #expect(again.epoch == "E2")
        #expect(again.epochChanges == 1)
        #expect(again.lastEventSeq == 1)
    }
}

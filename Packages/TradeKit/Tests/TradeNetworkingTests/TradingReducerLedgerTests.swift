import Contracts
import Testing
import TradeCore
import TradeNetworking

extension TradingReducerTests {
    // MARK: Ledger entries

    /// A ledger entry carries the absolute cash and the absolute position after a fill: the state takes both as they
    /// are, and adds one ledger row with every other field copied. It never makes an order row.
    @Test func aLedgerEntrySetsCashAndPositionAndAddsARow() {
        let state = reduced(events: [
            ledgerEvent(
                1, tsNs: 4_242, ledgerSeq: 1, order: "O-000007", symbol: 3, side: .sell, quantity: 100, price: 3_450,
                commission: 345, cashDelta: 344_655, cashAfter: 100_344_655, positionAfter: 400)
        ])

        #expect(state.cash == 100_344_655)
        #expect(state.positions == [3: 400])
        let expected = LedgerRow(
            id: 1, orderId: "O-000007", symbolId: 3, side: .sell, quantity: 100, price: Price(satang: 3_450),
            commission: 345, cashDelta: 344_655, tsNs: 4_242)
        #expect(state.ledger == [expected])
        #expect(state.orders.isEmpty)
    }

    /// A symbol with no shares left has no entry, whether the server says 0 or something nonsensical below it, and the
    /// other symbols are not touched.
    @Test(arguments: [0, -1, Int64.min] as [Int64])
    func aPositionOfZeroOrLessRemovesTheKey(positionAfter: Int64) {
        let held = reduced(events: [
            ledgerEvent(1, ledgerSeq: 1, symbol: 1, quantity: 100, price: 3_425, cashAfter: 1_000, positionAfter: 100),
            ledgerEvent(2, ledgerSeq: 2, symbol: 2, quantity: 50, price: 1_000, cashAfter: 900, positionAfter: 50),
        ])
        #expect(held.positions == [1: 100, 2: 50])

        let sold = reduced(
            events: [
                ledgerEvent(
                    3, ledgerSeq: 3, symbol: 1, side: .sell, quantity: 100, price: 3_425, cashAfter: 2_000,
                    positionAfter: positionAfter)
            ], from: held)
        #expect(sold.positions == [2: 50])
        #expect(sold.cash == 2_000)
    }

    /// Entries stack newest first, in the order they arrive.
    @Test func ledgerEntriesStackNewestFirst() {
        let state = reduced(events: [
            ledgerEvent(1, ledgerSeq: 1, quantity: 100, price: 3_425, cashAfter: 100, positionAfter: 100),
            ledgerEvent(2, ledgerSeq: 2, quantity: 100, price: 3_450, cashAfter: 200, positionAfter: 200),
            ledgerEvent(3, ledgerSeq: 3, quantity: 100, price: 3_475, cashAfter: 300, positionAfter: 300),
        ])
        #expect(state.ledger.map(\.id) == [3, 2, 1])
        #expect(state.ledger.map(\.price) == [Price(satang: 3_475), Price(satang: 3_450), Price(satang: 3_425)])
    }

    /// A ledger sequence number is a row once. A second entry with the same number adds no row and does not replace the
    /// first, but it is an event of the log like any other and sets cash and the position.
    @Test func aRepeatedLedgerSeqIsNotAddedTwice() throws {
        let first = ledgerEvent(
            1, ledgerSeq: 1, quantity: 100, price: 3_425, commission: 342, cashDelta: -342_842, cashAfter: 99_657_158,
            positionAfter: 100)
        let again = ledgerEvent(
            2, ledgerSeq: 1, quantity: 55, price: 1, commission: 0, cashDelta: 0, cashAfter: 5, positionAfter: 7)
        let state = reduced(events: [first, again])

        #expect(state.ledger.count == 1)
        let row = try #require(state.ledger.first)
        #expect(row.quantity == 100)
        #expect(row.price == Price(satang: 3_425))
        #expect(state.cash == 5)
        #expect(state.positions == [1: 7])
        // A different number is a second row.
        let other = ledgerEvent(
            3, ledgerSeq: 2, quantity: 55, price: 1, cashAfter: 5, positionAfter: 7)
        #expect(reduced(events: [other], from: state).ledger.map(\.id) == [2, 1])
    }

    /// A side that does not map leaves no row to show, but the numbers are still absolute truth about the account.
    @Test(arguments: [Tp_Side.unspecified, .UNRECOGNIZED(9)])
    func aLedgerEntryWithAnUnmappableSideStillMovesCashAndPosition(side: Tp_Side) {
        let entry = ledgerEvent(
            1, ledgerSeq: 1, side: side, quantity: 100, price: 3_425, cashAfter: 99_000_000, positionAfter: 100)
        let state = reduced(events: [entry])
        #expect(state.ledger.isEmpty)
        #expect(state.cash == 99_000_000)
        #expect(state.positions == [1: 100])
        #expect(state.lastEventSeq == 1)
        // With a side that maps the same entry makes a row.
        let mapped = ledgerEvent(
            1, ledgerSeq: 1, side: .buy, quantity: 100, price: 3_425, cashAfter: 99_000_000, positionAfter: 100)
        #expect(reduced(events: [mapped]).ledger.count == 1)
    }

    /// A fill moves the order row only: cash and positions change with the ledger entry that follows it.
    @Test func cashAndPositionsComeOnlyFromLedgerEntries() {
        let fill = [
            acceptedEvent(1, quantity: 200),
            fillEvent(2, quantity: 100, price: 3_425, remaining: 100),
        ]
        let withoutEntry = reduced(events: fill)
        #expect(withoutEntry.cash == 0)
        #expect(withoutEntry.positions.isEmpty)
        #expect(withoutEntry.ledger.isEmpty)

        let entry = ledgerEvent(
            3, ledgerSeq: 1, quantity: 100, price: 3_425, commission: 342, cashDelta: -342_842,
            cashAfter: 99_657_158, positionAfter: 100)
        let withEntry = reduced(events: [entry], from: withoutEntry)
        #expect(withEntry.cash == 99_657_158)
        #expect(withEntry.positions == [1: 100])
        #expect(withEntry.ledger.count == 1)
    }

    /// A state built from the events and a state seeded from the account of the same moment agree on cash and
    /// positions, even when a symbol was bought and sold out again: neither holds an entry for it.
    @Test func aStateBuiltFromEventsEqualsAStateSeededFromTheAccount() {
        var server = ServerLog(epoch: "E1", cash: 100_000_000)
        let bought = server.accept(client: "C-1", symbol: 1, side: .buy, quantity: 200)
        server.fill(bought, quantity: 200, price: 3_425, remaining: 0)
        let other = server.accept(client: "C-2", symbol: 2, side: .buy, quantity: 100)
        server.fill(other, quantity: 100, price: 1_000, remaining: 0)
        let sold = server.accept(client: "C-3", symbol: 1, side: .sell, quantity: 200)
        server.fill(sold, quantity: 200, price: 3_450, remaining: 0)
        #expect(server.positions == [2: 100])

        let fromEvents = reduced(events: server.events)
        let snapshot = accountSnapshot(
            epoch: "E1", cash: server.cash, positions: [(2, 100)], lastEventSeq: UInt64(server.events.count),
            lastLedgerSeq: 3)
        let fromAccount = reduced([.account(snapshot, adoptEventSeq: true)])

        #expect(fromEvents.positions == [2: 100])
        #expect(fromEvents.positions == fromAccount.positions)
        #expect(fromEvents.cash == fromAccount.cash)
        #expect(fromEvents.epoch == fromAccount.epoch)
        #expect(fromEvents.lastEventSeq == fromAccount.lastEventSeq)
    }

    /// Numbers at the ends of their types are stored as they come and trap nothing, up to the last event number there
    /// is, after which every event of the epoch is a repeat.
    @Test func extremeNumbersAreStoredAsTheyCome() {
        let entry = ledgerEvent(
            UInt64.max, tsNs: Int64.min, ledgerSeq: UInt64.max, symbol: UInt32.max, quantity: Int64.min,
            price: Int64.min, commission: Int64.min, cashDelta: Int64.max, cashAfter: Int64.min,
            positionAfter: Int64.max)
        let state = reduced(events: [entry])

        let expected = LedgerRow(
            id: UInt64.max, orderId: "O-000001", symbolId: UInt32.max, side: .buy, quantity: Int64.min,
            price: Price(satang: Int64.min), commission: Int64.min, cashDelta: Int64.max, tsNs: Int64.min)
        #expect(state.ledger == [expected])
        #expect(state.cash == Int64.min)
        #expect(state.positions == [UInt32.max: Int64.max])
        #expect(state.lastEventSeq == UInt64.max)
        #expect(reduced(events: [orderEvent(UInt64.max)], from: state) == state)
    }
}

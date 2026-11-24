import Contracts
import Testing
import TradeCore
import TradeNetworking

/// What the trading reducer makes of the server's order events, the app's own submissions and account snapshots.
/// This file holds the main scenarios; the rest of the suite is in `TradingReducerOrderTests.swift`,
/// `TradingReducerFillTests.swift`, `TradingReducerLedgerTests.swift`, `TradingReducerEpochTests.swift`,
/// `TradingReducerAccountTests.swift`, `TradingReducerReplayTests.swift`, `TradingReducerModelTests.swift` and
/// `TradingReducerFuzzTests.swift`, each an extension of this suite.
@Suite("TradingReducerTests")
struct TradingReducerTests {
    // MARK: The main scenarios

    /// The user sends a market buy of 200 shares; the server accepts it and fills it in two parts, 100 at 34.25 and 100
    /// at 34.50. Each fill is followed by its ledger entry, whose cash and position are absolute.
    @Test func acceptedFillLedgerBuildsState() throws {
        var state = reduced([.localSubmitted(draft("C-1", quantity: 200), createdNs: 100)])
        let pending = try #require(state.order("C-1"))
        #expect(pending.status == .pending)
        #expect(pending.orderId == nil)

        state = reduced(
            events: [
                acceptedEvent(1, client: "C-1", order: "O-000001", quantity: 200),
                fillEvent(2, order: "O-000001", quantity: 100, price: 3_425, remaining: 100),
                ledgerEvent(
                    3, ledgerSeq: 1, quantity: 100, price: 3_425, commission: 342, cashDelta: -342_842,
                    cashAfter: 99_657_158, positionAfter: 100
                ),
                fillEvent(4, order: "O-000001", quantity: 100, price: 3_450, remaining: 0),
                ledgerEvent(
                    5, ledgerSeq: 2, quantity: 100, price: 3_450, commission: 345, cashDelta: -345_345,
                    cashAfter: 99_311_813, positionAfter: 200
                ),
            ], from: state)

        #expect(state.orders.count == 1)
        let row = try #require(state.order("C-1"))
        #expect(row.orderId == "O-000001")
        #expect(row.filledQuantity == 200)
        // (100 * 3425 + 100 * 3450) / 200 is 3437.5, and a half rounds up.
        #expect(row.averageFillPrice == Price(satang: 3_438))
        #expect(row.status == .filled)
        #expect(row.rejectReason == nil)
        #expect(row.createdNs == 100)
        #expect(state.cash == 99_311_813)
        #expect(state.positions == [1: 200])
        #expect(state.ledger.map(\.id) == [2, 1])
        #expect(state.lastEventSeq == 5)
        #expect(state.epoch == "E1")
        #expect(state.epochChanges == 0)
    }

    /// An event delivered twice, or one older than the last, changes nothing. The event used is a fill, which would
    /// add its shares again if it were applied again.
    @Test func duplicateAndStaleEventsIgnored() throws {
        let log = [
            acceptedEvent(1, client: "C-1", order: "O-000001", quantity: 200),
            fillEvent(2, order: "O-000001", quantity: 50, price: 3_425, remaining: 150),
            ledgerEvent(
                3, ledgerSeq: 1, quantity: 50, price: 3_425, cashDelta: -171_250, cashAfter: 99_828_750,
                positionAfter: 50
            ),
            fillEvent(4, order: "O-000001", quantity: 50, price: 3_430, remaining: 100),
            fillEvent(5, order: "O-000001", quantity: 50, price: 3_440, remaining: 50),
        ]
        let atFour = reduced(events: Array(log.prefix(4)))
        let atFive = reduced(events: [log[4]], from: atFour)
        // The first delivery of event 5 does change the state; the repeats below must not do it again.
        #expect(atFive.order("C-1")?.filledQuantity == 150)
        #expect(atFive.lastEventSeq == 5)

        #expect(reduced(events: [log[4]], from: atFive) == atFive)
        #expect(reduced(events: [log[3], log[2], log[1], log[0]], from: atFive) == atFive)
        // A late event that would create a row if it were new.
        let late = acceptedEvent(3, client: "C-2", order: "O-000002", quantity: 100)
        #expect(reduced(events: [late], from: atFive) == atFive)
        // Numbered above the last one it applies, so the ignoring above is the gate and not the fixture.
        let next = acceptedEvent(6, client: "C-2", order: "O-000002", quantity: 100)
        #expect(reduced(events: [next], from: atFive).order("C-2") != nil)
    }

    /// The server restarts and numbers its events from 1 again in a new epoch. Every row of the old epoch is a
    /// phantom, the unanswered and the lost submits included; cash is kept until the new epoch says otherwise.
    @Test func epochChangeClearsPhantomOrders() throws {
        var state = reduced([
            .localSubmitted(draft("C-pending"), createdNs: 100),
            .localSubmitted(draft("C-lost"), createdNs: 110),
            .submitUnconfirmed(clientOrderId: "C-lost"),
        ])
        state = reduced(
            events: [
                acceptedEvent(1, client: "C-open", order: "O-000001", quantity: 300),
                acceptedEvent(2, client: "C-done", order: "O-000002", quantity: 100),
                fillEvent(3, order: "O-000002", quantity: 100, price: 3_425, remaining: 0),
                ledgerEvent(
                    4, ledgerSeq: 1, order: "O-000002", quantity: 100, price: 3_425, commission: 342,
                    cashDelta: -342_842, cashAfter: 99_657_158, positionAfter: 100
                ),
            ], from: state)
        #expect(state.orders.map(\.status) == [.filled, .accepted, .unknown, .pending])
        #expect(state.ledger.count == 1)
        #expect(state.positions == [1: 100])
        #expect(state.lastEventSeq == 4)

        let restarted = reduced(events: [orderEvent(1, epoch: "E2")], from: state)

        #expect(restarted.orders.isEmpty)
        #expect(restarted.ledger.isEmpty)
        #expect(restarted.positions.isEmpty)
        #expect(restarted.cash == 99_657_158)
        #expect(restarted.lastEventSeq == 1)
        #expect(restarted.epochChanges == 1)
        #expect(restarted.epoch == "E2")
    }

    /// A refusal that comes back from the submit call marks the row, and only that row.
    @Test func submitRejectedMarksRow() throws {
        let submitted = reduced([
            .localSubmitted(draft("C-1", quantity: 100), createdNs: 100),
            .localSubmitted(draft("C-2", quantity: 300), createdNs: 200),
        ])
        let rejected = reduced([.submitRejected(clientOrderId: "C-1", reason: .insufficientFunds)], from: submitted)

        let row = try #require(rejected.order("C-1"))
        #expect(row.status == .rejected)
        #expect(row.rejectReason == .insufficientFunds)
        #expect(row.orderId == nil)
        let expected = try submitted.editing("C-1") {
            $0.status = .rejected
            $0.rejectReason = .insufficientFunds
        }
        #expect(rejected == expected)
        // A client order id with no row is ignored.
        #expect(reduced([.submitRejected(clientOrderId: "C-9", reason: .invalidLot)], from: submitted) == submitted)
    }

    /// A submit that got no answer is `.unknown`; the event log then settles it, and it stays one row.
    @Test func unconfirmedThenAcceptedResolves() throws {
        var state = reduced([.localSubmitted(draft("C-1", quantity: 200), createdNs: 100)])
        state = reduced([.submitUnconfirmed(clientOrderId: "C-1")], from: state)
        #expect(state.order("C-1")?.status == .unknown)

        state = reduced(events: [acceptedEvent(1, client: "C-1", order: "O-000001", quantity: 200)], from: state)

        #expect(state.orders.count == 1)
        let row = try #require(state.order("C-1"))
        #expect(row.status == .accepted)
        #expect(row.orderId == "O-000001")
        #expect(row.createdNs == 100)
    }

    /// The app relaunches and replays the log from sequence 0: it has no row for any order, so each `accepted` event
    /// makes one, and the rows end newest first.
    @Test func replayFromZeroRebuildsOrders() throws {
        var server = ServerLog(epoch: "E1", cash: 100_000_000, startNs: 5_000_000)
        let first = server.accept(client: "C-1", quantity: 200)
        server.fill(first, quantity: 100, price: 3_425, remaining: 100)
        server.fill(first, quantity: 100, price: 3_450, remaining: 0)
        let second = server.accept(client: "C-2", side: .sell, type: .limit, quantity: 100, limitPrice: 3_500)
        server.cancel(second, remaining: 100)
        let log = server.events
        #expect(log.count == 7)

        let state = reduced(events: log)

        #expect(state.orders.map(\.id) == ["C-2", "C-1"])
        let done = try #require(state.order("C-1"))
        #expect(done.orderId == first)
        #expect(done.status == .filled)
        #expect(done.filledQuantity == 200)
        #expect(done.averageFillPrice == Price(satang: 3_438))
        #expect(done.createdNs == log.first?.serverTsNs)
        let cancelled = try #require(state.order("C-2"))
        #expect(cancelled.orderId == second)
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.side == .sell)
        #expect(cancelled.type == .limit)
        #expect(cancelled.limitPrice == Price(satang: 3_500))
        #expect(cancelled.filledQuantity == 0)
        #expect(cancelled.averageFillPrice == nil)
        #expect(state.ledger.map(\.id) == [2, 1])
        #expect(state.cash == server.cash)
        #expect(state.positions == [1: 200])
        #expect(state.lastEventSeq == 7)
        #expect(state.epochChanges == 0)
    }

    /// A limit order that is filled in part and then cancelled keeps what it filled and its average.
    @Test func partialFillThenCancelKeepsFilled() throws {
        let accepted = reduced(events: [
            acceptedEvent(1, client: "C-1", order: "O-000001", type: .limit, quantity: 300, limitPrice: 3_400)
        ])
        let partial = reduced(
            events: [fillEvent(2, order: "O-000001", quantity: 100, price: 3_400, remaining: 200)], from: accepted)
        let resting = try #require(partial.order("C-1"))
        #expect(resting.status == .partiallyFilled)
        #expect(resting.filledQuantity == 100)

        let cancelled = reduced(events: [cancelledEvent(3, order: "O-000001", remaining: 200)], from: partial)

        let row = try #require(cancelled.order("C-1"))
        #expect(row.status == .cancelled)
        #expect(row.filledQuantity == 100)
        #expect(row.averageFillPrice == Price(satang: 3_400))
        #expect(row.quantity == 300)
        #expect(row.rejectReason == nil)
    }

    /// An account snapshot seeds cash, positions and the epoch. Whether it also sets the event sequence is the
    /// caller's choice: without it the log is replayed from where the state is, with it the log is followed from the
    /// snapshot's own sequence.
    @Test func accountActionSeedsCashAndPositions() throws {
        let snapshot = accountSnapshot(
            epoch: "E1", cash: 98_000_000, positions: [(1, 200), (4, 1_000)], lastEventSeq: 42, lastLedgerSeq: 7)

        let notAdopted = reduced([.account(snapshot, adoptEventSeq: false)])
        #expect(notAdopted.cash == 98_000_000)
        #expect(notAdopted.positions == [1: 200, 4: 1_000])
        #expect(notAdopted.epoch == "E1")
        #expect(notAdopted.lastEventSeq == 0)
        #expect(notAdopted.epochChanges == 0)

        let adopted = reduced([.account(snapshot, adoptEventSeq: true)])
        #expect(adopted.cash == 98_000_000)
        #expect(adopted.positions == [1: 200, 4: 1_000])
        #expect(adopted.epoch == "E1")
        #expect(adopted.lastEventSeq == 42)
        #expect(adopted.epochChanges == 0)

        // The sequence decides what the log does next.
        #expect(reduced(events: [orderEvent(42)], from: adopted) == adopted)
        #expect(reduced(events: [orderEvent(43)], from: adopted).lastEventSeq == 43)
        #expect(reduced(events: [orderEvent(1)], from: notAdopted).lastEventSeq == 1)
    }
}

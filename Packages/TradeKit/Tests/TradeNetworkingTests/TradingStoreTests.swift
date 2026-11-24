import Contracts
import Testing
import TradeCore
@testable import TradeNetworking

/// The trading store over a fake client and a fake REST API: what each operation sends and what it does to the state,
/// the account reads at start and at every connection, the out-of-range recovery and the submit-to-fill timer.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TradingStoreTests {
    // MARK: Submit

    @Test func anAcceptedSubmitLeavesThePendingRowToTheStream() async throws {
        let rig = StoreRig()
        await rig.store.submit(draft("C-1"))
        #expect(rig.client.submitted == [draft("C-1")])
        #expect(rig.store.state.orders.map(\.status) == [.pending])
        #expect(rig.store.state.order("C-1")?.createdNs == 77)
    }

    @Test func aRefusalWithAReasonRejectsTheRow() async throws {
        let rig = StoreRig()
        rig.client.answer { _ in FakeTradingClient.refused(.invalidLot) }
        await rig.store.submit(draft("C-1", quantity: 150))
        #expect(rig.store.state.order("C-1")?.status == .rejected)
        #expect(rig.store.state.order("C-1")?.rejectReason == .invalidLot)
    }

    @Test func aRefusalWithNoKnownReasonLeavesTheRowUnknown() async throws {
        let rig = StoreRig()
        rig.client.answer { _ in FakeTradingClient.refused(nil) }
        await rig.store.submit(draft("C-1"))
        #expect(rig.store.state.order("C-1")?.status == .unknown)
    }

    @Test func aThrownSubmitLeavesTheRowUnknown() async throws {
        let rig = StoreRig()
        rig.client.answer { _ in throw FakeTradingClient.Failure() }
        await rig.store.submit(draft("C-1"))
        #expect(rig.store.state.order("C-1")?.status == .unknown)
    }

    @Test func aSecondSubmitOfOneIdSendsAgainAndMakesNoSecondRow() async throws {
        let rig = StoreRig()
        await rig.store.submit(draft("C-1"))
        await rig.store.submit(draft("C-1"))
        #expect(rig.client.submitted.map(\.clientOrderId) == ["C-1", "C-1"])
        #expect(rig.store.state.orders.count == 1)
    }

    // MARK: Retry and cancel

    @Test func retryUnconfirmedResendsTheSameIdOnlyForAnUnknownRow() async throws {
        let rig = StoreRig()
        rig.client.answer { _ in throw FakeTradingClient.Failure() }
        await rig.store.submit(draft("C-1", symbol: 3, side: .sell, type: .limit, quantity: 300, limit: 3_425))
        #expect(rig.store.state.order("C-1")?.status == .unknown)

        rig.client.answer { _ in FakeTradingClient.refused(.insufficientPosition) }
        await rig.store.retryUnconfirmed(clientOrderId: "C-1")
        #expect(rig.client.submitted.count == 2)
        #expect(rig.client.submitted.last == draft("C-1", symbol: 3, side: .sell, type: .limit, quantity: 300, limit: 3_425))
        #expect(rig.store.state.order("C-1")?.status == .rejected)

        // Neither a rejected row nor an id without a row is sent again.
        await rig.store.retryUnconfirmed(clientOrderId: "C-1")
        await rig.store.retryUnconfirmed(clientOrderId: "C-none")
        #expect(rig.client.submitted.count == 2)
    }

    @Test func retryUnconfirmedLeavesAPendingRowAlone() async throws {
        let rig = StoreRig()
        rig.client.answer { _ in FakeTradingClient.accepted(draft("C-1")) }
        await rig.store.submit(draft("C-1"))
        await rig.store.retryUnconfirmed(clientOrderId: "C-1")
        #expect(rig.client.submitted.count == 1)
    }

    @Test func cancelReachesTheClientOnlyForAnOpenRowWhileConnected() async throws {
        let rig = StoreRig()
        try await rig.start()
        try await rig.deliver([
            acceptedEvent(1, client: "C-open", order: "O-1"),
            acceptedEvent(2, client: "C-done", order: "O-2"),
            fillEvent(3, order: "O-2", quantity: 200, price: 1_000, remaining: 0),
        ])
        // Not connected yet: nothing is sent.
        await rig.store.cancel(orderId: "O-1")
        #expect(rig.client.cancelled.isEmpty)

        // The store has seen `.connected` once its account read at the connection has been made.
        let calls = rig.rest.calls
        rig.client.push(.connected)
        let seen = await until { rig.rest.calls > calls }
        #expect(seen)
        await rig.store.cancel(orderId: "O-2")  // filled
        await rig.store.cancel(orderId: "O-9")  // unknown
        #expect(rig.client.cancelled.isEmpty)
        // Positive control: the open row is sent.
        await rig.store.cancel(orderId: "O-1")
        #expect(rig.client.cancelled == ["O-1"])
    }

    // MARK: Accounts

    @Test func startReadsTheAccountAndStartsTheStreamFromTheState() async throws {
        let rest = FakeRestAPI()
        rest.enqueue(.account(accountSnapshot(epoch: "E1", cash: 5_000, positions: [(2, 100)], lastEventSeq: 9)))
        let rig = StoreRig(rest: rest)
        try await rig.start()
        #expect(rig.store.state.cash == 5_000)
        #expect(rig.store.state.positions == [2: 100])
        #expect(rig.store.state.epoch == "E1")
        // The sequence is not taken: the log is replayed from 0 to rebuild the rows.
        #expect(rig.store.state.lastEventSeq == 0)
        let resume = try rig.client.requireHandlers().resumeFrom()
        #expect(resume.seq == 0)
        #expect(resume.epoch == "E1")
    }

    @Test func aFailedFirstReadIsIgnored() async throws {
        let rig = StoreRig()
        try await rig.start()
        #expect(rig.client.starts == 1)
        #expect(rig.store.state == TradingState())
    }

    /// The reset of a server without events of its new epoch: the account read at the connection clears the rows.
    @Test func everyConnectionReadsTheAccountAndAnotherEpochClearsTheRows() async throws {
        let rig = StoreRig()
        try await rig.start()
        try await rig.deliver([acceptedEvent(1, epoch: "E1", client: "C-1")])
        await rig.store.submit(draft("C-2"))
        #expect(rig.store.state.orders.count == 2)

        rig.rest.enqueue(.account(accountSnapshot(epoch: "E1", cash: 100, lastEventSeq: 1)))
        rig.client.push(.connected)
        let first = await until { rig.store.state.cash == 100 }
        #expect(first)
        #expect(rig.store.state.orders.count == 2)

        rig.client.push(.reconnecting(attempt: 1))
        rig.rest.enqueue(.account(accountSnapshot(epoch: "E2", cash: 900, lastEventSeq: 0)))
        rig.client.push(.connected)
        let cleared = await until { rig.store.state.epoch == "E2" }
        #expect(cleared)
        #expect(rig.store.state.orders.isEmpty)
        #expect(rig.store.state.cash == 900)
        #expect(rig.store.state.epochChanges == 1)
        let resume = try rig.client.requireHandlers().resumeFrom()
        #expect(resume.seq == 0)
        #expect(resume.epoch == "E2")
    }

    @Test func outOfRangeStartsOverFromTheAccount() async throws {
        let rig = StoreRig()
        try await rig.start()
        try await rig.deliver([acceptedEvent(1, epoch: "E1", client: "C-1")])
        rig.rest.enqueue(.account(accountSnapshot(epoch: "E1", cash: 4_200, positions: [(3, 500)], lastEventSeq: 60)))
        try await rig.client.requireHandlers().onOutOfRange()
        #expect(rig.store.state.orders.isEmpty)
        #expect(rig.store.state.cash == 4_200)
        #expect(rig.store.state.positions == [3: 500])
        #expect(rig.store.state.lastEventSeq == 60)
        #expect(rig.store.state.epochChanges == 0)
        let resume = try rig.client.requireHandlers().resumeFrom()
        #expect(resume.seq == 60)
        #expect(resume.epoch == "E1")
        // The stream goes on from there.
        try await rig.deliver([acceptedEvent(61, epoch: "E1", client: "C-61", order: "O-61")])
        #expect(rig.store.state.orders.map(\.id) == ["C-61"])
    }

    /// A failed reload changes nothing at all, not even the resume point; the next out-of-range recovery completes.
    @Test func aFailedReloadChangesNothingAndTheNextRecoveryCompletes() async throws {
        let rig = StoreRig()
        try await rig.start()
        try await rig.deliver([
            acceptedEvent(1, epoch: "E1", client: "C-1"),
            fillEvent(2, quantity: 100, price: 1_000, remaining: 100),
            ledgerEvent(3, ledgerSeq: 1, quantity: 100, price: 1_000, cashAfter: 9_000, positionAfter: 100),
        ])
        let before = rig.store.state
        rig.rest.enqueue(.failure)
        let handlers = try rig.client.requireHandlers()
        await handlers.onOutOfRange()
        #expect(rig.store.state == before)
        let unchanged = handlers.resumeFrom()
        #expect(unchanged.seq == 3)
        #expect(unchanged.epoch == "E1")

        rig.rest.enqueue(.account(accountSnapshot(epoch: "E1", cash: 300, lastEventSeq: 40)))
        await handlers.onOutOfRange()
        let resume = handlers.resumeFrom()
        #expect(resume.seq == 40)
        #expect(resume.epoch == "E1")
        #expect(rig.store.state.cash == 300)
        try await rig.deliver([acceptedEvent(41, epoch: "E1", client: "C-41", order: "O-41")])
        #expect(rig.store.state.orders.map(\.id) == ["C-41"])
    }

    @Test func startAgainAfterAStopRegistersAgainAndKeepsTheRows() async throws {
        let rig = StoreRig()
        try await rig.start()
        try await rig.deliver([acceptedEvent(1, epoch: "E1", client: "C-1")])
        await rig.client.stop()

        try await rig.start()
        #expect(rig.client.starts == 2)
        #expect(rig.store.state.orders.map(\.id) == ["C-1"])
        #expect(try rig.client.requireHandlers().resumeFrom().seq == 1)
        // The new observer sees the new connection: its account read happens.
        let calls = rig.rest.calls
        rig.client.push(.connected)
        let read = await until { rig.rest.calls > calls }
        #expect(read)
    }

    // MARK: Submit to fill

    @Test func theFirstFillOfASubmittedOrderIsTimedOnce() async throws {
        let rig = StoreRig()
        try await rig.start()
        await rig.store.submit(draft("C-1"))
        rig.clock.advance(by: 3_000_000)
        try await rig.deliver([
            acceptedEvent(1, client: "C-1", order: "O-1"),
            fillEvent(2, order: "O-1", quantity: 100, price: 1_000, remaining: 100),
        ])
        rig.clock.advance(by: 1_000_000)
        try await rig.deliver([fillEvent(3, order: "O-1", quantity: 100, price: 1_000, remaining: 0)])
        let summary = rig.latency.summary(.orderSubmitToFill)
        #expect(summary.count == 1)
        #expect(summary.clamped == 0)
        #expect(rig.store.state.order("C-1")?.status == .filled)
    }

    /// A replay after a relaunch has no starts, and a repeated fill is not taken: neither records.
    @Test func aReplayedOrRepeatedFillRecordsNothing() async throws {
        let rig = StoreRig()
        try await rig.start()
        try await rig.deliver([
            acceptedEvent(1, client: "C-1", order: "O-1"),
            fillEvent(2, order: "O-1", quantity: 100, price: 1_000, remaining: 100),
        ])
        #expect(rig.latency.summary(.orderSubmitToFill).count == 0)

        // A submit of the same id after its fill, then the fill again: stale, so still nothing.
        await rig.store.submit(draft("C-1"))
        try await rig.deliver([fillEvent(2, order: "O-1", quantity: 100, price: 1_000, remaining: 100)])
        #expect(rig.latency.summary(.orderSubmitToFill).count == 0)
        // Positive control: the next new fill of that order is timed.
        try await rig.deliver([fillEvent(3, order: "O-1", quantity: 100, price: 1_000, remaining: 0)])
        #expect(rig.latency.summary(.orderSubmitToFill).count == 1)
    }

    @Test func aStartOlderThanTenSecondsRecordsNothing() async throws {
        let rig = StoreRig()
        try await rig.start()
        await rig.store.submit(draft("C-old"))
        rig.clock.advance(by: 10_000_000_001)
        await rig.store.submit(draft("C-late"))
        try await rig.deliver([
            acceptedEvent(1, client: "C-old", order: "O-1"),
            fillEvent(2, order: "O-1", quantity: 200, price: 1_000, remaining: 0),
        ])
        #expect(rig.latency.summary(.orderSubmitToFill).count == 0)
        // Positive control: an order submitted after the jump is timed.
        try await rig.deliver([
            acceptedEvent(3, client: "C-late", order: "O-3"),
            fillEvent(4, order: "O-3", quantity: 200, price: 1_000, remaining: 0),
        ])
        #expect(rig.latency.summary(.orderSubmitToFill).count == 1)
        #expect(rig.latency.summary(.orderSubmitToFill).clamped == 0)
    }
}

import Contracts
import Testing
import TradeCore
@testable import TradeNetworking

/// The recovery after the server no longer keeps the events asked for, with the account read held by the test: the
/// old state stays on screen until the answer is in, and only an answer that can be applied replaces it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TradingStoreRecoveryTests {
    /// A started store in epoch "E1" at event 3, with one partly filled row, cash 9_000 and 100 shares of symbol 1;
    /// its recovery has begun and its account read is held.
    private func heldRecovery() async throws -> (rig: StoreRig, before: TradingState, recovery: Task<Void, Never>) {
        let rig = StoreRig()
        try await rig.start()
        try await rig.deliver([
            acceptedEvent(1, epoch: "E1", client: "C-1"),
            fillEvent(2, quantity: 100, price: 1_000, remaining: 100),
            ledgerEvent(3, ledgerSeq: 1, quantity: 100, price: 1_000, cashAfter: 9_000, positionAfter: 100),
        ])
        let before = rig.store.state
        let handlers = try rig.client.requireHandlers()
        rig.rest.enqueue(.hold)
        let recovery = Task { await handlers.onOutOfRange() }
        let held = await until { rig.rest.heldCount == 1 }
        #expect(held, "the recovery did not read the account")
        return (rig, before, recovery)
    }

    @Test func nothingIsClearedWhileTheRecoveryReadIsOut() async throws {
        let (rig, before, recovery) = try await heldRecovery()
        #expect(rig.store.state == before)
        #expect(rig.store.state.cash == 9_000)
        #expect(rig.store.state.positions == [1: 100])
        #expect(rig.store.state.orders.map(\.id) == ["C-1"])
        rig.rest.release(.failure)
        await recovery.value
    }

    @Test func theAnswerReplacesTheRowsAndTheResumePoint() async throws {
        let (rig, before, recovery) = try await heldRecovery()
        let account = accountSnapshot(epoch: "E1", cash: 4_200, positions: [(3, 500)], lastEventSeq: 60)
        rig.rest.release(.account(account))
        await recovery.value
        #expect(rig.store.state == reduced([.clear, .account(account, adoptEventSeq: true)], from: before))
        #expect(rig.store.state.orders.isEmpty)
        #expect(rig.store.state.cash == 4_200)
        #expect(rig.store.state.positions == [3: 500])
        let resume = try rig.client.requireHandlers().resumeFrom()
        #expect(resume.seq == 60)
        #expect(resume.epoch == "E1")
    }

    /// The state moved to another epoch while the read was out: the answer of the epoch it left changes nothing.
    @Test func anAnswerThatStraddlesAnEpochChangeIsDroppedByTheRecovery() async throws {
        let (rig, _, recovery) = try await heldRecovery()
        try await rig.deliver([acceptedEvent(1, epoch: "E2", client: "C-2", order: "O-000002")])
        let moved = rig.store.state
        #expect(moved.epoch == "E2")
        rig.rest.release(.account(accountSnapshot(epoch: "E1", cash: 4_200, lastEventSeq: 60)))
        await recovery.value
        #expect(rig.store.state == moved)
        let resume = try rig.client.requireHandlers().resumeFrom()
        #expect(resume.seq == 1)
        #expect(resume.epoch == "E2")
    }
}

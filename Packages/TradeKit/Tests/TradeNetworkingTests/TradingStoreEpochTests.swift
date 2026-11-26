import Contracts
import Testing
import TradeCore
@testable import TradeNetworking

/// Account answers that were asked for in one epoch and arrive after the state has moved to another: the reducer
/// cannot tell an older epoch from a newer one, so the store drops such an answer itself. Each test holds the answer
/// of the read made at a connection, changes the state meanwhile, then releases it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TradingStoreEpochTests {
    /// A started store in epoch "E1" with one accepted row, whose read at the next `.connected` is held.
    private func heldRig() async throws -> StoreRig {
        let rig = StoreRig()
        try await rig.start()
        try await rig.deliver([acceptedEvent(1, epoch: "E1", client: "C-1", order: "O-000001")])
        rig.rest.enqueue(.hold)
        rig.client.push(.connected)
        let held = await until { rig.rest.heldCount == 1 }
        #expect(held, "the read at the connection was not made")
        return rig
    }

    @Test func anAnswerOfTheEpochTheStateLeftIsDropped() async throws {
        let rig = try await heldRig()
        try await rig.deliver([
            acceptedEvent(1, epoch: "E2", client: "C-2", order: "O-000002"),
            fillEvent(2, epoch: "E2", order: "O-000002", quantity: 200, price: 1_000, remaining: 0),
        ])
        let before = rig.store.state
        #expect(before.epoch == "E2")
        #expect(before.epochChanges == 1)

        rig.rest.release(.account(accountSnapshot(epoch: "E1", cash: 555, lastEventSeq: 1)))
        // The read is the observer's; a later `.connected` shows that it has dealt with the answer.
        rig.rest.enqueue(.failure)
        let calls = rig.rest.calls
        rig.client.push(.reconnecting(attempt: 1))
        rig.client.push(.connected)
        let done = await until { rig.rest.calls > calls }
        #expect(done)
        #expect(rig.store.state == before)
    }

    /// The positive control: an answer of another epoch while the state stayed in its own is the reset case.
    @Test func anAnswerOfANewEpochIsAppliedWhileTheStateStayed() async throws {
        let rig = try await heldRig()
        rig.rest.release(.account(accountSnapshot(epoch: "E2", cash: 555, lastEventSeq: 0)))
        let applied = await until { rig.store.state.epoch == "E2" }
        #expect(applied)
        #expect(rig.store.state.orders.isEmpty)
        #expect(rig.store.state.epochChanges == 1)
        #expect(rig.store.state.cash == 555)
    }

    @Test func anAnswerOfTheEpochTheStateMovedToIsApplied() async throws {
        let rig = try await heldRig()
        try await rig.deliver([acceptedEvent(1, epoch: "E2", client: "C-2", order: "O-000002")])
        rig.rest.release(.account(accountSnapshot(epoch: "E2", cash: 555, positions: [(1, 200)], lastEventSeq: 1)))
        let applied = await until { rig.store.state.cash == 555 }
        #expect(applied)
        #expect(rig.store.state.epoch == "E2")
        #expect(rig.store.state.orders.map(\.id) == ["C-2"])
        #expect(rig.store.state.positions == [1: 200])
        #expect(rig.store.state.epochChanges == 1)
    }
}

import Contracts
import Testing
import TradeCore
@testable import TradeNetworking

/// `reconcile()` against a fake account: drift only when the sequences are equal and cash or positions differ;
/// anything that cannot be compared at one moment is in flight.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TradingStoreReconcileTests {
    /// A store whose state is epoch "E1" at event 4 with cash 99_000 and 100 shares of symbol 1 (from a ledger entry).
    private func settledRig(account: AccountDTO) async throws -> StoreRig {
        let rest = FakeRestAPI(fallback: .account(account))
        rest.enqueue(.failure)  // the first read of `start()`
        let rig = StoreRig(rest: rest)
        try await rig.start()
        try await rig.deliver([
            acceptedEvent(1, client: "C-1"), fillEvent(2, quantity: 100, price: 1_000, remaining: 100),
            ledgerEvent(3, ledgerSeq: 1, quantity: 100, price: 1_000, cashAfter: 99_000, positionAfter: 100),
            cancelledEvent(4, remaining: 100),
        ])
        #expect(rig.store.state.lastEventSeq == 4)
        return rig
    }

    @Test func reconcileDetectsDrift() async throws {
        let rig = try await settledRig(
            account: accountSnapshot(epoch: "E1", cash: 98_000, positions: [(1, 100)], lastEventSeq: 4))
        let before = rig.store.state
        let verdict = await rig.store.reconcile()
        #expect(verdict == .drift("cash: app 99000 satang, server 98000 satang"))
        #expect(rig.store.state == before)
    }

    @Test func reconcileReportsInFlight() async throws {
        let rig = try await settledRig(
            account: accountSnapshot(epoch: "E1", cash: 99_000, positions: [(1, 100)], lastEventSeq: 5))
        let verdict = await rig.store.reconcile()
        #expect(verdict == .inFlight)
    }

    @Test func reconcileNamesEveryPositionThatDiffers() async throws {
        let rig = try await settledRig(
            account: accountSnapshot(epoch: "E1", cash: 99_000, positions: [(1, 200), (2, 0), (3, 50)],
                                     lastEventSeq: 4))
        let verdict = await rig.store.reconcile()
        #expect(verdict == .drift("symbol 1: app 100 shares, server 200 shares; symbol 3: app 0 shares, server 50 shares"))
    }

    @Test func reconcileIsConsistentWhenEverythingMatches() async throws {
        let rig = try await settledRig(
            account: accountSnapshot(epoch: "E1", cash: 99_000, positions: [(1, 100), (4, 0)], lastEventSeq: 4))
        let verdict = await rig.store.reconcile()
        #expect(verdict == .consistent)
    }

    /// Another epoch with the same number and the same money is still not comparable.
    @Test func reconcileReportsInFlightForAnotherEpoch() async throws {
        let rig = try await settledRig(
            account: accountSnapshot(epoch: "E2", cash: 99_000, positions: [(1, 100)], lastEventSeq: 4))
        let verdict = await rig.store.reconcile()
        #expect(verdict == .inFlight)
    }

    @Test func reconcileReportsInFlightWhenTheAccountCannotBeRead() async throws {
        let rig = try await settledRig(
            account: accountSnapshot(epoch: "E1", cash: 99_000, positions: [(1, 100)], lastEventSeq: 4))
        rig.rest.enqueue(.failure)
        let before = rig.store.state
        let verdict = await rig.store.reconcile()
        #expect(verdict == .inFlight)
        #expect(rig.store.state == before)
        // Positive control: the next read answers, and the same state is consistent.
        let next = await rig.store.reconcile()
        #expect(next == .consistent)
    }
}

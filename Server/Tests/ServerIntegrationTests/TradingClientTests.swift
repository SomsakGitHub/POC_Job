import Contracts
import ExchangeCore
import Foundation
import Testing
import TradeCore
import TradeNetworking
@testable import ExchangeServerKit

/// The trading store over the gRPC client against a real server on ephemeral ports: orders end to end, drops,
/// resets, bursts, a stalled market client and an event log that no longer holds what the client asks for.
@Suite(.timeLimit(.minutes(2)))
struct TradingClientTests {
    /// The cash the account starts with, in satang.
    static let startingCash: Int64 = 100_000_000

    @Test func submitMarketBuyEndToEnd() async throws {
        try await withTradingStore { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            await rig.store.submit(marketDraft("buy-1"))
            let caughtUp = await rig.caughtUp()
            #expect(caughtUp)
            let state = await rig.state()
            let row = try #require(state.row("buy-1"))
            #expect(row.status == .filled)
            #expect(row.filledQuantity == 100)
            #expect(state.cash < Self.startingCash)
            #expect(state.positions[1] == 100)
            #expect(state.ledger.count == 1)
            #expect(rig.latency.summary(.orderSubmitToAck).count == 1)
            #expect(rig.latency.summary(.orderServerProcessing).count == 1)
            #expect(rig.latency.summary(.orderSubmitToFill).count == 1)
        }
    }

    @Test func invalidOrderShowsRejectNotCrash() async throws {
        try await withTradingStore { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            await rig.store.submit(marketDraft("odd-lot", quantity: 150))
            let caughtUp = await rig.caughtUp()
            #expect(caughtUp)
            let state = await rig.state()
            let row = try #require(state.row("odd-lot"))
            #expect(row.status == .rejected)
            #expect(row.rejectReason == .invalidLot)
            #expect(row.orderId == nil)
            #expect(state.cash == Self.startingCash)
            // The order call answered with the refusal, so the submit's round trip was recorded.
            #expect(rig.latency.summary(.orderSubmitToAck).count == 1)
        }
    }

    @Test func resubmittingSameDraftDoesNotDuplicate() async throws {
        try await withTradingStore { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            await rig.store.submit(marketDraft("twice"))
            await rig.store.submit(marketDraft("twice"))
            let caughtUp = await rig.caughtUp()
            #expect(caughtUp)
            let state = await rig.state()
            #expect(state.orders.map(\.id) == ["twice"])
            let accepted = rig.client.events.filter { $0.accepted.clientOrderID == "twice" && $0.kind == "accepted" }
            #expect(accepted.count == 1)
            #expect(rig.latency.summary(.orderSubmitToAck).count == 2)
        }
    }

    @Test func streamResumesAfterDropWithoutDuplicates() async throws {
        try await withTradingStore { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            for index in 0..<20 {
                if index == 6 || index == 13 { try await rig.rest.dropConnections() }
                await rig.store.submit(marketDraft("drop-\(index)"))
            }
            // A submit that found no connection for all three attempts is sent again with its id.
            for row in await rig.state().orders where row.status == .unknown {
                await rig.store.retryUnconfirmed(clientOrderId: row.id)
            }
            let caughtUp = await rig.caughtUp()
            #expect(caughtUp)
            let state = await rig.state()
            #expect(state.orders.count == 20)
            #expect(Set(state.orders.map(\.id)).count == 20)
            #expect(!state.hasUnanswered)
            let delivered = rig.client.events.map(\.eventSeq)
            #expect(isStrictlyIncreasing(delivered), "an event was delivered twice or out of order")
            #expect(isContiguousFromOne(delivered), "an event was missed")
            #expect(state.ledger.reduce(0) { $0 + $1.cashDelta } == state.cash - Self.startingCash)
            // Both drops really ended the stream.
            #expect(rig.log.states.filter(\.isReconnecting).count >= 2)
        }
    }

    @Test func serverResetClearsPhantomState() async throws {
        try await withTradingStore { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            await rig.store.submit(try await restingDraft("resting", engine: rig.app.engine))
            let caughtUp = await rig.caughtUp()
            #expect(caughtUp)
            let before = await rig.state()
            #expect(before.row("resting")?.status == .accepted)

            let index = rig.log.count
            let epoch = try await rig.rest.resetServer()
            #expect(epoch != before.epoch)
            let reconnected = await rig.connected(after: index)
            #expect(reconnected)
            let cleared = await eventually {
                let state = await rig.state()
                return state.epoch == epoch && state.orders.isEmpty
            }
            #expect(cleared)
            let state = await rig.state()
            #expect(!state.hasUnanswered)
            #expect(state.epochChanges == 1)
            #expect(state.cash == Self.startingCash)
            #expect(state.positions.isEmpty)
        }
    }

    @Test func eventsNeverDroppedUnderBurst() async throws {
        try await withTradingStore { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            _ = try await rig.rest.setLab(LabPatch(stress: true))
            for index in 0..<1_000 {
                await rig.store.submit(marketDraft("burst-\(index)", index.isMultiple(of: 2) ? .buy : .sell))
            }
            let caughtUp = await rig.caughtUp()
            #expect(caughtUp)
            let state = await rig.state()
            let engine = await rig.app.engine.account()
            #expect(state.lastEventSeq == engine.lastEventSeq)
            #expect(state.orders.count == 1_000)
            #expect(!state.hasUnanswered)
            let delivered = rig.client.events.map(\.eventSeq)
            #expect(isStrictlyIncreasing(delivered))
            #expect(isContiguousFromOne(delivered))
            #expect(delivered.count == Int(engine.lastEventSeq))
        }
    }

    @Test func ordersUnaffectedByStalledMarketClient() async throws {
        try await withTradingStore { rig in
            // A market client that subscribes to every symbol and then never reads.
            let symbols = try await rig.rest.symbols()
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let url = try #require(URL(string: "ws://\(rig.config.host):\(rig.config.restPort)/ws/market"))
            let stalled = session.webSocketTask(with: url)
            stalled.resume()
            let tickers = symbols.map { "\"\($0.ticker)\"" }.joined(separator: ",")
            try await stalled.send(.string("{\"op\":\"subscribe\",\"symbols\":[\(tickers)]}"))
            let registered = await eventually { await rig.app.hub.connectionCount() == 1 }
            #expect(registered)
            _ = try await rig.rest.setLab(LabPatch(stress: true))
            // The stall is real: every subscribed symbol has a quote waiting on the connection, and keeps it.
            let stalledProven = await holdsStall(rig.app.hub, symbols: symbols.count)
            try #require(stalledProven, "the stall never took effect: the market client's quotes did not back up")

            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            for index in 0..<200 {
                await rig.store.submit(marketDraft("calm-\(index)", index.isMultiple(of: 2) ? .buy : .sell))
            }
            let caughtUp = await rig.caughtUp()
            #expect(caughtUp)
            let delivered = rig.client.events.map(\.eventSeq)
            #expect(isStrictlyIncreasing(delivered))
            #expect(isContiguousFromOne(delivered))
            let state = await rig.state()
            #expect(state.orders.count == 200)
            #expect(!state.hasUnanswered)
            // Bounded at one quote per symbol, and still full: the stall lasted through every order.
            let pending = await rig.app.hub.maxPendingCount()
            #expect(pending <= 12)
            #expect(pending == symbols.count)
            stalled.cancel(with: .goingAway, reason: nil)
        }
    }

    @Test func outOfRangeRecoversFromAccount() async throws {
        var config = ServerConfig.ephemeral
        config.eventLogCapacity = 10
        try await withTradingStore(config: config) { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            await rig.store.submit(marketDraft("before"))
            let caughtUp = await rig.caughtUp()
            #expect(caughtUp)
            await rig.client.stop()

            for index in 0..<50 {
                _ = await rig.app.engine.submit(OrderRequest(
                    clientOrderId: "away-\(index)", symbolId: 1, side: index.isMultiple(of: 2) ? .buy : .sell,
                    type: .market, quantity: 100, limitPrice: nil))
            }
            let delivered = rig.client.events.count
            await rig.store.start()
            let recovered = await rig.caughtUp()
            #expect(recovered)
            let state = await rig.state()
            let engine = await rig.app.engine.account()
            #expect(state.cash == engine.cash)
            #expect(state.positions == engine.positions.filter { $0.value > 0 })
            #expect(state.lastEventSeq == engine.lastEventSeq)
            #expect(state.epochChanges == 0)
            // The old rows went with the recovery, and nothing of the lost stretch was replayed.
            #expect(state.orders.isEmpty)
            #expect(rig.client.events.count == delivered)
            let verdict = await rig.store.reconcile()
            #expect(verdict == .consistent)
        }
    }

    @Test func cancelRestingOrder() async throws {
        try await withTradingStore { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            await rig.store.submit(try await restingDraft("to-cancel", engine: rig.app.engine))
            let accepted = await rig.caughtUp()
            #expect(accepted)
            let placed = await rig.state().row("to-cancel")
            let orderId = try #require(placed?.orderId)
            await rig.store.cancel(orderId: orderId)
            let cancelled = await eventually { await rig.state().row("to-cancel")?.status == .cancelled }
            #expect(cancelled)
            let row = await rig.state().row("to-cancel")
            #expect(row?.rejectReason == nil)
            #expect(row?.filledQuantity == 0)
        }
    }

    @Test func reconcileConsistentAfterFills() async throws {
        try await withTradingStore { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            for index in 0..<50 {
                await rig.store.submit(marketDraft("fill-\(index)", index.isMultiple(of: 2) ? .buy : .sell))
            }
            let caughtUp = await rig.caughtUp()
            #expect(caughtUp)
            let state = await rig.state()
            #expect(!state.ledger.isEmpty)
            let verdict = await rig.store.reconcile()
            #expect(verdict == .consistent)
        }
    }
}

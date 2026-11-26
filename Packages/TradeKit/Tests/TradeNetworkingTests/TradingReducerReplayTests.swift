import Contracts
import Testing
import TradeCore
import TradeNetworking

/// Plays `events` the way a running app sees them: the app submits every order a moment before the server's
/// `accepted` event arrives, so its row is already there, pending and stamped with the time the server accepted it,
/// and the events then arrive in order.
private func liveRun(_ events: [Tp_OrderEvent]) throws -> TradingState {
    var state = TradingState()
    for event in events {
        if case .accepted(let accepted)? = event.event {
            let side = try #require(Side(wire: accepted.side))
            let type = try #require(OrderType(wire: accepted.type))
            let sent = OrderDraft(
                clientOrderId: accepted.clientOrderID, symbolId: accepted.symbolID, side: side, type: type,
                quantity: accepted.quantity,
                limitPrice: accepted.limitPrice == 0 ? nil : Price(satang: accepted.limitPrice))
            TradingReducer.reduce(&state, .localSubmitted(sent, createdNs: event.serverTsNs))
        }
        TradingReducer.reduce(&state, .event(event))
    }
    return state
}

extension TradingReducerTests {
    // MARK: Replay

    /// A log of five orders: filled in two parts, resting after a part fill, cancelled untouched, cut short for want
    /// of liquidity, and untouched.
    private static func busyLog() -> ServerLog {
        var server = ServerLog(epoch: "E1", cash: 100_000_000, startNs: 2_000_000_000)
        let first = server.accept(client: "C-1", symbol: 1, side: .buy, quantity: 200)
        server.fill(first, quantity: 100, price: 3_425, remaining: 100)
        server.fill(first, quantity: 100, price: 3_450, remaining: 0)
        let second = server.accept(client: "C-2", symbol: 2, side: .buy, type: .limit, quantity: 500, limitPrice: 1_000)
        server.fill(second, quantity: 200, price: 1_000, remaining: 300)
        let third = server.accept(client: "C-3", symbol: 1, side: .sell, type: .limit, quantity: 100, limitPrice: 3_500)
        server.cancel(third, remaining: 100)
        let fourth = server.accept(client: "C-4", symbol: 1, side: .sell, quantity: 300)
        server.fill(fourth, quantity: 150, price: 3_440, remaining: 150)
        server.cancel(fourth, remaining: 150, reason: .noLiquidity)
        server.accept(client: "C-5", symbol: 2, side: .buy, type: .limit, quantity: 100, limitPrice: 900)
        return server
    }

    /// A relaunch that replays the whole log from sequence 0 into a fresh state ends where the run that lived through
    /// it ended: the same rows, ledger, cash and positions. The live run had a pending row for every order, the replay
    /// makes the rows from the events, and both go on alike from there.
    @Test func replayOfTheWholeLogEqualsTheLiveRun() throws {
        let server = Self.busyLog()
        let log = server.events
        #expect(log.count == 15)

        let live = try liveRun(log)
        let replayed = reduced(events: log)

        #expect(live.orders.count == 5)
        #expect(live.ledger.count == 4)
        #expect(live.cash == server.cash)
        #expect(live.positions == server.positions)
        #expect(replayed == live)
        #expect(replayed.orders.map(\.status) == [.accepted, .cancelled, .cancelled, .partiallyFilled, .filled])
        #expect(replayed.orders.map(\.id) == ["C-5", "C-4", "C-3", "C-2", "C-1"])
        #expect(replayed.cash == server.cash)
        #expect(replayed.positions == server.positions)

        // Both carry on alike: the same next fill gives the same row.
        let next = fillEvent(16, order: "O-000002", symbol: 2, quantity: 100, price: 1_001, remaining: 200)
        let liveNext = reduced(events: [next], from: live)
        #expect(liveNext == reduced(events: [next], from: replayed))
        // (200 * 1000 + 100 * 1001) / 300 is 1000.3.
        #expect(liveNext.order("C-2")?.averageFillPrice == Price(satang: 1_000))
    }

    /// Replaying the log a second time, over the state the first replay built, changes nothing: every event is a
    /// repeat.
    @Test func replayingTheLogAgainChangesNothing() {
        let log = Self.busyLog().events
        let once = reduced(events: log)
        #expect(once.orders.count == 5)
        #expect(reduced(events: log, from: once) == once)
    }

    /// A refused order is in the live run as a rejected row but not in a replay, which has no row for an order it
    /// never saw: the one thing a relaunch cannot bring back.
    @Test func aReplayDoesNotBringBackARefusedOrder() throws {
        var server = ServerLog(epoch: "E1")
        server.refuse(client: "C-1", reason: .insufficientFunds)
        let accepted = server.accept(client: "C-2", quantity: 100)
        server.cancel(accepted, remaining: 100)
        let log = server.events

        let live = reduced(
            [.localSubmitted(draft("C-1"), createdNs: 1), .localSubmitted(draft("C-2", quantity: 100), createdNs: 2)])
        let afterLive = reduced(events: log, from: live)
        #expect(afterLive.order("C-1")?.status == .rejected)
        #expect(afterLive.order("C-1")?.rejectReason == .insufficientFunds)

        let replayed = reduced(events: log)
        #expect(replayed.order("C-1") == nil)
        #expect(replayed.order("C-2")?.status == .cancelled)
        #expect(replayed.lastEventSeq == afterLive.lastEventSeq)
    }

    // MARK: Fresh state, determinism, concurrency

    /// The state of a fresh launch has no epoch, sequence 0, no epoch changes, no rows, no cash and no positions.
    @Test func aFreshStateIsEmpty() {
        let state = TradingState()
        #expect(state.epoch == nil)
        #expect(state.lastEventSeq == 0)
        #expect(state.epochChanges == 0)
        #expect(state.orders.isEmpty)
        #expect(state.ledger.isEmpty)
        #expect(state.cash == 0)
        #expect(state.positions.isEmpty)
    }

    /// The same action on two copies of one state gives two equal states, for every kind of action, and each of the
    /// actions below changes this state, so the equality is not two untouched copies.
    @Test func reduceIsDeterministic() {
        let state = stateWithEveryStatus()
        let actions: [TradingAction] = [
            .localSubmitted(draft("C-new"), createdNs: 5),
            .submitRejected(clientOrderId: "C-pending", reason: .invalidLot),
            .submitUnconfirmed(clientOrderId: "C-pending"),
            .event(fillEvent(8, order: "O-000001", quantity: 50, price: 3_400, remaining: 150)),
            .event(acceptedEvent(8, epoch: "E2", client: "C-x", order: "O-000009")),
            .account(accountSnapshot(epoch: "E1", cash: 1, lastEventSeq: 9), adoptEventSeq: true),
            .clear,
        ]
        #expect(actions.count == 7)
        for action in actions {
            var first = state
            var second = state
            TradingReducer.reduce(&first, action)
            TradingReducer.reduce(&second, action)
            #expect(first == second)
            #expect(first != state)
        }
    }

    /// The state and the actions are plain values that cross task boundaries (this does not compile otherwise), and
    /// the reducer gives the same answer on another task as on this one.
    @Test func theStateAndTheActionsCrossTaskBoundaries() async {
        let state = stateWithEveryStatus()
        let action = TradingAction.event(fillEvent(8, order: "O-000001", quantity: 50, price: 3_400, remaining: 150))
        let elsewhere = await Task.detached {
            reduced([action], from: state)
        }.value
        #expect(elsewhere == reduced([action], from: state))
        #expect(elsewhere != state)
    }
}

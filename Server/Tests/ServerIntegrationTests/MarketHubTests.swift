import Contracts
import ExchangeCore
import Testing
import TradeCore
@testable import ExchangeServerKit

/// The hub with fake connections, in real time. Bounds are generous: a busy test run delays every task, so a test
/// checks what must never happen (too many frames, a frame too early, a frame too soon after another) and that the
/// expected thing happens eventually, never an exact interval.
@Suite("MarketHubTests")
struct MarketHubTests {
    @Test func subscribeSendsFullStateImmediately() async throws {
        let hub = makeHub()
        await hub.publish(allQuotes(offset: 0))
        let connection = FakeConnection()
        let id = await connection.register(with: hub)

        let unknown = await hub.subscribe(id, tickers: ["AOT", "PTT"])
        #expect(unknown.isEmpty)
        // The hub sends no heartbeat within the test's patience, so a frame that arrives was sent for the subscribe.
        await connection.expectFrames(1)
        let first = try #require(connection.frames.first)
        #expect(first.frame.frameSeq == 1)
        #expect(first.frame.updates.map(\.symbolID) == [1, 2])
        #expect(first.frame.updates.map(\.seq) == [1, 1])
        let expected = [makeQuote(1, last: 1_000), makeQuote(2, last: 2_000)].map {
            MarketFrameMapping.update($0, seq: 1)
        }
        #expect(first.frame.updates == expected)
        #expect(first.frame.serverSendNs <= first.receivedNs)
    }

    @Test func seqIncreasesPerSymbol() async throws {
        let hub = makeHub()
        await hub.publish(allQuotes(offset: 0))
        let connection = FakeConnection()
        let id = await connection.register(with: hub)
        _ = await hub.subscribe(id, tickers: ["PTT", "AOT"])
        await connection.expectFrames(1)

        for step in 1...3 {
            await hub.publish([makeQuote(1, last: 1_000 + Int64(step))])
            await connection.expectFrames(1 + step)
        }
        await hub.publish([makeQuote(2, last: 2_001)])
        await connection.expectFrames(5)
        // Unsubscribing and subscribing again does not restart the numbering, and neither does a resync.
        await hub.unsubscribe(id, tickers: ["PTT"])
        _ = await hub.subscribe(id, tickers: ["PTT"])
        await connection.expectFrames(6)
        let resynced = await hub.resync(id, ticker: "PTT")
        #expect(resynced)
        await connection.expectFrames(7)

        let updates = connection.updates
        #expect(updates.filter { $0.symbolID == 1 }.map(\.seq) == [1, 2, 3, 4, 5, 6])
        #expect(updates.filter { $0.symbolID == 2 }.map(\.seq) == [1, 2])
        #expect(connection.frames.map(\.frame.frameSeq) == Array(1...7))
    }

    @Test func framesBatchWithin5ms() async throws {
        let hub = makeHub()
        let connection = FakeConnection()
        let id = await connection.register(with: hub)
        _ = await hub.subscribe(id, tickers: allTickers)

        // 1,000 publishes of all twelve symbols over about 200 ms.
        for round in 1...1_000 {
            await hub.publish(allQuotes(offset: Int64(round)))
            if round.isMultiple(of: 50) { try await Task.sleep(for: .milliseconds(10)) }
        }
        let latest = allQuotes(offset: 1_000).map(\.last.satang)
        let settled = await eventually { connection.frames.last?.frame.updates.map(\.last) == latest }
        #expect(settled, "the last frame does not carry the latest quote of each symbol")

        let frames = connection.frames
        #expect(!frames.isEmpty)
        #expect(frames.count <= 60, "\(frames.count) frames for about 200 ms of publishing")
        for frame in frames {
            let symbols = frame.frame.updates.map(\.symbolID)
            #expect(symbols == symbols.sorted() && Set(symbols).count == symbols.count)
        }
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            #expect(later.at - earlier.at >= .milliseconds(4), "two frames \(later.at - earlier.at) apart")
        }
    }

    @Test func slowConsumerIsConflated() async throws {
        let hub = makeHub()
        let connection = FakeConnection(holdsFirstSend: true)
        let id = await connection.register(with: hub)
        _ = await hub.subscribe(id, tickers: allTickers)
        await hub.publish(allQuotes(offset: 0))
        await connection.expectFrames(1)  // the send is now held
        let heldSince = ContinuousClock.now

        // The hub takes every publish while the send stays suspended: it never waits for a connection.
        let published = await finishes(within: patience) {
            for round in 1...5_000 {
                await hub.publish(allQuotes(offset: Int64(round)))
            }
        }
        #expect(published, "the publishes waited for the suspended send")
        let pendingMax = await hub.maxPendingCount()
        // One waiting quote per symbol, however many publishes came in: at most twelve, and here all twelve.
        #expect(pendingMax == 12)
        #expect(connection.frames.count == 1)

        try await Task.sleep(until: heldSince + .milliseconds(500))
        connection.releaseFirstSend()
        await connection.expectFrames(2)
        let next = try #require(connection.frames.dropFirst().first)
        #expect(next.frame.updates.map(\.last) == allQuotes(offset: 5_000).map(\.last.satang))
        #expect(next.frame.updates.map(\.seq) == Array(repeating: 2, count: 12))
    }

    @Test func heartbeatWhenIdle() async throws {
        let hub = MarketHub(symbols: SymbolCatalog.defaultSymbols, lab: LabControls())
        let connection = FakeConnection()
        let registered = ContinuousClock.now
        _ = await connection.register(with: hub)

        try await Task.sleep(for: .milliseconds(1_200))
        let frames = await eventually { connection.frames.count >= 1 }
        #expect(frames)
        let first = try #require(connection.frames.first)
        #expect(first.frame.updates.isEmpty)
        #expect(first.frame.frameSeq == 1)
        #expect(first.at - registered >= .milliseconds(900), "a heartbeat after only \(first.at - registered)")
    }

    @Test func labLatencyDelaysDelivery() async throws {
        let lab = LabControls()
        await lab.apply(LabPatch(extraLatencyMs: 100))
        let hub = makeHub(lab: lab)
        await hub.publish(allQuotes(offset: 0))
        let connection = FakeConnection()
        let id = await connection.register(with: hub)
        _ = await hub.subscribe(id, tickers: ["PTT"])
        await hub.publish([makeQuote(1, last: 1_001)])

        await connection.expectFrames(1)
        for received in connection.frames {
            let delay = received.receivedNs - received.frame.serverSendNs
            #expect(delay >= 100_000_000, "sent \(delay) ns after its stamp")
        }
    }

    /// With `dropUpdates` on, every second published update is withheld but keeps its `seq`; the states that subscribe
    /// and resync queue are always sent and do not move the alternation; with the setting off nothing is withheld and
    /// the alternation stands still.
    @Test func dropUpdatesCreatesGap() async throws {
        let lab = LabControls()
        await lab.apply(LabPatch(dropUpdates: true))
        let hub = makeHub(lab: lab)
        await hub.publish(allQuotes(offset: 0))
        let connection = FakeConnection()
        let id = await connection.register(with: hub)
        var last: Int64 = 1_000

        func publishAndSettle() async {
            last += 1
            await hub.publish([makeQuote(1, last: last)])
            _ = await eventually { await hub.maxPendingCount() == 0 }
        }

        _ = await hub.subscribe(id, tickers: ["PTT"])  // seq 1, exempt
        _ = await eventually { await hub.maxPendingCount() == 0 }
        for _ in 1...4 { await publishAndSettle() }  // seq 2 sent, 3 withheld, 4 sent, 5 withheld
        _ = await hub.resync(id, ticker: "PTT")  // seq 6, exempt
        _ = await eventually { await hub.maxPendingCount() == 0 }
        for _ in 1...2 { await publishAndSettle() }  // seq 7 sent, 8 withheld
        await lab.apply(LabPatch(dropUpdates: false))
        await publishAndSettle()  // seq 9 sent; the alternation stands still
        await lab.apply(LabPatch(dropUpdates: true))
        for _ in 1...2 { await publishAndSettle() }  // seq 10 sent, 11 withheld

        let expected: [UInt64] = [1, 2, 4, 6, 7, 9, 10]
        await connection.expectFrames(expected.count)
        let frames = connection.frames
        #expect(frames.flatMap(\.frame.updates).map(\.seq) == expected)
        // A frame whose every update was withheld is not sent, so no frame number is missing.
        #expect(frames.map(\.frame.frameSeq) == Array(1...UInt64(frames.count)))
    }

    @Test func dropAllClosesConnections() async throws {
        let hub = makeHub()
        await hub.publish(allQuotes(offset: 0))
        let idle = FakeConnection()
        let stuck = FakeConnection(holdsFirstSend: true)
        let idleId = await idle.register(with: hub)
        let stuckId = await stuck.register(with: hub)
        _ = await hub.subscribe(idleId, tickers: ["PTT"])
        _ = await hub.subscribe(stuckId, tickers: ["PTT"])
        await stuck.expectFrames(1)  // its flusher is now suspended inside `send`

        await hub.dropAll()
        #expect(idle.closeCount == 1)
        #expect(stuck.closeCount == 1)
        let remaining = await hub.connectionCount()
        #expect(remaining == 0)

        // Nothing more reaches a dropped connection, and a late unregister is a no-op.
        let idleFrames = idle.frames.count
        await hub.publish(allQuotes(offset: 1))
        let pending = await hub.maxPendingCount()
        #expect(pending == 0)
        stuck.releaseFirstSend()
        try await Task.sleep(for: .milliseconds(100))
        #expect(stuck.frames.count == 1)
        #expect(idle.frames.count == idleFrames)
        await hub.unregister(idleId)
        await hub.unregister(stuckId)
        #expect(idle.closeCount == 1)
        #expect(stuck.closeCount == 1)

        // The hub still serves new connections.
        let later = FakeConnection()
        let laterId = await later.register(with: hub)
        _ = await hub.subscribe(laterId, tickers: ["PTT"])
        await later.expectFrames(1)
    }
}

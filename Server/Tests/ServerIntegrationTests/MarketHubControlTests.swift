import Contracts
import ExchangeCore
import Testing
import TradeCore
@testable import ExchangeServerKit

/// Subscriptions, resync, the heartbeat timer and the life of a connection in the hub.
extension MarketHubTests {
    @Test func subscribeReportsUnknownTickersInRequestOrderAndSubscribesTheKnownOnes() async throws {
        let hub = makeHub()
        await hub.publish(allQuotes(offset: 0))
        let connection = FakeConnection()
        let id = await connection.register(with: hub)

        let unknown = await hub.subscribe(id, tickers: ["ZZZ", "PTT", "AAA", "ptt"])
        #expect(unknown == ["ZZZ", "AAA", "ptt"])
        await connection.expectFrames(1)
        #expect(connection.updates.map(\.symbolID) == [1])
    }

    @Test func aSymbolWithoutAQuoteIsSentAtItsFirstPublish() async throws {
        let hub = makeHub()
        let connection = FakeConnection()
        let id = await connection.register(with: hub)
        _ = await hub.subscribe(id, tickers: ["AOT"])
        let pending = await hub.maxPendingCount()
        #expect(pending == 0)

        await hub.publish([makeQuote(2, last: 5_800)])
        await connection.expectFrames(1)
        #expect(connection.updates.map(\.last) == [5_800])
        #expect(connection.updates.map(\.seq) == [1])
    }

    /// The hub keeps the latest quote of every symbol, subscribed or not, and marks it pending only where it is
    /// subscribed.
    @Test func publishKeepsTheLatestQuoteForLaterSubscribers() async throws {
        let hub = makeHub()
        let connection = FakeConnection()
        let id = await connection.register(with: hub)
        _ = await hub.subscribe(id, tickers: ["AOT"])
        await hub.publish([makeQuote(1, last: 3_400)])
        await hub.publish([makeQuote(1, last: 3_425)])
        let pending = await hub.maxPendingCount()
        #expect(pending == 0)

        _ = await hub.subscribe(id, tickers: ["PTT"])
        await connection.expectFrames(1)
        #expect(connection.updates.map(\.last) == [3_425])
    }

    @Test func unsubscribeDropsThePendingQuoteAndStopsUpdates() async throws {
        let hub = makeHub()
        await hub.publish(allQuotes(offset: 0))
        let connection = FakeConnection(holdsFirstSend: true)
        let id = await connection.register(with: hub)
        _ = await hub.subscribe(id, tickers: ["PTT"])
        await connection.expectFrames(1)  // the send is now held
        _ = await hub.subscribe(id, tickers: ["AOT"])
        await hub.publish(allQuotes(offset: 1))
        let before = await hub.maxPendingCount()
        #expect(before == 2)

        await hub.unsubscribe(id, tickers: ["PTT", "NOPE"])
        let after = await hub.maxPendingCount()
        #expect(after == 1)
        await hub.publish(allQuotes(offset: 2))
        connection.releaseFirstSend()
        await connection.expectFrames(2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(connection.frames.dropFirst().flatMap(\.frame.updates).map(\.symbolID) == [2])
    }

    @Test func resyncSendsTheStateOfAKnownTickerAndRejectsAnUnknownOne() async throws {
        let hub = makeHub()
        await hub.publish(allQuotes(offset: 0))
        let connection = FakeConnection()
        let id = await connection.register(with: hub)

        let unknown = await hub.resync(id, ticker: "NOPE")
        #expect(!unknown)
        let known = await hub.resync(id, ticker: "AOT")  // not subscribed: still sent once
        #expect(known)
        await connection.expectFrames(1)
        #expect(connection.updates == [MarketFrameMapping.update(makeQuote(2, last: 2_000), seq: 1)])

        await hub.publish(allQuotes(offset: 1))
        let pending = await hub.maxPendingCount()
        #expect(pending == 0)
    }

    /// The idle timer restarts at every frame sent: the heartbeat comes a second after the last frame, not a second
    /// after the connection opened.
    @Test func heartbeatTimerRestartsAtEverySentFrame() async throws {
        let hub = MarketHub(symbols: SymbolCatalog.defaultSymbols, lab: LabControls())
        await hub.publish(allQuotes(offset: 0))
        let connection = FakeConnection()
        let id = await connection.register(with: hub)
        try await Task.sleep(for: .milliseconds(600))
        _ = await hub.subscribe(id, tickers: ["PTT"])

        // On a slow run a heartbeat may come before the subscribe; what counts is the frame after the state.
        func stateIndex() -> Int? { connection.frames.firstIndex { !$0.frame.updates.isEmpty } }
        let followed = await eventually { stateIndex().map { connection.frames.count > $0 + 1 } ?? false }
        #expect(followed)
        let frames = connection.frames
        let index = try #require(stateIndex())
        let heartbeat = frames[index + 1]
        #expect(heartbeat.frame.updates.isEmpty)
        let silence = heartbeat.at - frames[index].at
        #expect(silence >= .milliseconds(900), "a heartbeat only \(silence) after the last frame")
    }

    /// Whichever of unregister, dropAll and a second unregister comes first closes the connection; the others do
    /// nothing.
    @Test func closeIsCalledExactlyOnce() async throws {
        let hub = makeHub()
        let connection = FakeConnection()
        let id = await connection.register(with: hub)

        await hub.unregister(id)
        let closed = await eventually { connection.closeCount == 1 }
        #expect(closed)
        await hub.unregister(id)
        await hub.dropAll()
        await hub.unregister(id + 1_000)
        try await Task.sleep(for: .milliseconds(50))
        #expect(connection.closeCount == 1)
        let remaining = await hub.connectionCount()
        #expect(remaining == 0)
    }

    @Test func aFailedSendEndsTheConnection() async throws {
        let hub = makeHub()
        await hub.publish(allQuotes(offset: 0))
        let connection = FakeConnection(failSends: true)
        let id = await connection.register(with: hub)
        _ = await hub.subscribe(id, tickers: ["PTT"])

        let closed = await eventually { connection.closeCount == 1 }
        #expect(closed)
        let remaining = await hub.connectionCount()
        #expect(remaining == 0)
        await hub.unregister(id)
        await hub.dropAll()
        await hub.publish(allQuotes(offset: 1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(connection.closeCount == 1)
        #expect(connection.frames.count == 1)
    }
}

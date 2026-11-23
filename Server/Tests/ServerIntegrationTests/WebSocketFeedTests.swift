import Contracts
import ExchangeCore
import Foundation
import Hummingbird
import HummingbirdWebSocket
import Synchronization
import Testing
import TradeCore
@testable import ExchangeServerKit

/// `/ws/market` through a real `URLSessionWebSocketTask`, against a running server whose market moves in real time.
@Suite("WebSocketFeedTests")
struct WebSocketFeedTests {
    private func int64(_ object: [String: Any], _ key: String) -> Int64? {
        (object[key] as? NSNumber)?.int64Value
    }

    /// The `message` of an error reply, or nil when `object` is not one.
    private func errorMessage(_ object: [String: Any]) -> String? {
        object["op"] as? String == "error" ? object["message"] as? String : nil
    }

    @Test func subscribeReceivesBinaryFrames() async throws {
        try await withFeedServer { _, client, _ in
            try await client.send(#"{"op":"subscribe","symbols":["AOT","PTT"]}"#)
            let first = try await client.nextFrame { !$0.updates.isEmpty }
            #expect(first.updates.map(\.symbolID) == [1, 2])
            #expect(first.updates.map(\.seq) == [1, 1])
            #expect(first.updates.allSatisfy { $0.last > 0 && $0.hasCandle1S && $0.hasCandle5M })
            let stampAge = WallClock.nowNs() - first.serverSendNs
            #expect(stampAge >= 0 && stampAge < Int64(patience.components.seconds) * 1_000_000_000)

            // The market moves: a later update of PTT carries a higher seq, in a later frame.
            let later = try await client.nextFrame { $0.updates.contains { $0.symbolID == 1 && $0.seq > 1 } }
            #expect(later.frameSeq > first.frameSeq)
        }
    }

    @Test func pingPong() async throws {
        try await withFeedServer { _, client, _ in
            let sent = WallClock.nowNs()
            try await client.send(#"{"op":"ping","clientNs":123}"#)
            let pong = try await client.nextText()
            let received = WallClock.nowNs()
            #expect(pong["op"] as? String == "pong")
            #expect(int64(pong, "clientNs") == 123)
            // Read between the send and the receipt; within a second of now whenever the round trip takes less.
            let serverNs = try #require(int64(pong, "serverNs"))
            #expect(sent <= serverNs && serverNs <= received)
        }
    }

    @Test func resyncSendsFullState() async throws {
        try await withFeedServer { _, client, _ in
            try await client.send(#"{"op":"resync","symbol":"NOPE"}"#)
            let rejected = try await client.nextText()
            #expect(errorMessage(rejected)?.contains("NOPE") == true)

            // Not subscribed: the state comes once, numbered as the first update of PTT on this connection.
            try await client.send(#"{"op":"resync","symbol":"PTT"}"#)
            let frame = try await client.nextFrame { !$0.updates.isEmpty }
            let update = try #require(frame.updates.first)
            #expect(frame.updates.count == 1)
            #expect(update.symbolID == 1)
            #expect(update.seq == 1)
            #expect(update.last > 0 && update.bid > 0 && update.ask > update.bid && update.dayVolume > 0)
            #expect(update.hasCandle1S && update.hasCandle1M && update.hasCandle5M)
        }
    }

    @Test func unsubscribeStopsUpdates() async throws {
        try await withFeedServer { _, client, _ in
            try await client.send(#"{"op":"subscribe","symbols":["PTT"]}"#)
            _ = try await client.nextFrame { $0.updates.contains { $0.symbolID == 1 } }
            try await client.send(#"{"op":"unsubscribe","symbols":["PTT","NOPE"]}"#)
            try await client.send(#"{"op":"subscribe","symbols":["AOT"]}"#)
            // A frame taken before the unsubscribe may still be on its way; once AOT's state has arrived, the
            // unsubscribe has long been applied.
            _ = try await client.nextFrame { $0.updates.contains { $0.symbolID == 2 && $0.seq == 1 } }

            var frames = 0
            while frames < 10 {
                let frame = try await client.nextFrame { !$0.updates.isEmpty }
                #expect(frame.updates.map(\.symbolID) == [2])
                frames += 1
            }
        }
    }

    @Test func malformedTextGetsErrorNotDisconnect() async throws {
        try await withFeedServer { _, client, _ in
            let bad = [
                "not json", #"{"symbols":["PTT"]}"#, #"{"op":"dance"}"#, #"{"op":"ping","clientNs":"soon"}"#,
                #"{"op":"subscribe","symbols":"PTT"}"#, #"{"op":"resync"}"#, "[]",
            ]
            for text in bad {
                try await client.send(text)
                let reply = try await client.nextText()
                #expect(errorMessage(reply) != nil, "\(text) was answered \(reply)")
            }
            try await client.send(binary: Data([1, 2, 3]))  // ignored

            try await client.send(#"{"op":"subscribe","symbols":["PTT","NOPE","ALSO"]}"#)
            let unknown = try await client.nextText()
            let message = try #require(errorMessage(unknown))
            #expect(message.contains("NOPE") && message.contains("ALSO") && !message.contains("PTT"))
            _ = try await client.nextFrame { $0.updates.contains { $0.symbolID == 1 } }

            try await client.send(#"{"op":"ping","clientNs":7}"#)
            let pong = try await client.nextText()
            #expect(pong["op"] as? String == "pong")
            #expect(int64(pong, "clientNs") == 7)
        }
    }

    /// The pongs and the frames share one socket: every reply arrives whole and in order while the frames of a
    /// stressed market flow.
    @Test func pingsAreAnsweredIntactAndInOrderWhileFramesFlow() async throws {
        try await withFeedServer { app, client, _ in
            await app.lab.apply(LabPatch(stress: true))
            try await client.send(#"{"op":"subscribe","symbols":\#(allTickers)}"#)
            _ = try await client.nextFrame { !$0.updates.isEmpty }

            let count = 200
            for clientNs in 1...count { try await client.send(#"{"op":"ping","clientNs":\#(clientNs)}"#) }
            var echoed: [Int64] = []
            var frames = 0
            while echoed.count < count {
                switch try await client.next() {
                case .frame: frames += 1
                case .text(let reply):
                    #expect(reply["op"] as? String == "pong")
                    echoed.append(int64(reply, "clientNs") ?? -1)
                }
            }
            #expect(echoed == (1...Int64(count)).map { $0 })
            #expect(frames > 0)
        }
    }

    @Test func dropConnectionsClosesTheFeed() async throws {
        try await withFeedServer { _, client, ports in
            try await client.send(#"{"op":"subscribe","symbols":["PTT"]}"#)
            _ = try await client.nextFrame { !$0.updates.isEmpty }

            let rest = RestClient(host: ServerConfig().host, port: ports.rest)
            let dropped = try await rest.post("/v1/admin/drop-connections")
            #expect(dropped.status == 204)
            let closed = await finishes(within: patience) {
                while (try? await client.next()) != nil {}
            }
            #expect(closed, "the feed stayed open after drop-connections")

            // The feed takes new connections afterwards.
            let again = try FeedClient(host: ServerConfig().host, port: ports.rest)
            defer { again.close() }
            try await again.send(#"{"op":"ping","clientNs":1}"#)
            let pong = try await again.nextText()
            #expect(pong["op"] as? String == "pong")
        }
    }

    /// The service group waits for every handler however long it takes, so an open feed must end on a graceful
    /// shutdown.
    @Test func aGracefulShutdownCompletesWhileAFeedClientIsConnected() async throws {
        let server = try await startServer()
        let client = try FeedClient(host: server.host, port: server.ports.rest)
        defer { client.close() }
        try await client.send(#"{"op":"subscribe","symbols":["PTT"]}"#)
        _ = try await client.nextFrame { !$0.updates.isEmpty }

        let stopped = await server.shutDown(within: patience)
        #expect(stopped, "run() did not return with a feed client connected")
    }

    /// With a clock that stands still the market never moves and the runner publishes nothing, so the states a first
    /// subscriber gets can only come from what the server published when it started.
    @Test func theFirstSubscriberGetsEveryStateBeforeTheMarketMoves() async throws {
        let stamp: Int64 = 1_732_000_000_000_000_000
        try await withRunningServer(nowNs: { stamp }) { app, ports in
            let client = try FeedClient(host: ServerConfig().host, port: ports.rest)
            defer { client.close() }
            try await client.send(#"{"op":"subscribe","symbols":\#(allTickers)}"#)
            let frame = try await client.nextFrame { !$0.updates.isEmpty }
            let quotes = await app.engine.quotes()
            #expect(frame.updates == quotes.map { MarketFrameMapping.update($0, seq: 1) })
            #expect(frame.serverSendNs == stamp)
        }
    }
}

/// The one point every write of a socket goes through.
@Suite("SerialWriterTests")
struct SerialWriterTests {
    /// Writes in flight at once, the most there ever were, and what was written.
    final class Overlap: Sendable {
        private let state = Mutex((now: 0, most: 0, written: [Int]()))

        func begin() {
            state.withLock { state in
                state.now += 1
                state.most = max(state.most, state.now)
            }
        }

        func end(_ value: Int) {
            state.withLock { state in
                state.now -= 1
                state.written.append(value)
            }
        }

        var most: Int { state.withLock { $0.most } }
        var written: [Int] { state.withLock { $0.written } }
    }

    private struct Refused: Error {}

    /// Fifty tasks write at once through one writer: no two writes overlap, every write happens, and a write that
    /// fails fails only its own caller.
    @Test func writesFromManyTasksNeverOverlap() async throws {
        let overlap = Overlap()
        let writer = SerialWriter<Int> { value in
            overlap.begin()
            try? await Task.sleep(for: .milliseconds(1))
            overlap.end(value)
            if value == 13 { throw Refused() }
        }
        let failures = Counter()
        await withTaskGroup { group in
            for value in 0..<50 {
                group.addTask {
                    do { try await writer.write(value) } catch { failures.increment() }
                }
            }
        }
        #expect(overlap.most == 1)
        #expect(overlap.written.sorted() == Array(0..<50))
        #expect(failures.value == 1)
    }
}

/// A session's two writers, the hub's flusher and the replies to the client's messages, share one serialisation point.
@Suite("MarketFeedSessionTests")
struct MarketFeedSessionTests {
    private static let binary = 0
    private static let text = 1

    @Test func framesAndRepliesAreWrittenOneAtATime() async throws {
        let overlap = SerialWriterTests.Overlap()
        let hub = makeHub()
        let session = MarketFeedSession(hub: hub, nowNs: WallClock.nowNs) { frame in
            overlap.begin()
            try? await Task.sleep(for: .milliseconds(1))
            if case .text = frame { overlap.end(Self.text) } else { overlap.end(Self.binary) }
        }
        let id = await session.register(close: {})
        try await session.receive(.text(#"{"op":"subscribe","symbols":\#(allTickers)}"#), connection: id)
        try await session.receive(.binary(ByteBuffer(bytes: [1, 2, 3])), connection: id)  // ignored

        try await withThrowingTaskGroup { group in
            group.addTask {
                for round in 1...300 {
                    await hub.publish(allQuotes(offset: Int64(round)))
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            for clientNs in 1...100 {
                try await session.receive(.text(#"{"op":"ping","clientNs":\#(clientNs)}"#), connection: id)
            }
            try await group.waitForAll()
        }
        await hub.unregister(id)

        let written = overlap.written
        #expect(overlap.most == 1)
        #expect(written.filter { $0 == Self.text }.count == 100)
        #expect(written.contains(Self.binary))
    }
}

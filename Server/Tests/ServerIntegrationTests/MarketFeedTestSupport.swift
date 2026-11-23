import Contracts
import ExchangeCore
import Foundation
import Synchronization
import Testing
import TradeCore
@testable import ExchangeServerKit

// Shared helpers for the market feed tests: a fake connection for the hub, quotes to publish, and a WebSocket client
// for the route.

/// A frame a fake connection was handed, with when: `receivedNs` from the clock the hub was given, `at` from the
/// monotonic clock.
struct ReceivedFrame: Sendable {
    let frame: Tp_MarketFrame
    let receivedNs: Int64
    let at: ContinuousClock.Instant
}

/// The two closures a connection registers with the hub, recording every frame it is sent and every close.
///
/// With `holdsFirstSend`, the first `send` records its frame and then stays suspended until the test calls
/// `releaseFirstSend()`, like a socket that is not draining; it does not notice that its caller was cancelled.
/// `failSends` makes every `send` throw after recording.
final class FakeConnection: Sendable {
    private struct State {
        var frames: [ReceivedFrame] = []
        var closes = 0
    }

    private let state = Mutex(State())
    private let nowNs: @Sendable () -> Int64
    private let holdsFirstSend: Bool
    private let failSends: Bool
    private let gate: AsyncStream<Void>
    private let opener: AsyncStream<Void>.Continuation

    struct SendFailed: Error {}

    init(nowNs: @escaping @Sendable () -> Int64 = WallClock.nowNs, holdsFirstSend: Bool = false, failSends: Bool = false) {
        self.nowNs = nowNs
        self.holdsFirstSend = holdsFirstSend
        self.failSends = failSends
        (gate, opener) = AsyncStream<Void>.makeStream()
    }

    func send(_ frame: Tp_MarketFrame) async throws {
        let received = ReceivedFrame(frame: frame, receivedNs: nowNs(), at: .now)
        let count = state.withLock { state in
            state.frames.append(received)
            return state.frames.count
        }
        if count == 1, holdsFirstSend {
            // An unstructured task, so that cancelling the caller does not end the wait.
            await Task { [gate] in for await _ in gate {} }.value
        }
        if failSends { throw SendFailed() }
    }

    /// Lets the held first `send` return.
    func releaseFirstSend() {
        opener.finish()
    }

    func close() async {
        state.withLock { $0.closes += 1 }
    }

    var frames: [ReceivedFrame] { state.withLock { $0.frames } }
    var closeCount: Int { state.withLock { $0.closes } }

    /// Every update received so far, in order of arrival.
    var updates: [Tp_SymbolUpdate] { frames.flatMap(\.frame.updates) }

    /// Registers this connection with `hub`.
    func register(with hub: MarketHub) async -> ConnectionID {
        await hub.register(send: { try await self.send($0) }, close: { await self.close() })
    }

    /// Whether at least `count` frames arrive within `limit`.
    func waitForFrames(_ count: Int, within limit: Duration = patience) async -> Bool {
        await eventually(within: limit) { self.frames.count >= count }
    }

    /// Waits for at least `count` frames and records an issue if they do not arrive within `patience`.
    func expectFrames(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        let arrived = await waitForFrames(count)
        #expect(arrived, "\(frames.count) of \(count) frames arrived", sourceLocation: sourceLocation)
    }
}

/// A quote of `symbolId` whose every price is derived from `last`, so that two quotes with different `last` differ in
/// every field the wire carries.
func makeQuote(_ symbolId: UInt32, last: Int64, eventNs: Int64 = 1_732_000_000_000_000_000) -> SymbolQuote {
    func candle(_ openTimeMs: Int64, _ base: Int64) -> Candle {
        Candle(
            openTimeMs: openTimeMs, open: Price(satang: base - 3), high: Price(satang: base + 5),
            low: Price(satang: base - 7), close: Price(satang: base), volume: base * 100
        )
    }
    return SymbolQuote(
        symbolId: symbolId, last: Price(satang: last), bid: Price(satang: last - 25), ask: Price(satang: last + 25),
        bidQty: 1_000 + Int64(symbolId), askQty: 2_000 + Int64(symbolId), dayVolume: 50_000 + last,
        candle1s: candle(1_732_000_000_000, last), candle1m: candle(1_731_999_960_000, last + 1),
        candle5m: candle(1_731_999_700_000, last + 2), eventNs: eventNs
    )
}

/// One quote of each of the twelve default symbols, every `last` offset by `offset`.
func allQuotes(offset: Int64) -> [SymbolQuote] {
    SymbolCatalog.defaultSymbols.map { makeQuote($0.id, last: 1_000 * Int64($0.id) + offset) }
}

/// Every default ticker, in catalog order.
let allTickers = SymbolCatalog.defaultSymbols.map(\.ticker)

/// A hub over the default symbols that reads the wall clock and sends no heartbeat within any test's patience, so
/// that a frame a test waits for can only have been sent because something asked for it. The heartbeat tests use the
/// public initialiser, with its one-second heartbeat.
func makeHub(lab: LabControls = LabControls()) -> MarketHub {
    MarketHub(symbols: SymbolCatalog.defaultSymbols, lab: lab, nowNs: WallClock.nowNs, idleTimeout: .seconds(3_600))
}

// MARK: WebSocket client

/// A message the market feed sent: a binary frame or a JSON text.
enum FeedMessage {
    case frame(Tp_MarketFrame)
    case text([String: Any])
}

enum FeedClientError: Error {
    case badURL
    case notJSON(String)
    case timedOut
}

/// A real `URLSessionWebSocketTask` on `/ws/market`.
final class FeedClient: Sendable {
    private let task: URLSessionWebSocketTask

    init(host: String, port: Int) throws {
        guard let url = URL(string: "ws://\(host):\(port)/ws/market") else { throw FeedClientError.badURL }
        task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
        task.resume()
    }

    /// Sends a text message.
    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    /// Sends a binary message.
    func send(binary: Data) async throws {
        try await task.send(.data(binary))
    }

    /// The next message, decoded.
    func next() async throws -> FeedMessage {
        switch try await task.receive() {
        case .data(let data):
            return .frame(try Tp_MarketFrame(serializedBytes: data))
        case .string(let text):
            guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw FeedClientError.notJSON(text)
            }
            return .text(object)
        @unknown default:
            throw FeedClientError.notJSON("unknown message")
        }
    }

    /// The next text message, skipping the frames before it. Throws `FeedClientError.timedOut` if none has come
    /// within `limit`; the feed's heartbeat arrives at least every second, so the deadline is checked often enough.
    func nextText(within limit: Duration = patience) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if case .text(let object) = try await next() { return object }
        }
        throw FeedClientError.timedOut
    }

    /// The next frame that satisfies `accept`, skipping texts and other frames. Throws `FeedClientError.timedOut` if
    /// none has come within `limit`.
    func nextFrame(
        within limit: Duration = patience, where accept: (Tp_MarketFrame) -> Bool = { _ in true }
    ) async throws -> Tp_MarketFrame {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if case .frame(let frame) = try await next(), accept(frame) { return frame }
        }
        throw FeedClientError.timedOut
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Starts a server, hands `body` the app and a feed client connected to it, then closes the client and stops the
/// server.
func withFeedServer(_ body: (ExchangeServerApp, FeedClient, BoundPorts) async throws -> Void) async throws {
    try await withRunningServer { app, ports in
        let client = try FeedClient(host: ServerConfig().host, port: ports.rest)
        defer { client.close() }
        try await body(app, client, ports)
    }
}

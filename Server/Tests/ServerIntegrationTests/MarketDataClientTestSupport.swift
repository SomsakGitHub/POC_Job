import Contracts
import Darwin
import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import ServiceLifecycleTestKit
import Synchronization
import Testing
import TradeCore
import TradeNetworking
@testable import ExchangeServerKit

// Helpers for the tests that run the client library's market-data client against a real server: a client wired to
// a server on ephemeral ports, a log of its connection states, a log of every update it applied, and a listener that
// accepts connections and never answers.

/// How long a market-client test waits for something that should happen at once. Far longer than anything takes on
/// an idle machine: it only turns a client that never gets there into a failure instead of a hang.
let clientPatience: Duration = .seconds(10)

/// Every state a client's `connection` stream yielded, with the moment it arrived, read by a task of its own until
/// the stream finishes (which `stop()` makes it do).
final class StateLog: Sendable {
    private final class Entries: Sendable {
        let list = Mutex<[(state: ConnectionState, at: ContinuousClock.Instant)]>([])
    }

    private let entries = Entries()
    private let reader: Task<Void, Never>

    init(_ stream: AsyncStream<ConnectionState>) {
        let entries = entries
        reader = Task {
            for await state in stream {
                let now = ContinuousClock.now
                entries.list.withLock { $0.append((state, now)) }
            }
        }
    }

    /// Every state so far, in order.
    var states: [ConnectionState] {
        entries.list.withLock { $0.map(\.state) }
    }

    /// How many states have arrived so far: an index to look after with `wait(after:for:)`.
    var count: Int {
        entries.list.withLock { $0.count }
    }

    /// The moment the first state at or after index `start` that matches arrived, waiting up to `limit` for it; nil if
    /// none did.
    func wait(
        after start: Int = 0, within limit: Duration = clientPatience, for match: (ConnectionState) -> Bool
    ) async -> ContinuousClock.Instant? {
        var found: ContinuousClock.Instant?
        _ = await eventually(within: limit, every: .milliseconds(5)) {
            found = entries.list.withLock { $0.dropFirst(start).first { match($0.state) }?.at }
            return found != nil
        }
        return found
    }

    /// Waits until the stream has finished: the client has been stopped.
    func finished() async {
        await reader.value
    }
}

/// Every update of one symbol the client applied, in order, as the snapshot it left behind.
///
/// It is the clock of the client's `MarketState`, which reads it once for every frame that applied an update, right
/// after applying it, and it reads the symbol's snapshot from the state then. With one symbol subscribed, one frame
/// carries at most one update of it, so the log has an entry for every update the client applied.
final class AppliedLog: Sendable {
    let symbolId: UInt32
    private let state = Mutex<MarketState?>(nil)
    private let entries = Mutex<[SymbolSnapshot]>([])

    init(symbolId: UInt32) {
        self.symbolId = symbolId
    }

    /// The state to read the snapshots from.
    func attach(_ market: MarketState) {
        state.withLock { $0 = market }
    }

    /// The clock reading: logs the symbol's snapshot and answers the wall clock.
    func now() -> Int64 {
        if let snapshot = state.withLock({ $0 })?.snapshot(symbolId) {
            entries.withLock { $0.append(snapshot) }
        }
        return WallClock.nowNs()
    }

    /// The snapshots so far.
    var snapshots: [SymbolSnapshot] {
        entries.withLock { $0 }
    }
}

/// A client of a running server and what a test reads from it.
struct FeedClientRig: Sendable {
    let client: WebSocketMarketDataClient
    let state: MarketState
    let log: StateLog
    let rest: URLSessionRestClient
    let symbols: [SymbolDTO]

    var tickers: [String] { symbols.map(\.ticker) }

    /// Whether every symbol has a snapshot whose frame arrived at or after `sinceNs` (wall clock).
    func allSymbolsUpdated(sinceNs: Int64 = 0) -> Bool {
        symbols.allSatisfy { (state.snapshot($0.id)?.appliedAtNs ?? -1) >= sinceNs }
    }

    /// Changes the server's lab settings.
    func lab(_ patch: LabPatch) async throws {
        _ = try await rest.setLab(patch)
    }
}

/// Starts a server (whose clock is `serverNowNs`, if given) and a market client for it with `watchdog`, hands both to
/// `body`, and afterwards stops the client, waits for its state stream to finish and invalidates the URL session the
/// client and the REST client shared. The client is not started: `body` starts it. With `applied`, the client's state
/// reads its clock from it.
func withFeedClient(
    watchdog: Duration = .seconds(5), serverNowNs: (@Sendable () -> Int64)? = nil, applied: AppliedLog? = nil,
    _ body: (ExchangeServerApp, FeedClientRig) async throws -> Void
) async throws {
    try await withRunningServer(nowNs: serverNowNs) { app, ports in
        let config = ClientConfig(host: ServerConfig.ephemeral.host, restPort: ports.rest, grpcPort: ports.grpc)
        let session = URLSession(configuration: .ephemeral)
        let rest = URLSessionRestClient(config: config, session: session)
        let state = applied.map { log in MarketState(latency: LatencyRecorder(), nowNs: { log.now() }) }
            ?? MarketState(latency: LatencyRecorder())
        applied?.attach(state)
        do {
            let symbols = try await rest.symbols()
            let client = WebSocketMarketDataClient(
                config: config, symbols: symbols, state: state, latency: LatencyRecorder(), watchdog: watchdog,
                session: session
            )
            let rig = FeedClientRig(
                client: client, state: state, log: StateLog(client.connection), rest: rest, symbols: symbols
            )
            do {
                try await body(app, rig)
            } catch {
                await rig.client.stop()
                await rig.log.finished()
                throw error
            }
            await rig.client.stop()
            await rig.log.finished()
        } catch {
            session.invalidateAndCancel()
            throw error
        }
        session.invalidateAndCancel()
    }
}

/// A TCP port on the loopback address that accepts connections (the system completes the handshake from its backlog)
/// and never reads or answers: a server that has gone silent before it said anything.
final class SilentListener: Sendable {
    struct Failure: Error {}

    let port: Int
    private let descriptor: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure() }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(descriptor, address, length) == 0 && listen(descriptor, 16) == 0
                    && getsockname(descriptor, address, &length) == 0
            }
        }
        guard bound else {
            Darwin.close(descriptor)
            throw Failure()
        }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    /// Closes the listening socket, and with it the connections waiting in its backlog.
    func close() {
        Darwin.close(descriptor)
    }
}

/// A market client of `listener`, with its own URL session; `body` gets the client and its state log, and the client
/// is stopped, its stream drained and the session invalidated afterwards.
func withSilentFeedClient(
    watchdog: Duration, _ body: (WebSocketMarketDataClient, StateLog) async throws -> Void
) async throws {
    let listener = try SilentListener()
    defer { listener.close() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let client = WebSocketMarketDataClient(
        config: ClientConfig(host: "127.0.0.1", restPort: listener.port), symbols: [],
        state: MarketState(latency: LatencyRecorder()), latency: LatencyRecorder(), watchdog: watchdog,
        session: session
    )
    let log = StateLog(client.connection)
    do {
        try await body(client, log)
    } catch {
        await client.stop()
        await log.finished()
        throw error
    }
    await client.stop()
    await log.finished()
}

extension ConnectionState {
    /// Whether this is a `.reconnecting` of any attempt.
    var isReconnecting: Bool {
        if case .reconnecting = self { return true }
        return false
    }
}

/// A stand-in for the market feed that only answers pings, for a test that must control how long a pong takes:
/// the pongs of connection `n` (from 1) carry a server clock `offsetNs(n)` ahead of the wall clock and are sent
/// `delay(n)` after the ping arrived. It sends no frames.
struct PongOnlyFeed: Sendable {
    let offsetNs: @Sendable (Int) -> Int64
    let delay: @Sendable (Int) -> Duration

    /// Runs the feed on an ephemeral loopback port, hands `body` the port, and shuts the feed down gracefully after.
    func run(_ body: (Int) async throws -> Void) async throws {
        let connections = Counter()
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/ws/market") { [offsetNs, delay] inbound, outbound, _ in
            connections.increment()
            let connection = connections.value
            for try await message in inbound.messages(maxSize: 1 << 16) {
                guard case .text(let text) = message,
                    let ping = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                    ping["op"] as? String == "ping", let clientNs = (ping["clientNs"] as? NSNumber)?.int64Value
                else { continue }
                try await Task.sleep(for: delay(connection))
                let pong: [String: Any] = [
                    "op": "pong", "clientNs": clientNs, "serverNs": WallClock.nowNs() + offsetNs(connection),
                ]
                let json = try JSONSerialization.data(withJSONObject: pong)
                try await outbound.write(.text(String(decoding: json, as: UTF8.self)))
            }
        }
        var logger = Logger(label: "PongOnlyFeed")
        logger.logLevel = .critical
        let (ports, portSink) = AsyncStream<Int>.makeStream()
        let app = Application(
            router: router, server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in portSink.yield(channel.localAddress?.port ?? 0) },
            logger: logger
        )
        try await testGracefulShutdown { trigger in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await app.run() }
                var iterator = ports.makeAsyncIterator()
                let port = await iterator.next() ?? 0
                do {
                    try await body(port)
                } catch {
                    trigger.triggerGracefulShutdown()
                    throw error
                }
                trigger.triggerGracefulShutdown()
                try await group.waitForAll()
            }
        }
    }
}

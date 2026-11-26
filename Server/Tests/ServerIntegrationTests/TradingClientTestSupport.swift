import Contracts
import ExchangeCore
import Foundation
import Synchronization
import Testing
import TradeCore
import TradeNetworking
@testable import ExchangeServerKit

// Helpers for the tests that run the trading client and store against a real server: a store wired to a server on
// ephemeral ports, a client wrapper that records every event the store was handed, and order helpers.

/// A `TradingClient` that hands everything to `base` and records, in order, each event `base` delivered before the
/// store applies it.
final class RecordingTradingClient: TradingClient {
    let base: GRPCTradingClient
    private let seen = Mutex<[Tp_OrderEvent]>([])

    init(_ base: GRPCTradingClient) {
        self.base = base
    }

    /// Every event delivered so far, replays included.
    var events: [Tp_OrderEvent] { seen.withLock { $0 } }

    func submit(_ d: OrderDraft) async throws -> SubmitResult { try await base.submit(d) }
    func cancel(orderId: String) async throws -> Bool { try await base.cancel(orderId: orderId) }
    var connection: AsyncStream<ConnectionState> { base.connection }
    func nudge() { base.nudge() }
    func stop() async { await base.stop() }

    func startEventStream(
        resumeFrom: @escaping @Sendable () -> (seq: UInt64, epoch: String?),
        onEvent: @escaping @Sendable (Tp_OrderEvent) async -> Void,
        onOutOfRange: @escaping @Sendable () async -> Void
    ) {
        base.startEventStream(
            resumeFrom: resumeFrom,
            onEvent: { [self] event in
                seen.withLock { $0.append(event) }
                await onEvent(event)
            },
            onOutOfRange: onOutOfRange)
    }
}

/// Counts the waits a client makes between submit attempts, and waits them for real.
final class CountingSleep: Sendable {
    private let calls = Mutex<[Duration]>([])

    func sleep(_ duration: Duration) async throws {
        calls.withLock { $0.append(duration) }
        try await Task.sleep(for: duration)
    }

    var waits: [Duration] { calls.withLock { $0 } }
}

/// A resume point a test sets while the client reads it.
final class ResumeBox: Sendable {
    private let point = Mutex<(seq: UInt64, epoch: String?)>((0, nil))

    var value: (seq: UInt64, epoch: String?) { point.withLock { $0 } }

    func set(seq: UInt64, epoch: String) {
        point.withLock { $0 = (seq, epoch) }
    }
}

/// A store and its client against a running server, and what a test reads from them.
struct TradingRig: Sendable {
    let app: ExchangeServerApp
    let config: ClientConfig
    let client: RecordingTradingClient
    let rest: URLSessionRestClient
    let latency: LatencyRecorder
    let store: TradingStore
    let log: StateLog
    let sleeps: CountingSleep

    /// The store's state now.
    func state() async -> TradingState {
        await store.state
    }

    /// Whether the store has caught up with every event the engine logged, within `limit`.
    func caughtUp(within limit: Duration = patience) async -> Bool {
        await eventually(within: limit) {
            let engine = await app.engine.account()
            let state = await store.state
            return state.epoch == engine.epoch && state.lastEventSeq == engine.lastEventSeq
        }
    }

    /// Whether the client reaches `.connected` after the state at index `after`, within `clientPatience`.
    func connected(after index: Int = 0) async -> Bool {
        await log.wait(after: index) { $0 == .connected } != nil
    }
}

/// Starts a server with `config`, builds a store over a recording gRPC client and a REST client for it, hands them to
/// `body`, then stops the client and waits for its state stream to finish. The store is not started.
func withTradingStore(
    config: ServerConfig = .ephemeral, keepaliveInterval: Duration = .seconds(30),
    _ body: (TradingRig) async throws -> Void
) async throws {
    try await withRunningServer(config: config) { app, ports in
        let clientConfig = ClientConfig(host: config.host, restPort: ports.rest, grpcPort: ports.grpc)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let latency = LatencyRecorder()
        let sleeps = CountingSleep()
        let base = GRPCTradingClient(
            config: clientConfig, latency: latency, keepaliveInterval: keepaliveInterval,
            sleep: { try await sleeps.sleep($0) })
        let client = RecordingTradingClient(base)
        let rest = URLSessionRestClient(config: clientConfig, session: session)
        let store = await TradingStore(client: client, rest: rest, latency: latency)
        let rig = TradingRig(
            app: app, config: clientConfig, client: client, rest: rest, latency: latency, store: store,
            log: StateLog(client.connection), sleeps: sleeps)
        do {
            try await body(rig)
        } catch {
            await client.stop()
            await rig.log.finished()
            throw error
        }
        await client.stop()
        await rig.log.finished()
    }
}

/// A market order for `quantity` shares of PTT.
func marketDraft(_ id: String, _ side: Side = .buy, quantity: Quantity = 100) -> OrderDraft {
    OrderDraft(clientOrderId: id, symbolId: 1, side: side, type: .market, quantity: quantity)
}

/// A limit buy of 100 PTT at the bottom of the price band: the market is far above it, so it rests.
func restingDraft(_ id: String, engine: ExchangeEngine) async throws -> OrderDraft {
    let symbol = try #require(await engine.symbols().first { $0.id == 1 })
    let low = TickRules.band(reference: symbol.reference).lowerBound.satang
    let tick = TickRules.tickSize(at: Price(satang: low)).satang
    let price = (low + tick - 1) / tick * tick
    return OrderDraft(
        clientOrderId: id, symbolId: 1, side: .buy, type: .limit, quantity: 100, limitPrice: Price(satang: price))
}

extension TradingState {
    /// The row whose client order id is `id`.
    func row(_ id: String) -> OrderRow? {
        orders.first { $0.id == id }
    }

    /// Whether some row still waits for the server's answer.
    var hasUnanswered: Bool {
        orders.contains { $0.status == .pending || $0.status == .unknown }
    }
}

/// Whether a connection of `hub` holds a waiting quote for every one of `symbols` subscribed symbols in 10
/// consecutive samples 50 ms apart, within `limit`. A healthy connection takes its quotes with every frame, so its
/// count flickers; only a connection whose writes are blocked keeps them all, sample after sample.
func holdsStall(_ hub: MarketHub, symbols: Int, within limit: Duration = .seconds(10)) async -> Bool {
    let deadline = ContinuousClock.now + limit
    var streak = 0
    while ContinuousClock.now < deadline {
        streak = await hub.maxPendingCount() == symbols ? streak + 1 : 0
        if streak >= 10 { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// Whether the numbers are 1, 2, 3 ... with no gap and no repeat; false for none.
func isContiguousFromOne(_ numbers: [UInt64]) -> Bool {
    !numbers.isEmpty && numbers.enumerated().allSatisfy { $0.element == UInt64($0.offset + 1) }
}

/// Whether every number is greater than the one before it.
func isStrictlyIncreasing(_ numbers: [UInt64]) -> Bool {
    zip(numbers, numbers.dropFirst()).allSatisfy { $0 < $1 }
}

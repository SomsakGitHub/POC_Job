import ExchangeCore
import Foundation
import Synchronization
import Testing
import TradeCore
@testable import ExchangeServerKit

// Shared helpers for the tests that run the whole server: start it on ephemeral ports, stop it, and bound every wait.

/// How long a test waits for something before it calls it hung. A test that passes never waits this long; the limit is
/// generous because a test run keeps every thread busy for seconds at a time, and an answer that comes late is not a
/// wrong one. It exists so that a hung server fails a test instead of hanging the run.
let patience: Duration = .seconds(30)

/// A count that one task raises while the test reads it.
final class Counter: Sendable {
    private let count = Mutex(0)

    func increment() {
        count.withLock { $0 += 1 }
    }

    var value: Int {
        count.withLock { $0 }
    }
}

/// Whether `operation` finishes within `limit`. A hung operation is abandoned, not awaited.
func finishes(within limit: Duration, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    let (outcome, sink) = AsyncStream<Bool>.makeStream()
    let work = Task {
        await operation()
        sink.yield(true)
    }
    let timer = Task {
        try? await Task.sleep(for: limit)
        sink.yield(false)
    }
    defer {
        work.cancel()
        timer.cancel()
    }
    for await finished in outcome { return finished }
    return false
}

/// Whether `condition` becomes true within `limit`, polled every `interval`; it is checked once more at the limit.
func eventually(
    within limit: Duration = patience, every interval: Duration = .milliseconds(10),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}

struct ServerStartTimeout: Error {}

extension ServerConfig {
    /// The default configuration with both servers on ephemeral ports.
    static var ephemeral: ServerConfig {
        var config = ServerConfig()
        config.restPort = 0
        config.grpcPort = 0
        return config
    }
}

/// A server a test started: the app, the ports it bound and the task that runs it.
struct RunningServer: Sendable {
    let app: ExchangeServerApp
    let ports: BoundPorts
    let host: String
    fileprivate let task: Task<Void, any Error>

    /// Cancels `run()`, which the app turns into a graceful shutdown, and reports whether the server had stopped
    /// within `limit`. A server that has not is abandoned.
    func shutDown(within limit: Duration) async -> Bool {
        task.cancel()
        return await finishes(within: limit) { _ = await task.result }
    }
}

/// Lets at most `width` holders in at once; the others wait, in the order they came, for a permit to be released.
final class Gate: Sendable {
    private struct State {
        var running = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let width: Int
    private let state = Mutex(State())

    init(width: Int) {
        self.width = width
    }

    /// Returns once the caller holds a permit; each call must be matched by one `release()`.
    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let admitted = state.withLock { state in
                guard state.running < width else {
                    state.waiting.append(continuation)
                    return false
                }
                state.running += 1
                return true
            }
            if admitted { continuation.resume() }
        }
    }

    /// Hands the permit to the longest waiter, or gives it back when nobody waits.
    func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiting.isEmpty else {
                state.running -= 1
                return nil
            }
            return state.waiting.removeFirst()
        }
        next?.resume()
    }
}

/// Building a server builds its whole simulated market, a few hundred milliseconds of work that does not yield. Run
/// unchecked, dozens of tests start one at the same moment and every thread of the pool is busy for seconds, so that a
/// test which only waits for something is starved past its bound. This gate lets a few constructions run at once.
let serverConstructionGate = Gate(width: max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 2)))

/// Starts a server on ephemeral ports (or the ports `config` names) and returns once it is listening on both.
/// Fails, instead of hanging, if `run()` fails or the server is not listening within `startTimeout`. `nowNs` replaces
/// the wall clock the app reads, for a test that has to know exactly what the clock said.
func startServer(
    config: ServerConfig = .ephemeral, nowNs: (@Sendable () -> Int64)? = nil, startTimeout: Duration = patience
) async throws -> RunningServer {
    await serverConstructionGate.acquire()
    let app: ExchangeServerApp
    do {
        defer { serverConstructionGate.release() }
        app = nowNs.map { ExchangeServerApp(config: config, nowNs: $0) } ?? ExchangeServerApp(config: config)
    }

    // First of: the server reports its ports, `run()` fails, or the timeout fires.
    let (started, startup) = AsyncThrowingStream<BoundPorts, any Error>.makeStream()
    let server = Task {
        do {
            try await app.run()
        } catch {
            startup.finish(throwing: error)
            throw error
        }
    }
    let waiter = Task { startup.yield(await app.waitUntilListening()) }
    let timer = Task {
        try await Task.sleep(for: startTimeout)
        startup.finish(throwing: ServerStartTimeout())
    }
    defer {
        waiter.cancel()
        timer.cancel()
    }
    do {
        var iterator = started.makeAsyncIterator()
        guard let ports = try await iterator.next() else { throw ServerStartTimeout() }
        guard ports.rest != 0, ports.grpc != 0 else {
            try await server.value  // run() ended before listening: surface its error
            throw ServerStartTimeout()
        }
        return RunningServer(app: app, ports: ports, host: config.host, task: server)
    } catch {
        server.cancel()
        throw error
    }
}

struct ServerShutdownTimeout: Error {}

/// Starts a server, runs `body` against it, then shuts it down. Fails if the shutdown does not finish within
/// `shutdownTimeout`: a server that cannot stop would hang the process it runs in.
func withRunningServer(
    config: ServerConfig = .ephemeral, nowNs: (@Sendable () -> Int64)? = nil, startTimeout: Duration = patience,
    shutdownTimeout: Duration = patience, _ body: (ExchangeServerApp, BoundPorts) async throws -> Void
) async throws {
    let server = try await startServer(config: config, nowNs: nowNs, startTimeout: startTimeout)
    do {
        try await body(server.app, server.ports)
    } catch {
        _ = await server.shutDown(within: shutdownTimeout)
        throw error
    }
    guard await server.shutDown(within: shutdownTimeout) else { throw ServerShutdownTimeout() }
}

// MARK: REST

/// What a REST call answered.
struct RestResponse {
    let status: Int
    let body: Data
    private let http: HTTPURLResponse

    init(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RestClientError.notHTTP }
        self.http = http
        status = http.statusCode
        body = data
    }

    /// A header of the answer; the name is not case-sensitive.
    func header(_ name: String) -> String? {
        http.value(forHTTPHeaderField: name)
    }

    func decode<Value: Decodable>(_ type: Value.Type = Value.self) throws -> Value {
        try JSONDecoder().decode(type, from: body)
    }

    var text: String {
        String(decoding: body, as: UTF8.self)
    }
}

enum RestClientError: Error {
    case notHTTP
    case badTarget(String)
}

/// A REST client for the tests: a real `URLSession` that keeps no cache and never revalidates by itself, so every
/// answer, a 304 included, is the server's own.
struct RestClient: Sendable {
    private let host: String
    private let port: Int
    private let session: URLSession

    init(host: String, port: Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Double(patience.components.seconds)
        self.host = host
        self.port = port
        session = URLSession(configuration: configuration)
    }

    /// `target` is the path and query, already percent-encoded: `/v1/candles?symbol=PTT&interval=1m`.
    func get(_ target: String, headers: [String: String] = [:]) async throws -> RestResponse {
        try await send(method: "GET", target, headers: headers, body: nil)
    }

    /// A POST with a JSON `body`, or none.
    func post(_ target: String, json body: String? = nil) async throws -> RestResponse {
        let headers = body == nil ? [:] : ["Content-Type": "application/json"]
        return try await send(method: "POST", target, headers: headers, body: body.map { Data($0.utf8) })
    }

    private func send(
        method: String, _ target: String, headers: [String: String], body: Data?
    ) async throws -> RestResponse {
        guard let url = URL(string: "http://\(host):\(port)\(target)") else { throw RestClientError.badTarget(target) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        return try RestResponse(data: data, response: response)
    }
}

/// Starts a server, hands `body` the app and a REST client for it, then shuts the server down.
func withRestServer(
    config: ServerConfig = .ephemeral, nowNs: (@Sendable () -> Int64)? = nil,
    _ body: (ExchangeServerApp, RestClient) async throws -> Void
) async throws {
    try await withRunningServer(config: config, nowNs: nowNs) { app, ports in
        try await body(app, RestClient(host: config.host, port: ports.rest))
    }
}

/// `{"status":"ok","epoch":"…"}` as `GET /healthz` answers it.
struct HealthBody: Decodable {
    let status: String
    let epoch: String
}

/// `{"serverNs":N}` as `GET /v1/time` answers it.
struct TimeBody: Decodable {
    let serverNs: Int64
}

/// `{"epoch":"…"}` as `POST /v1/admin/reset` answers it.
struct EpochBody: Decodable {
    let epoch: String
}

/// `{"error":"…"}`, the body of every 4xx the routes produce.
struct ErrorBody: Decodable {
    let error: String
}

// MARK: Orders

/// Submits a market order for `quantity` shares of `symbol` (PTT unless told otherwise) and returns the id it was
/// accepted under. The test fails if the engine rejects it.
@discardableResult
func submitMarket(
    _ engine: ExchangeEngine, _ clientOrderId: String, _ side: Side, quantity: Quantity = 100, symbol: UInt32 = 1
) async throws -> String {
    let request = OrderRequest(
        clientOrderId: clientOrderId, symbolId: symbol, side: side, type: .market, quantity: quantity, limitPrice: nil
    )
    let outcome = await engine.submit(request)
    guard case .accepted(let orderId, _) = outcome else {
        Issue.record("\(clientOrderId) was not accepted: \(outcome)")
        throw OrderNotAccepted()
    }
    return orderId
}

struct OrderNotAccepted: Error {}

/// Trades 100 shares of PTT, alternately buying and selling, until the ledger holds `count` entries. A market order
/// the book cannot fill at that moment makes no entry, so a round that adds none waits a moment (the market runner
/// refills the book) and tries again; the test fails if the entries do not come within `limit`.
func makeLedgerEntries(_ engine: ExchangeEngine, count: UInt64, within limit: Duration = patience) async throws {
    let deadline = ContinuousClock.now + limit
    var round = 0
    var holding = false
    while await engine.account().lastLedgerSeq < count {
        guard ContinuousClock.now < deadline else {
            let have = await engine.account().lastLedgerSeq
            Issue.record("only \(have) of \(count) ledger entries after \(limit)")
            throw OrderNotAccepted()
        }
        round += 1
        let before = await engine.account().lastLedgerSeq
        try await submitMarket(engine, "bulk-\(round)", holding ? .sell : .buy)
        if await engine.account().lastLedgerSeq > before {
            holding.toggle()
        } else {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

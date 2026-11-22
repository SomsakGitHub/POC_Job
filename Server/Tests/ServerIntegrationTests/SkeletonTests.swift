import ExchangeServerKit
import Testing
import TradeNetworking

@Suite("SkeletonTests")
struct SkeletonTests {
    @Test func restHealthz() async throws {
        try await withSkeletonServer { probe in
            let status = try await probe.rest()
            #expect(status == "ok")
        }
    }

    @Test func webSocketDeliversFrame() async throws {
        try await withSkeletonServer { probe in
            let last = try await probe.webSocketLast()
            #expect(last == 3425)
        }
    }

    @Test func grpcSubmitAccepted() async throws {
        try await withSkeletonServer { probe in
            let orderID = try await probe.grpcOrderId()
            #expect(orderID == "skeleton")
        }
    }
}

struct ServerStartTimeout: Error {}

/// Starts a server on ephemeral ports, runs `body` against it, then cancels the server.
/// Fails (instead of hanging) if the server is not listening within `startTimeout`.
private func withSkeletonServer(
    startTimeout: Duration = .seconds(10),
    _ body: (SkeletonProbe) async throws -> Void
) async throws {
    var config = ServerConfig()
    config.restPort = 0
    config.grpcPort = 0
    let app = ExchangeServerApp(config: config)

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
        server.cancel()
        waiter.cancel()
        timer.cancel()
    }
    var iterator = started.makeAsyncIterator()
    guard let ports = try await iterator.next() else { throw ServerStartTimeout() }
    timer.cancel()

    let probe = SkeletonProbe(host: config.host, restPort: ports.rest, grpcPort: ports.grpc)
    try await body(probe)
    server.cancel()
    _ = await server.result
}

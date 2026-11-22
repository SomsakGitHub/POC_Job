import Contracts
import ExchangeCore
import GRPCCore
import GRPCNIOTransportHTTP2
import Hummingbird
import HummingbirdWebSocket
import Logging
import ServiceLifecycle
import SwiftProtobuf
import Synchronization
import TradeCore

/// Ports the server actually bound (differs from `ServerConfig` when a port is `0`).
public struct BoundPorts: Sendable {
    public let rest: Int
    public let grpc: Int
}

/// The exchange server: REST + WebSocket (Hummingbird) and gRPC, run with the market runner as services of one
/// `ServiceGroup`.
///
/// The REST routes and the market runner are real. The market feed (one fixed frame on `/ws/market`) and `SubmitOrder`
/// (which always accepts, with order id "skeleton", and never reaches the engine) are still skeletons.
public final class ExchangeServerApp: Sendable {
    private let config: ServerConfig
    private let nowNs: @Sendable () -> Int64
    private let listening = Mutex(ListeningState())

    /// The exchange the server fronts: the simulated market, the demo account and the order events. The REST routes,
    /// the market runner and anything else that serves the exchange share this one engine.
    public let engine: ExchangeEngine
    /// The lab's settings, which the REST routes change and the market runner follows.
    public let lab: LabControls

    /// A server over the default symbols, with every clock reading taken from the wall clock.
    public convenience init(config: ServerConfig) {
        self.init(config: config, nowNs: WallClock.nowNs)
    }

    /// A server whose engine, routes and market runner all read `nowNs` (nanoseconds since the Unix epoch), so that a
    /// test can say exactly what the time is.
    init(config: ServerConfig, nowNs: @escaping @Sendable () -> Int64) {
        self.config = config
        self.nowNs = nowNs
        engine = ExchangeEngine(
            symbols: SymbolCatalog.defaultSymbols, seed: config.seed, nowNs: nowNs,
            eventLogCapacity: config.eventLogCapacity, commissionBps: config.commissionBps
        )
        lab = LabControls()
    }

    /// Runs both servers and the market runner until the calling task is cancelled or a server fails.
    public func run() async throws {
        // Release `waitUntilListening()` callers even if a server never came up.
        defer { record { $0.stopped = true } }
        let logger = Self.makeLogger()
        let grpc = GRPCServerService(
            host: config.host,
            port: config.grpcPort,
            services: [SkeletonOrderService()],
            onListening: { [self] port in self.record { $0.grpc = port } }
        )

        let rest = RestRoutes(engine: engine, lab: lab, nowNs: nowNs, dropConnections: { [engine] in
            await engine.dropStreams()
        })
        let router = Self.makeRouter(rest: rest)
        let http = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname(config.host, port: config.restPort)),
            onServerRunning: { [self] channel in
                if let port = channel.localAddress?.port { self.record { $0.rest = port } }
            },
            logger: logger
        )

        // The runner is last: a group shuts its services down in reverse order, so the market stops first.
        let runner = MarketRunner(engine: engine, lab: lab, nowNs: nowNs)
        let services = ServiceGroup(services: [http, grpc, runner], logger: logger)
        // The servers run in an unstructured task so that cancelling `run()` becomes a graceful
        // shutdown: cancelling Hummingbird directly drops connections and logs errors.
        let running = Task { try await services.run() }
        try await withTaskCancellationHandler {
            try await running.value
        } onCancel: {
            Task { await services.triggerGracefulShutdown() }
        }
    }

    /// Suspends until both servers are listening and returns the ports they bound.
    ///
    /// If `run()` ends before both servers are listening, returns at that point with `0` for each
    /// port that was never bound; `0` therefore means "not listening".
    public func waitUntilListening() async -> BoundPorts {
        await withCheckedContinuation { continuation in
            let ready: BoundPorts? = listening.withLock { state in
                if let ports = state.ports { return ports }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// Server logs at `.notice` and above by default (no per-start info lines); `LOG_LEVEL` overrides it.
    private static func makeLogger() -> Logger {
        var logger = Logger(label: "ExchangeServer")
        logger.logLevel = Environment().get("LOG_LEVEL").flatMap(Logger.Level.init(rawValue:)) ?? .notice
        return logger
    }

    /// Applies `update`; once both ports are known (or `run()` has ended), resumes every pending
    /// `waitUntilListening()`.
    private func record(_ update: (inout ListeningState) -> Void) {
        let ready: (BoundPorts, [CheckedContinuation<BoundPorts, Never>])? = listening.withLock { state in
            update(&state)
            guard let ports = state.ports else { return nil }
            let waiters = state.waiters
            state.waiters = []
            return (ports, waiters)
        }
        guard let (ports, waiters) = ready else { return }
        for waiter in waiters { waiter.resume(returning: ports) }
    }

    private static func makeRouter(rest: RestRoutes) -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)
        rest.add(to: router)
        router.ws("/ws/market") { inbound, outbound, _ in
            try await outbound.write(.binary(ByteBuffer(bytes: try skeletonFrame().serializedData())))
            for try await _ in inbound {}  // keep the socket open until the client closes it
        }
        return router
    }

    private static func skeletonFrame() -> Tp_MarketFrame {
        var update = Tp_SymbolUpdate()
        update.symbolID = 1
        update.last = 3425
        var frame = Tp_MarketFrame()
        frame.updates = [update]
        return frame
    }
}

private struct ListeningState {
    var rest: Int?
    var grpc: Int?
    /// `run()` has ended.
    var stopped = false
    var waiters: [CheckedContinuation<BoundPorts, Never>] = []

    /// The bound ports once both are known; after `run()` ends, any unknown port is reported as `0`.
    var ports: BoundPorts? {
        if let rest, let grpc { return BoundPorts(rest: rest, grpc: grpc) }
        return stopped ? BoundPorts(rest: rest ?? 0, grpc: grpc ?? 0) : nil
    }
}

/// Adapts `GRPCServer` to a `ServiceLifecycle.Service` and reports the port it bound.
struct GRPCServerService: Service {
    private let transport: HTTP2ServerTransport.Posix
    private let server: GRPCServer<HTTP2ServerTransport.Posix>
    private let onListening: @Sendable (Int) -> Void

    init(
        host: String, port: Int, services: [any RegistrableRPCService],
        onListening: @escaping @Sendable (Int) -> Void
    ) {
        transport = HTTP2ServerTransport.Posix(address: .ipv4(host: host, port: port), transportSecurity: .plaintext)
        server = GRPCServer(transport: transport, services: services)
        self.onListening = onListening
    }

    /// A graceful shutdown is passed on to the server only after `listeningAddress` has resolved.
    /// Shutting down a `GRPCServer` before `serve()` stops it without ever calling `transport.listen()`,
    /// and then `listeningAddress` (which ignores cancellation) never resolves. Because `serve()` is
    /// always allowed to reach `listen()`, the address resolves either way: with the bound address,
    /// or with an error once `listen()` exits.
    func run() async throws {
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { try await server.serve() }
            group.addTask {
                if let port = try? await transport.listeningAddress.ipv4?.port { onListening(port) }
                // Returns on graceful shutdown, or throws once the group is cancelled because serve() failed.
                try? await gracefulShutdown()
                server.beginGracefulShutdown()
            }
        }
    }
}

/// Skeleton `tp.OrderService`: accepts every order under the id "skeleton" without passing it to the engine.
private struct SkeletonOrderService: Tp_OrderService.SimpleServiceProtocol {
    func submitOrder(request: Tp_SubmitOrderRequest, context: ServerContext) async throws -> Tp_SubmitOrderResponse {
        var response = Tp_SubmitOrderResponse()
        response.accepted = true
        response.orderID = "skeleton"
        return response
    }

    func cancelOrder(request: Tp_CancelOrderRequest, context: ServerContext) async throws -> Tp_CancelOrderResponse {
        Tp_CancelOrderResponse()
    }

    func streamOrderEvents(
        request: Tp_StreamOrderEventsRequest,
        response: RPCWriter<Tp_OrderEvent>,
        context: ServerContext
    ) async throws {}
}

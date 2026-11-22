import Contracts
import GRPCCore
import GRPCNIOTransportHTTP2
import Hummingbird
import HummingbirdWebSocket
import ServiceLifecycle
import SwiftProtobuf
import Synchronization

/// Ports the server actually bound (differs from `ServerConfig` when a port is `0`).
public struct BoundPorts: Sendable {
    public let rest: Int
    public let grpc: Int
}

/// The exchange server: REST + WebSocket (Hummingbird) and gRPC, run as services of one `ServiceGroup`.
///
/// Skeleton behaviour (replaced in Tasks 11–13): `GET /healthz`, one fixed frame on `/ws/market`,
/// and a `SubmitOrder` that always accepts with order id "skeleton".
public final class ExchangeServerApp: Sendable {
    private let config: ServerConfig
    private let listening = Mutex(ListeningState())

    public init(config: ServerConfig) {
        self.config = config
    }

    /// Runs both servers until the calling task is cancelled or a server fails.
    public func run() async throws {
        let grpcTransport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: config.host, port: config.grpcPort),
            transportSecurity: .plaintext
        )
        let grpcServer = GRPCServer(transport: grpcTransport, services: [SkeletonOrderService()])

        let router = Self.makeRouter()
        let http = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname(config.host, port: config.restPort)),
            onServerRunning: { [self] channel in
                if let port = channel.localAddress?.port { self.record { $0.rest = port } }
            }
        )

        let services = ServiceGroup(services: [http, GRPCServerService(server: grpcServer)])
        // The servers run in an unstructured task so that cancelling `run()` becomes a graceful
        // shutdown: cancelling Hummingbird directly drops connections and logs errors.
        let running = Task {
            try await withThrowingDiscardingTaskGroup { group in
                group.addTask { try await services.run() }
                group.addTask {
                    let port = try await grpcTransport.listeningAddress.ipv4?.port
                    if let port { self.record { $0.grpc = port } }
                }
            }
        }
        try await withTaskCancellationHandler {
            try await running.value
        } onCancel: {
            Task { await services.triggerGracefulShutdown() }
        }
    }

    /// Suspends until both servers are listening and returns the ports they bound.
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

    /// Applies `update`; once both ports are known, resumes every pending `waitUntilListening()`.
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

    private static func makeRouter() -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.get("/healthz") { _, _ in HealthResponse(status: "ok") }
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
    var waiters: [CheckedContinuation<BoundPorts, Never>] = []

    var ports: BoundPorts? {
        guard let rest, let grpc else { return nil }
        return BoundPorts(rest: rest, grpc: grpc)
    }
}

private struct HealthResponse: ResponseEncodable {
    let status: String
}

/// Adapts `GRPCServer` to a `ServiceLifecycle.Service`.
private struct GRPCServerService: Service {
    let server: GRPCServer<HTTP2ServerTransport.Posix>

    func run() async throws {
        try await withGracefulShutdownHandler {
            try await server.serve()
        } onGracefulShutdown: {
            server.beginGracefulShutdown()
        }
    }
}

/// Skeleton `tp.OrderService`; replaced by the real implementation in Task 13.
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

import Contracts
import ExchangeCore
import GRPCCore
import GRPCNIOTransportHTTP2
import Testing
import TradeCore
@testable import ExchangeServerKit

// Helpers for the tests that talk to the order service over real HTTP/2 with the raw generated client.

typealias OrderClient = Tp_OrderService.Client<HTTP2ClientTransport.Posix>

/// Call options with a deadline of `patience`: a call the server never answers fails instead of hanging the test.
let boundedCall: CallOptions = {
    var options = CallOptions.defaults
    options.timeout = patience
    return options
}()

/// Connects a plaintext client to the gRPC port of `ports`, runs `body` with it and closes it.
func withOrderClient<Result: Sendable>(
    host: String = ServerConfig().host, _ ports: BoundPorts, _ body: (OrderClient) async throws -> Result
) async throws -> Result {
    let transport = try HTTP2ClientTransport.Posix(
        target: .ipv4(address: host, port: ports.grpc), transportSecurity: .plaintext
    )
    return try await withGRPCClient(transport: transport) { client in
        try await body(Tp_OrderService.Client(wrapping: client))
    }
}

/// Starts a server (with `config`), connects a client to it and runs `body` with both.
func withOrderServer(
    config: ServerConfig = .ephemeral, _ body: (ExchangeServerApp, OrderClient) async throws -> Void
) async throws {
    try await withRunningServer(config: config) { app, ports in
        try await withOrderClient(host: config.host, ports) { client in
            try await body(app, client)
        }
    }
}

/// A submit request with every field set; `limitPrice` 0 means "no price".
func submitRequest(
    _ clientOrderId: String, side: Tp_Side = .buy, type: Tp_OrderType = .market, quantity: Int64 = 100,
    symbol: UInt32 = 1, limitPrice: Int64 = 0
) -> Tp_SubmitOrderRequest {
    var request = Tp_SubmitOrderRequest()
    request.clientOrderID = clientOrderId
    request.symbolID = symbol
    request.side = side
    request.type = type
    request.quantity = quantity
    request.limitPrice = limitPrice
    return request
}

/// The RPC error `operation` threw, or nil (and a recorded issue) when it threw none or another kind of error.
func rpcError(_ operation: () async throws -> Void) async -> RPCError? {
    do {
        try await operation()
        Issue.record("the call succeeded; an RPC error was expected")
    } catch let error as RPCError {
        return error
    } catch {
        Issue.record("expected an RPC error, got \(error)")
    }
    return nil
}

/// Logs `count` rejected orders (one event each) straight through the engine: a quantity that is not a board lot.
func logRejectedOrders(_ engine: ExchangeEngine, count: Int, prefix: String = "reject") async {
    for index in 1...count {
        _ = await engine.submit(OrderRequest(
            clientOrderId: "\(prefix)-\(index)", symbolId: 1, side: .buy, type: .market, quantity: 150,
            limitPrice: nil
        ))
    }
}

// MARK: Event streams

/// How a `StreamOrderEvents` call ended.
enum StreamEnding: Equatable {
    /// The server ended the stream with status OK.
    case finished
    case failed(RPCError.Code, String)
}

/// What one open `StreamOrderEvents` call has received so far.
actor EventInbox {
    private(set) var events: [Tp_OrderEvent] = []
    private(set) var ending: StreamEnding?

    func receive(_ event: Tp_OrderEvent) {
        events.append(event)
    }

    func end(_ ending: StreamEnding) {
        self.ending = ending
    }
}

/// An open `StreamOrderEvents` call: a task reads it into `inbox` until the server ends it or the task is cancelled.
struct EventStreamCall: Sendable {
    let inbox: EventInbox
    private let task: Task<Void, Never>

    init(_ client: OrderClient, after seq: UInt64, epoch: String = "") {
        var request = Tp_StreamOrderEventsRequest()
        request.fromEventSeq = seq
        request.clientEpoch = epoch
        let inbox = EventInbox()
        self.inbox = inbox
        task = Task {
            do {
                try await client.streamOrderEvents(request, options: boundedCall) { response in
                    for try await event in response.messages { await inbox.receive(event) }
                }
                await inbox.end(.finished)
            } catch let error as RPCError {
                await inbox.end(.failed(error.code, error.message))
            } catch {
                await inbox.end(.failed(.unknown, "\(error)"))
            }
        }
    }

    /// The events received once there are at least `count`, or all there are when `patience` runs out first.
    func events(atLeast count: Int) async -> [Tp_OrderEvent] {
        _ = await eventually { await inbox.events.count >= count }
        return await inbox.events
    }

    /// How the call ended, or nil when it is still open after `patience`.
    func ending() async -> StreamEnding? {
        _ = await eventually { await inbox.ending != nil }
        return await inbox.ending
    }

    /// Cancels the call from the client side and waits (bounded) for the reading task to stop.
    func cancel() async -> Bool {
        task.cancel()
        return await finishes(within: patience) { [task] in await task.value }
    }
}

/// Opens a `StreamOrderEvents` call for `body` and cancels it afterwards, so that the client can close.
func withEventStream(
    _ client: OrderClient, after seq: UInt64, epoch: String = "", _ body: (EventStreamCall) async throws -> Void
) async throws {
    let call = EventStreamCall(client, after: seq, epoch: epoch)
    do {
        try await body(call)
    } catch {
        _ = await call.cancel()
        throw error
    }
    let stopped = await call.cancel()
    #expect(stopped, "the event stream call did not stop after it was cancelled")
}

extension Tp_OrderEvent {
    /// The name of the payload case, for comparing a sequence of events at a glance.
    var kind: String {
        switch event {
        case .accepted: "accepted"
        case .rejected: "rejected"
        case .fill: "fill"
        case .cancelled: "cancelled"
        case .ledgerEntry: "ledgerEntry"
        case nil: "none"
        }
    }
}

import Contracts
import GRPCCore
import TradeCore

/// What the server answered to one submit, and how long the answer took.
public struct SubmitResult: Sendable, Equatable {
    /// The server's id of the order; nil when it gave none (a refused order).
    public let orderId: String?
    /// Whether the server took the order.
    public let accepted: Bool
    /// Why the server refused the order; nil when it was accepted or when the reason is not one this build knows.
    public let rejectReason: RejectReason?
    /// When the server received the submit, on its clock, in nanoseconds since the Unix epoch; 0 when it did not say.
    public let serverRecvNs: Int64
    /// When the server answered the submit, on its clock; 0 when it did not say.
    public let serverAckNs: Int64
    /// The round trip of the attempt that was answered, on this device's monotonic clock: failed attempts and the
    /// waits between attempts are not part of it.
    public let clientRoundTripNs: Int64

    /// An answer with every field given (the client builds these; a test or a preview may too).
    public init(
        orderId: String?, accepted: Bool, rejectReason: RejectReason?, serverRecvNs: Int64, serverAckNs: Int64,
        clientRoundTripNs: Int64
    ) {
        self.orderId = orderId
        self.accepted = accepted
        self.rejectReason = rejectReason
        self.serverRecvNs = serverRecvNs
        self.serverAckNs = serverAckNs
        self.clientRoundTripNs = clientRoundTripNs
    }
}

/// The exchange's order service as the app uses it: submit and cancel orders, and follow the server's order events
/// over one supervised stream. A protocol so that the trading store can be run against a fake.
public protocol TradingClient: Sendable {
    /// Sends `d` and returns the server's answer. Up to 3 attempts with the same client order id, each with a 2 s
    /// deadline, when the connection is not there or the call runs out of time; any other error is thrown at once.
    /// Records `orderSubmitToAck` and `orderServerProcessing`.
    func submit(_ d: OrderDraft) async throws -> SubmitResult
    /// Asks the server to cancel the resting order `orderId`: one attempt with a 2 s deadline, no retry. True when
    /// the server cancelled it.
    func cancel(orderId: String) async throws -> Bool
    /// Starts following the order events, and keeps a stream open, reconnecting with backoff, until `stop()`.
    ///
    /// Every connection asks for the events after `resumeFrom()` (read anew each time) and hands each event to
    /// `onEvent`, one at a time and in order. When the server no longer keeps the events asked for, `onOutOfRange` is
    /// awaited and the stream is opened again from the resume point it leaves. A call while a stream is running is
    /// ignored; after `stop()` it starts again.
    func startEventStream(
        resumeFrom: @escaping @Sendable () -> (seq: UInt64, epoch: String?),
        onEvent: @escaping @Sendable (Tp_OrderEvent) async -> Void,
        onOutOfRange: @escaping @Sendable () async -> Void)
    /// A new stream of the connection's states on every access (see `ConnectionSupervisor.states`).
    var connection: AsyncStream<ConnectionState> { get }
    /// Replaces the connection now (one that has gone quiet, say, when the app comes back to the foreground).
    func nudge()
    /// Closes the connection and returns once nothing of it runs any more.
    func stop() async
}

/// A `TradingClient` over gRPC (plaintext HTTP/2) to the server `ClientConfig` names, kept up by a
/// `ConnectionSupervisor`.
///
/// One connection at a time, opened by the event stream and borrowed by `submit` and `cancel`, so the first order
/// pays no connection setup. Each connection pings the server after `keepaliveInterval` without traffic (also with
/// no call open) and is given up when a ping is not answered within 10 s. Every call carries
/// `authorization: Bearer <token>` when the config has a token that is not empty.
///
/// `stop()` is mandatory: a client that is dropped while its stream runs keeps its supervisor reconnecting for ever.
public final class GRPCTradingClient: TradingClient {
    private let link: OrderEventLink
    private let latency: LatencyRecorder
    private let metadata: Metadata
    private let sleep: @Sendable (Duration) async throws -> Void
    private let supervisor = ConnectionSupervisor(name: "order-events")

    /// A client of the server `config` names that records the order latencies into `latency`.
    ///
    /// `keepaliveInterval` is how long a connection may carry nothing before the client pings the server; the server
    /// refuses pings less than 5 s apart, so a shorter interval gets the connection closed. `sleep` is every wait
    /// between two attempts of a submit and must throw when its task is cancelled; a test passes one it can see.
    public init(
        config: ClientConfig, latency: LatencyRecorder, keepaliveInterval: Duration = .seconds(30),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        link = OrderEventLink(config: config, keepaliveInterval: keepaliveInterval)
        self.latency = latency
        metadata = TradingWire.metadata(token: config.authToken)
        self.sleep = sleep
    }

    /// Sends the draft (a market order without a price), at most 3 times with the same client order id: after an
    /// `unavailable` or `deadlineExceeded` it waits 250 ms, then 500 ms. With no stream started, or after `stop()`,
    /// nobody will open a connection, so the first such error is thrown at once. A cancelled task stops the retries.
    /// The answered attempt's round trip is recorded as `orderSubmitToAck`, and the server's own part, when it says,
    /// as `orderServerProcessing`.
    public func submit(_ d: OrderDraft) async throws -> SubmitResult {
        let request = TradingWire.submitRequest(d)
        let (link, metadata) = (link, metadata)
        let (response, roundTripNs) = try await withRetries(
            retriable: { TradingWire.isRetriable($0) && link.isLive }, sleep: sleep
        ) {
            try await link.withClient { client in
                let start = ContinuousClock.now
                let response = try await client.submitOrder(
                    request, metadata: metadata, options: TradingWire.unaryOptions)
                return (response, TradingWire.nanoseconds(start.duration(to: .now)))
            }
        }
        latency.record(.orderSubmitToAck, nanos: roundTripNs)
        if let processing = TradingWire.serverProcessingNs(response) {
            latency.record(.orderServerProcessing, nanos: processing)
        }
        return TradingWire.result(response, roundTripNs: roundTripNs)
    }

    /// One attempt; `unavailable` at once when no connection is up.
    public func cancel(orderId: String) async throws -> Bool {
        var request = Tp_CancelOrderRequest()
        request.orderID = orderId
        let metadata = metadata
        return try await link.withClient { client in
            try await client.cancelOrder(request, metadata: metadata, options: TradingWire.unaryOptions).cancelled
        }
    }

    /// Starts the supervised stream (see `TradingClient.startEventStream`). Each pass of the supervisor is one
    /// connection; it is `.connected` once the stream's response head has arrived.
    public func startEventStream(
        resumeFrom: @escaping @Sendable () -> (seq: UInt64, epoch: String?),
        onEvent: @escaping @Sendable (Tp_OrderEvent) async -> Void,
        onOutOfRange: @escaping @Sendable () async -> Void
    ) {
        link.isLive = true
        supervisor.start { [link] markConnected in
            try await link.run(
                markConnected: markConnected, resumeFrom: resumeFrom, onEvent: onEvent, onOutOfRange: onOutOfRange)
        }
    }

    /// A new stream of the supervisor's states on every access: `.connected` once a connection's event stream has
    /// its response head, `.reconnecting` after it ended, `.stopped` (and the end of the stream) after `stop()`.
    public var connection: AsyncStream<ConnectionState> {
        supervisor.states
    }

    /// Ends the current connection (or the wait before the next one) and connects again at once.
    public func nudge() {
        supervisor.nudge()
    }

    /// Ends the stream and its connection and returns once they are gone; from now on a submit that finds no
    /// connection fails at once. `startEventStream` afterwards starts again.
    public func stop() async {
        link.isLive = false
        await supervisor.stop()
    }
}

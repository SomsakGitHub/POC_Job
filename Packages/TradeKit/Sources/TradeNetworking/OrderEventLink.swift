import Contracts
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization

/// The connection of the order client: one HTTP/2 connection per pass of the supervised event stream, which the unary
/// calls borrow while it is up.
///
/// A pass builds its own transport and `GRPCClient`, publishes the client in `slot` before it opens the stream and
/// clears the slot on every way out, so a unary call only ever finds the client of a pass that is still running. When
/// the pass ends for any reason the whole connection goes with it, and the next pass builds a fresh one. The lock is
/// never held across an `await`.
final class OrderEventLink: Sendable {
    typealias Client = GRPCClient<HTTP2ClientTransport.Posix>

    private struct Slot {
        var client: Client?
        /// The pass that published `client`: a pass clears only its own client.
        var pass: UInt64 = 0
        var passes: UInt64 = 0
        /// Between `startEventStream` and `stop()`: someone will build a connection again after this one fails.
        var live = false
    }

    /// Thrown by a pass when the config names no address a connection can be made to.
    struct InvalidAddress: Error {}

    private let config: ClientConfig
    private let keepaliveInterval: Duration
    private let slot = Mutex(Slot())

    init(config: ClientConfig, keepaliveInterval: Duration) {
        self.config = config
        self.keepaliveInterval = keepaliveInterval
    }

    /// Whether a stream is meant to be running, so that a failed call is worth waiting for.
    var isLive: Bool {
        get { slot.withLock { $0.live } }
        set { slot.withLock { $0.live = newValue } }
    }

    /// Runs `call` on the connection of the running pass. With no connection up it throws `unavailable` at once; an
    /// error of a client that closed meanwhile is thrown as `unavailable` too (`TradingWire.normalized`).
    func withClient<Value: Sendable>(
        _ call: (Tp_OrderService.Client<HTTP2ClientTransport.Posix>) async throws -> Value
    ) async throws -> Value {
        guard let client = slot.withLock({ $0.client }) else {
            throw RPCError(code: .unavailable, message: "no connection to the order service")
        }
        do {
            return try await call(Tp_OrderService.Client(wrapping: client))
        } catch {
            throw TradingWire.normalized(error)
        }
    }

    /// One pass: a fresh connection, the event stream from the resume point read now, every event handed to
    /// `onEvent` in order (each awaited before the next is read), until the stream ends.
    ///
    /// The pass is `.connected` once the stream's response head has arrived: the server sends it as soon as its
    /// handler starts, before any event. A stream the server ends (a reset, a dropped connection, a shutdown) ends the
    /// pass normally; `outOfRange` (the events asked for are no longer kept) awaits `onOutOfRange` and then ends the
    /// pass normally, so the next pass reads the resume point it left; any other error is thrown to the supervisor.
    func run(
        markConnected: @Sendable () -> Void,
        resumeFrom: @Sendable () -> (seq: UInt64, epoch: String?),
        onEvent: @Sendable (Tp_OrderEvent) async -> Void,
        onOutOfRange: @Sendable () async -> Void
    ) async throws {
        guard let target = Self.target(config) else { throw InvalidAddress() }
        let transport = try HTTP2ClientTransport.Posix(
            target: target, transportSecurity: .plaintext,
            config: .defaults { config in
                config.connection.keepalive = .init(
                    time: keepaliveInterval, timeout: .seconds(10), allowWithoutCalls: true)
            }
        )
        let metadata = TradingWire.metadata(token: config.authToken)
        let pass = slot.withLock { slot in
            slot.passes += 1
            return slot.passes
        }
        // Also cleared here for a pass that throws before or after its client existed.
        defer { release(pass) }
        do {
            try await withGRPCClient(transport: transport) { client in
                slot.withLock { slot in
                    slot.client = client
                    slot.pass = pass
                }
                // Cleared before the client begins to close, so no call starts on a closing client.
                defer { release(pass) }
                let resume = resumeFrom()
                var request = Tp_StreamOrderEventsRequest()
                request.fromEventSeq = resume.seq
                request.clientEpoch = resume.epoch ?? ""
                try await withoutActuallyEscaping(markConnected) { markConnected in
                    try await withoutActuallyEscaping(onEvent) { onEvent in
                        try await Tp_OrderService.Client(wrapping: client).streamOrderEvents(
                            request, metadata: metadata, options: TradingWire.streamOptions
                        ) { response in
                            if case .success = response.accepted { markConnected() }
                            for try await event in response.messages {
                                await onEvent(event)
                            }
                        }
                    }
                }
            }
        } catch let error as RPCError where error.code == .outOfRange {
            await onOutOfRange()
        }
    }

    /// Empties the slot if it still holds the client of `pass`.
    private func release(_ pass: UInt64) {
        slot.withLock { slot in
            if slot.pass == pass { slot.client = nil }
        }
    }

    /// The target of the config's host and gRPC port, or nil when they make none: an empty host or a port outside
    /// 1...65535. An IPv6 address written in brackets, as in a URL, loses its brackets.
    static func target(_ config: ClientConfig) -> ResolvableTargets.DNS? {
        var host = Substring(config.host)
        if host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 {
            host = host.dropFirst().dropLast()
        }
        guard !host.isEmpty, (1...65535).contains(config.grpcPort) else { return nil }
        return .dns(host: String(host), port: config.grpcPort)
    }
}

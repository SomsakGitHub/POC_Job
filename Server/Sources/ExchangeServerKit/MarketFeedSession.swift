import Contracts
import Hummingbird
import HummingbirdWebSocket
import SwiftProtobuf

/// One client's conversation with the market feed: its frames out, its control messages in, and their replies out.
///
/// Every write, the hub's binary frames and the JSON replies alike, goes through the session's one `SerialWriter`,
/// because the hub's flusher and the socket's reading loop are two tasks and must never write to a WebSocket at once.
struct MarketFeedSession: Sendable {
    let hub: MarketHub
    let nowNs: @Sendable () -> Int64
    private let writer: SerialWriter<WebSocketOutboundWriter.OutboundFrame>

    /// A session that writes to the socket through `write`, one frame at a time.
    init(
        hub: MarketHub, nowNs: @escaping @Sendable () -> Int64,
        write: @escaping @Sendable (WebSocketOutboundWriter.OutboundFrame) async throws -> Void
    ) {
        self.hub = hub
        self.nowNs = nowNs
        writer = SerialWriter(write: write)
    }

    /// Registers the client with the hub, which then sends it each `Tp_MarketFrame` serialised as a binary message,
    /// and calls `close` once when it ends the connection.
    func register(close: @escaping @Sendable () async -> Void) async -> ConnectionID {
        await hub.register(
            send: { [writer] frame in try await writer.write(.binary(ByteBuffer(bytes: try frame.serializedData()))) },
            close: close
        )
    }

    /// Carries out a message from the client and writes the reply, if there is one. Binary messages are ignored.
    /// Throws only if the reply cannot be written.
    func receive(_ message: WebSocketMessage, connection id: ConnectionID) async throws {
        guard case .text(let text) = message else { return }
        if let reply = await handle(text, connection: id) {
            try await writer.write(.text(reply.json))
        }
    }

    /// Carries out one control message and returns the reply to send, if any. A message that cannot be understood is
    /// answered with an error and changes nothing: a client bug should not cost the client its feed.
    private func handle(_ text: String, connection id: ConnectionID) async -> MarketReply? {
        let control: MarketControl
        do {
            control = try MarketControl.decode(text)
        } catch {
            return .error(error.message)
        }
        switch control {
        case .subscribe(let tickers):
            let unknown = await hub.subscribe(id, tickers: tickers)
            return unknown.isEmpty ? nil : .error("unknown symbols: \(unknown.joined(separator: ", "))")
        case .unsubscribe(let tickers):
            await hub.unsubscribe(id, tickers: tickers)
            return nil
        case .ping(let clientNs):
            return .pong(clientNs: clientNs, serverNs: nowNs())
        case .resync(let ticker):
            let known = await hub.resync(id, ticker: ticker)
            return known ? nil : .error("unknown symbol: \(ticker)")
        }
    }
}

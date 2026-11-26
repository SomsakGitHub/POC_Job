import Hummingbird
import HummingbirdWebSocket
import ServiceLifecycle

/// The `/ws/market` route: one WebSocket per client, registered with the hub for as long as it is open.
///
/// The client sends JSON text control messages (`MarketControl`) and is answered in JSON text (`MarketReply`); the
/// hub's frames go out as binary messages, one serialised `Tp_MarketFrame` each. Binary messages from the client are
/// ignored. A message that cannot be understood is answered with an error and the socket stays open: a client bug
/// should not cost the client its feed.
///
/// What one socket says and hears is `MarketFeedSession`'s business; the route connects it to the socket and keeps it
/// open. The handler ends when the client closes, when the hub ends the connection (`drop-connections`, a failed
/// send) or when the server shuts down gracefully, and it always unregisters from the hub on the way out.
struct MarketWebSocket: Sendable {
    /// The largest text message a client may send; control messages are a few hundred bytes.
    static let maxMessageSize = 1 << 16

    let hub: MarketHub
    let nowNs: @Sendable () -> Int64

    /// Adds `/ws/market` to `router`.
    func add(to router: Router<BasicWebSocketRequestContext>) {
        router.ws("/ws/market") { inbound, outbound, _ in
            await serve(inbound: inbound, outbound: outbound)
        }
    }

    private func serve(inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async {
        let session = MarketFeedSession(hub: hub, nowNs: nowNs) { try await outbound.write($0) }
        let (closed, close) = AsyncStream<Void>.makeStream()
        let id = await session.register(close: { close.finish() })
        await cancelWhenGracefulShutdown {
            await withTaskGroup { group in
                group.addTask {
                    for await _ in closed {}  // until the hub ends the connection
                }
                group.addTask {
                    await readControls(inbound, session: session, connection: id)
                }
                // Whichever ends first ends the other.
                await group.next()
                group.cancelAll()
            }
        }
        await hub.unregister(id)
    }

    /// Hands the client's messages to the session until the client closes the socket or the task is cancelled.
    private func readControls(
        _ inbound: WebSocketInboundStream, session: MarketFeedSession, connection id: ConnectionID
    ) async {
        do {
            for try await message in inbound.messages(maxSize: Self.maxMessageSize) {
                try await session.receive(message, connection: id)
            }
        } catch {
            // The socket failed or closed: the connection is over either way.
        }
    }
}

/// Lets any number of tasks write through one writer while making sure that only one write is in progress at a time,
/// in the order the writers arrived.
///
/// An actor alone is not enough: it lets another call in while one is suspended inside the write. So a write that
/// finds the writer busy waits its turn, and a finishing write hands the turn straight to the next waiting one.
actor SerialWriter<Frame: Sendable> {
    private let perform: @Sendable (Frame) async throws -> Void
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// A writer that passes every frame to `write`, one at a time.
    init(write: @escaping @Sendable (Frame) async throws -> Void) {
        perform = write
    }

    /// Writes `frame` once every earlier write has finished, and throws what `write` threw.
    func write(_ frame: Frame) async throws {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiting.isEmpty {
                busy = false
            } else {
                waiting.removeFirst().resume()
            }
        }
        try await perform(frame)
    }
}

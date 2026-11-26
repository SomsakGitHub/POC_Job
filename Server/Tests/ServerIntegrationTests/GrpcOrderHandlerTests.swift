import Contracts
import GRPCCore
import ServiceLifecycleTestKit
import Testing
@testable import ExchangeCore
@testable import ExchangeServerKit

/// The stream handler called directly, without a transport: the ways it ends that a transport would hide (it also
/// cancels the RPC when the server shuts down, and it never reports a failed write to the test).
extension GrpcOrderTests {
    private struct WriteFailed: Error {}

    /// A response writer that keeps what it is given in `inbox`, or fails every write.
    private struct InboxWriter: RPCWriterProtocol {
        let inbox: EventInbox
        var failing = false

        func write(_ element: Tp_OrderEvent) async throws {
            if failing { throw WriteFailed() }
            await inbox.receive(element)
        }

        func write(contentsOf elements: some Sequence<Tp_OrderEvent>) async throws {
            for element in elements { try await write(element) }
        }
    }

    private func streamContext() -> ServerContext {
        ServerContext(
            descriptor: Tp_OrderService.Method.StreamOrderEvents.descriptor, remotePeer: "test", localPeer: "test",
            cancellation: ServerContext.RPCCancellationHandle()
        )
    }

    /// The graceful shutdown alone, with the RPC never cancelled, ends the handler and releases the engine's stream.
    @Test func aGracefulShutdownEndsTheStreamHandler() async {
        let engine = ExchangeServerApp(config: .ephemeral).engine
        let service = OrderServiceImpl(engine: engine)
        let writer = RPCWriter(wrapping: InboxWriter(inbox: EventInbox()))
        let context = streamContext()
        let opened = Counter()
        let returned = await finishes(within: patience) {
            await testGracefulShutdown { trigger in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try? await service.streamOrderEvents(
                            request: Tp_StreamOrderEventsRequest(), response: writer, context: context
                        )
                    }
                    if await eventually(within: patience, { await engine.liveStreamCount == 1 }) {
                        opened.increment()
                    }
                    trigger.triggerGracefulShutdown()
                }
            }
        }
        #expect(opened.value == 1, "the handler never registered its stream")
        #expect(returned, "the handler did not end on a graceful shutdown")
        let released = await eventually { await engine.liveStreamCount == 0 }
        #expect(released)
    }

    /// A write that fails ends the handler with that error and releases the engine's stream.
    @Test func aFailedWriteEndsTheStreamHandler() async {
        let engine = ExchangeServerApp(config: .ephemeral).engine
        await logRejectedOrders(engine, count: 1)
        let service = OrderServiceImpl(engine: engine)
        let writer = RPCWriter(wrapping: InboxWriter(inbox: EventInbox(), failing: true))
        let context = streamContext()
        let failed = Counter()
        let returned = await finishes(within: patience) {
            do {
                try await service.streamOrderEvents(
                    request: Tp_StreamOrderEventsRequest(), response: writer, context: context
                )
            } catch is WriteFailed {
                failed.increment()
            } catch {}
        }
        #expect(returned, "the handler did not end after a failed write")
        #expect(failed.value == 1, "the handler did not end with the write's error")
        let released = await eventually { await engine.liveStreamCount == 0 }
        #expect(released)
    }
}

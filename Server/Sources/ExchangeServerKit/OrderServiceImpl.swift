import Contracts
import ExchangeCore
import GRPCCore
import ServiceLifecycle

/// `tp.OrderService` over the exchange engine: submitting and cancelling orders, and the stream of order events.
///
/// A malformed request is an RPC error (`invalidArgument`); an order that breaks a trading rule is a normal answer
/// with `accepted` false and the reason, never an RPC error. The service holds no state of its own: everything is the
/// engine's.
struct OrderServiceImpl: Tp_OrderService.SimpleServiceProtocol {
    let engine: ExchangeEngine

    /// Checks the request's form (see `OrderRequest(wire:)`) and passes it to the engine. The answer carries the
    /// engine's order id or reject reason and its timing; a repeated client order id gets the stored answer.
    func submitOrder(request: Tp_SubmitOrderRequest, context: ServerContext) async throws -> Tp_SubmitOrderResponse {
        let order = try OrderRequest(wire: request)
        return Tp_SubmitOrderResponse(outcome: await engine.submit(order))
    }

    /// Cancels a resting order. `cancelled` is false, and no error is raised, for an id that is empty, unknown,
    /// finished or already cancelled.
    func cancelOrder(request: Tp_CancelOrderRequest, context: ServerContext) async throws -> Tp_CancelOrderResponse {
        var response = Tp_CancelOrderResponse()
        response.cancelled = await engine.cancel(orderId: request.orderID)
        return response
    }

    /// Writes the events after `from_event_seq` (all of them when `client_epoch` is empty or names another epoch),
    /// then every new event, in order.
    ///
    /// Fails with `outOfRange`, naming the oldest event still kept, when the first event asked for is gone. Ends with
    /// status OK when the engine finishes the stream (a reset, or the lab dropping connections) and on a graceful
    /// shutdown of the server: the service group waits for every service without a time limit, so a stream left open
    /// would hold up the shutdown forever. Also ends when the client cancels the call or a write fails; the engine's
    /// stream is finished either way, so the engine stops feeding it.
    func streamOrderEvents(
        request: Tp_StreamOrderEventsRequest,
        response: RPCWriter<Tp_OrderEvent>,
        context: ServerContext
    ) async throws {
        let clientEpoch = request.clientEpoch.isEmpty ? nil : request.clientEpoch
        let events: AsyncStream<OrderEventRecord>
        do {
            events = try await engine.eventStream(after: request.fromEventSeq, clientEpoch: clientEpoch)
        } catch {
            throw RPCError(eventLogError: error)
        }
        try await cancelWhenGracefulShutdown {
            try await Self.untilCancelled(context.cancellation) {
                for await record in events {
                    try await response.write(Tp_OrderEvent(record: record))
                }
            }
        }
    }

    /// Runs `operation` until it ends or the RPC is cancelled, whichever comes first; a cancelled RPC cancels the
    /// operation's task. gRPC reports a client that cancelled the call, a deadline that passed or a broken connection
    /// only through the RPC's cancellation handle, never by cancelling the handler's task: without this, the handler
    /// would wait for the next event that it can no longer deliver, and keep the engine's stream registered.
    private static func untilCancelled(
        _ rpc: ServerContext.RPCCancellationHandle, _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                // Returns once the RPC is cancelled, or (with the CancellationError dropped) once this task is: by
                // `cancelAll()` below, or by a graceful shutdown, which must end the stream with status OK too.
                try? await rpc.cancelled
            }
            // The first to finish wins; an error of the operation is rethrown and cancels the other task.
            try await group.next()
            group.cancelAll()
        }
    }
}

import Contracts
import GRPCCore
import TradeCore

// The small pieces of the order service client that need no connection: the requests and answers on the wire, the
// call options and metadata, which errors are worth another attempt, and the retry loop itself.

enum TradingWire {
    /// How long one unary call may take before it fails with `deadlineExceeded`.
    static let unaryTimeout: Duration = .seconds(2)

    /// The waits before the second and the third attempt of a submit.
    static let retryWaits: [Duration] = [.milliseconds(250), .milliseconds(500)]

    /// The options of a submit or a cancel: a 2 s deadline, and no waiting for a connection to become ready, because
    /// a call is only made on a connection that has already carried the event stream's head.
    static var unaryOptions: CallOptions {
        var options = CallOptions.defaults
        options.timeout = unaryTimeout
        options.waitForReady = false
        return options
    }

    /// The options of the event stream: no deadline (it lives as long as the connection), and a connection that
    /// fails ends the call at once instead of being waited for, so the supervisor sees the failure and backs off.
    static var streamOptions: CallOptions {
        var options = CallOptions.defaults
        options.waitForReady = false
        return options
    }

    /// `authorization: Bearer <token>` exactly when the token is there and not empty, the rule of every client.
    static func metadata(token: String?) -> Metadata {
        var metadata = Metadata()
        if let token, !token.isEmpty {
            metadata.addString("Bearer " + token, forKey: "authorization")
        }
        return metadata
    }

    /// The submit request of `draft`. A market order always sends a limit price of 0 ("no price"), even when its
    /// draft carries one, so the server never echoes a price it ignored; a limit order without a price sends 0 too.
    static func submitRequest(_ draft: OrderDraft) -> Tp_SubmitOrderRequest {
        var request = Tp_SubmitOrderRequest()
        request.clientOrderID = draft.clientOrderId
        request.symbolID = draft.symbolId
        request.side = draft.side.wire
        request.type = draft.type.wire
        request.quantity = draft.quantity
        request.limitPrice = draft.type == .limit ? (draft.limitPrice?.satang ?? 0) : 0
        return request
    }

    /// The answer as the app reads it: an empty order id is none, a reason only for a refusal and only when it maps,
    /// the server's timing as 0 when it sent none.
    static func result(_ response: Tp_SubmitOrderResponse, roundTripNs: Int64) -> SubmitResult {
        SubmitResult(
            orderId: response.orderID.isEmpty ? nil : response.orderID,
            accepted: response.accepted,
            rejectReason: response.accepted ? nil : RejectReason(wire: response.rejectReason),
            serverRecvNs: response.hasTiming ? response.timing.recvNs : 0,
            serverAckNs: response.hasTiming ? response.timing.ackNs : 0,
            clientRoundTripNs: roundTripNs
        )
    }

    /// The server's own part of a submit (ack minus receive), or nil when the answer has no timing or the difference
    /// is negative or does not fit.
    static func serverProcessingNs(_ response: Tp_SubmitOrderResponse) -> Int64? {
        guard response.hasTiming else { return nil }
        let (difference, overflow) = response.timing.ackNs.subtractingReportingOverflow(response.timing.recvNs)
        return overflow || difference < 0 ? nil : difference
    }

    /// Whether another attempt may succeed: the connection was not there or the call ran out of time.
    static func isRetriable(_ error: any Error) -> Bool {
        guard let error = error as? RPCError else { return false }
        return error.code == .unavailable || error.code == .deadlineExceeded
    }

    /// The error a caller sees. A client that is closing or closed (the connection was being replaced under the
    /// call) throws a `RuntimeError`; it means the same as a connection that is not there, so it becomes
    /// `unavailable` and falls under the same retry rule. Anything else is passed on as it came.
    static func normalized(_ error: any Error) -> any Error {
        guard let runtime = error as? RuntimeError else { return error }
        switch runtime.code {
        case .clientIsStopped, .transportError:
            return RPCError(code: .unavailable, message: "the connection to the order service closed", cause: runtime)
        default:
            return error
        }
    }

    /// The whole nanoseconds of `duration`, clamped into `Int64`.
    static func nanoseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return Int64(clamping: Int128(seconds) * 1_000_000_000 + Int128(attoseconds / 1_000_000_000))
    }
}

/// Runs `attempt` until it succeeds, at most `waits.count + 1` times: after a failure that `retriable` accepts it
/// waits the next of `waits` through `sleep` and tries again. A failure it does not accept, a failure after the last
/// wait, and a cancelled task end the loop at once with the error in hand; a cancellation during a wait ends it with
/// the error `sleep` throws.
func withRetries<Value: Sendable>(
    waits: [Duration] = TradingWire.retryWaits,
    retriable: (any Error) -> Bool,
    sleep: (Duration) async throws -> Void,
    _ attempt: () async throws -> Value
) async throws -> Value {
    var waited = 0
    while true {
        do {
            return try await attempt()
        } catch {
            guard waited < waits.count, !Task.isCancelled, retriable(error) else { throw error }
            try await sleep(waits[waited])
            waited += 1
        }
    }
}

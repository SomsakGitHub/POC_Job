import Contracts
import GRPCCore
import Synchronization
import Testing
import TradeCore
@testable import TradeNetworking

/// The order client's pieces that need no network: the retry loop, the request and answer mapping, the metadata and
/// the error rules.
@Suite(.timeLimit(.minutes(1)))
struct TradingWireTests {
    /// Records every wait and returns at once (or throws when the waiting task is cancelled).
    private final class Waits: Sendable {
        private let list = Mutex<[Duration]>([])
        func sleep(_ duration: Duration) async throws {
            list.withLock { $0.append(duration) }
            try Task.checkCancellation()
        }
        var all: [Duration] { list.withLock { $0 } }
    }

    private struct Numbered: Error, Equatable { let attempt: Int }

    /// The attempts made, and what the loop ended with, when every attempt throws `error(attempt)`.
    private func failingAttempts(
        _ error: @escaping @Sendable (Int) -> any Error, retriable: @escaping (any Error) -> Bool = TradingWire.isRetriable
    ) async -> (attempts: Int, waits: [Duration], thrown: (any Error)?) {
        let waits = Waits()
        let count = Mutex(0)
        do {
            _ = try await withRetries(retriable: retriable, sleep: { try await waits.sleep($0) }) { () throws -> Int in
                let attempt = count.withLock { count in
                    count += 1
                    return count
                }
                throw error(attempt)
            }
            return (count.withLock { $0 }, waits.all, nil)
        } catch {
            return (count.withLock { $0 }, waits.all, error)
        }
    }

    @Test func unavailableIsTriedThreeTimesWithTheExactWaitsAndTheLastErrorIsThrown() async {
        let outcome = await failingAttempts { RPCError(code: .unavailable, message: "attempt \($0)") }
        #expect(outcome.attempts == 3)
        #expect(outcome.waits == [.milliseconds(250), .milliseconds(500)])
        #expect((outcome.thrown as? RPCError)?.message == "attempt 3")
    }

    @Test func deadlineExceededIsRetriedToo() async {
        let outcome = await failingAttempts { _ in RPCError(code: .deadlineExceeded, message: "late") }
        #expect(outcome.attempts == 3)
    }

    @Test func invalidArgumentIsNotRetried() async {
        let outcome = await failingAttempts { _ in RPCError(code: .invalidArgument, message: "bad") }
        #expect(outcome.attempts == 1)
        #expect(outcome.waits.isEmpty)
        #expect((outcome.thrown as? RPCError)?.code == .invalidArgument)
    }

    @Test func aSuccessAfterAFailureEndsTheLoop() async throws {
        let count = Mutex(0)
        let waits = Waits()
        let value = try await withRetries(retriable: TradingWire.isRetriable, sleep: { try await waits.sleep($0) }) {
            let attempt = count.withLock { count in
                count += 1
                return count
            }
            if attempt == 1 { throw RPCError(code: .unavailable, message: "down") }
            return attempt
        }
        #expect(value == 2)
        #expect(waits.all == [.milliseconds(250)])
    }

    @Test func aRefusedRetryEndsAtOnce() async {
        let outcome = await failingAttempts({ _ in RPCError(code: .unavailable, message: "down") }, retriable: { _ in false })
        #expect(outcome.attempts == 1)
        #expect(outcome.waits.isEmpty)
    }

    /// A task cancelled while its attempts fail stops after the attempt in hand, without a wait.
    @Test func aCancelledTaskStopsTheRetries() async {
        let attempts = Mutex(0)
        let waits = Waits()
        let task = Task {
            try await withRetries(retriable: TradingWire.isRetriable, sleep: { try await waits.sleep($0) }) { () throws -> Int in
                attempts.withLock { $0 += 1 }
                withUnsafeCurrentTask { $0?.cancel() }
                throw RPCError(code: .unavailable, message: "down")
            }
        }
        let result = await task.result
        #expect(attempts.withLock { $0 } == 1)
        #expect(waits.all.isEmpty)
        #expect(throws: RPCError.self) { try result.get() }
    }

    /// A cancellation that arrives during a wait ends the loop with the wait's error.
    @Test func aCancellationDuringAWaitEndsTheLoop() async {
        let attempts = Mutex(0)
        let task = Task {
            try await withRetries(
                retriable: TradingWire.isRetriable,
                sleep: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    try Task.checkCancellation()
                }
            ) { () throws -> Int in
                attempts.withLock { $0 += 1 }
                throw RPCError(code: .unavailable, message: "down")
            }
        }
        let result = await task.result
        #expect(attempts.withLock { $0 } == 1)
        #expect(throws: CancellationError.self) { try result.get() }
    }

    // MARK: Mapping

    @Test func aMarketDraftNeverSendsItsPrice() {
        let request = TradingWire.submitRequest(draft("C-9", symbol: 4, side: .sell, type: .market, quantity: 300, limit: 3_425))
        #expect(request.clientOrderID == "C-9")
        #expect(request.symbolID == 4)
        #expect(request.side == .sell)
        #expect(request.type == .market)
        #expect(request.quantity == 300)
        #expect(request.limitPrice == 0)
    }

    @Test func aLimitDraftSendsItsPriceAndNoPriceIsZero() {
        #expect(TradingWire.submitRequest(draft(type: .limit, limit: 3_425)).limitPrice == 3_425)
        #expect(TradingWire.submitRequest(draft(type: .limit, limit: nil)).limitPrice == 0)
    }

    @Test func anAnswerMapsToAResult() {
        var accepted = Tp_SubmitOrderResponse()
        accepted.accepted = true
        accepted.orderID = "O-000007"
        accepted.timing.recvNs = 100
        accepted.timing.ackNs = 160
        #expect(TradingWire.result(accepted, roundTripNs: 9) == SubmitResult(
            orderId: "O-000007", accepted: true, rejectReason: nil, serverRecvNs: 100, serverAckNs: 160,
            clientRoundTripNs: 9))
        #expect(TradingWire.serverProcessingNs(accepted) == 60)

        var refused = Tp_SubmitOrderResponse()
        refused.rejectReason = .invalidLot
        #expect(TradingWire.result(refused, roundTripNs: 1) == SubmitResult(
            orderId: nil, accepted: false, rejectReason: .invalidLot, serverRecvNs: 0, serverAckNs: 0,
            clientRoundTripNs: 1))
        #expect(TradingWire.serverProcessingNs(refused) == nil)

        refused.rejectReason = .unspecified
        #expect(TradingWire.result(refused, roundTripNs: 1).rejectReason == nil)
        refused.timing.recvNs = 10
        refused.timing.ackNs = 5
        #expect(TradingWire.serverProcessingNs(refused) == nil)
        refused.timing.recvNs = .min
        refused.timing.ackNs = .max
        #expect(TradingWire.serverProcessingNs(refused) == nil)
    }

    @Test func theTokenIsSentExactlyWhenThereIsOne() {
        #expect(Array(TradingWire.metadata(token: "abc")[stringValues: "authorization"]) == ["Bearer abc"])
        #expect(TradingWire.metadata(token: "").isEmpty)
        #expect(TradingWire.metadata(token: nil).isEmpty)
    }

    @Test func aClosingClientCountsAsUnavailable() {
        let stopped = TradingWire.normalized(RuntimeError(code: .clientIsStopped, message: "stopped"))
        #expect((stopped as? RPCError)?.code == .unavailable)
        #expect(TradingWire.isRetriable(stopped))
        let other = TradingWire.normalized(RPCError(code: .permissionDenied, message: "no"))
        #expect((other as? RPCError)?.code == .permissionDenied)
        #expect(!TradingWire.isRetriable(other))
        #expect(!TradingWire.isRetriable(CancellationError()))
    }

    @Test func theTargetComesFromTheConfigAndABadOneIsNone() {
        #expect(OrderEventLink.target(ClientConfig(host: "127.0.0.1", grpcPort: 5)) != nil)
        #expect(OrderEventLink.target(ClientConfig(host: "[::1]", grpcPort: 5)) != nil)
        #expect(OrderEventLink.target(ClientConfig(host: "", grpcPort: 5)) == nil)
        #expect(OrderEventLink.target(ClientConfig(host: "[]", grpcPort: 5)) == nil)
        #expect(OrderEventLink.target(ClientConfig(grpcPort: 0)) == nil)
        #expect(OrderEventLink.target(ClientConfig(grpcPort: 70_000)) == nil)
    }

    @Test func durationsBecomeNanoseconds() {
        #expect(TradingWire.nanoseconds(.milliseconds(1_500)) == 1_500_000_000)
        #expect(TradingWire.nanoseconds(.seconds(Int64.max)) == .max)
    }
}

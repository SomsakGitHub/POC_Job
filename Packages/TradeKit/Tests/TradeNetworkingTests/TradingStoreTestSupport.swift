import Contracts
import Foundation
import Synchronization
import Testing
import TradeCore
@testable import TradeNetworking

// Fakes for the trading store tests: an order client that records what it was asked and hands the test the closures
// of the event stream, and a REST API whose account answers the test sets (and can hold until it releases them).

/// A `TradingClient` without a network. `submit` answers what `answer` says; `startEventStream` keeps its closures
/// for the test to call; `connection` streams whatever the test pushes.
final class FakeTradingClient: TradingClient {
    struct Handlers: Sendable {
        let resumeFrom: @Sendable () -> (seq: UInt64, epoch: String?)
        let onEvent: @Sendable (Tp_OrderEvent) async -> Void
        let onOutOfRange: @Sendable () async -> Void
    }

    private struct Shared {
        var submitted: [OrderDraft] = []
        var cancelled: [String] = []
        var starts = 0
        var stops = 0
        var handlers: Handlers?
        var observers: [AsyncStream<ConnectionState>.Continuation] = []
        var current: ConnectionState?
        var answer: @Sendable (OrderDraft) throws -> SubmitResult = { FakeTradingClient.accepted($0) }
    }

    struct Failure: Error {}

    private let shared = Mutex(Shared())

    /// An accepted answer for `draft`.
    static func accepted(_ draft: OrderDraft) -> SubmitResult {
        SubmitResult(
            orderId: "O-" + draft.clientOrderId, accepted: true, rejectReason: nil, serverRecvNs: 1, serverAckNs: 2,
            clientRoundTripNs: 3)
    }

    /// A refusal, with `reason` (nil: none that maps).
    static func refused(_ reason: RejectReason?) -> SubmitResult {
        SubmitResult(
            orderId: nil, accepted: false, rejectReason: reason, serverRecvNs: 1, serverAckNs: 2, clientRoundTripNs: 3)
    }

    /// What every later `submit` answers (or throws).
    func answer(_ answer: @escaping @Sendable (OrderDraft) throws -> SubmitResult) {
        shared.withLock { $0.answer = answer }
    }

    func submit(_ d: OrderDraft) async throws -> SubmitResult {
        let answer = shared.withLock { shared in
            shared.submitted.append(d)
            return shared.answer
        }
        return try answer(d)
    }

    func cancel(orderId: String) async throws -> Bool {
        shared.withLock { $0.cancelled.append(orderId) }
        return true
    }

    func startEventStream(
        resumeFrom: @escaping @Sendable () -> (seq: UInt64, epoch: String?),
        onEvent: @escaping @Sendable (Tp_OrderEvent) async -> Void,
        onOutOfRange: @escaping @Sendable () async -> Void
    ) {
        shared.withLock { shared in
            shared.starts += 1
            shared.handlers = Handlers(resumeFrom: resumeFrom, onEvent: onEvent, onOutOfRange: onOutOfRange)
            shared.current = nil
        }
    }

    /// A new stream: the current state first (if any), then every pushed one; finished by `stop()`.
    var connection: AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionState.self)
        shared.withLock { shared in
            if let current = shared.current { continuation.yield(current) }
            if shared.current == .stopped {
                continuation.finish()
            } else {
                shared.observers.append(continuation)
            }
        }
        return stream
    }

    func nudge() {}

    func stop() async {
        let observers = shared.withLock { shared in
            shared.stops += 1
            shared.current = .stopped
            defer { shared.observers = [] }
            return shared.observers
        }
        for observer in observers {
            observer.yield(.stopped)
            observer.finish()
        }
    }

    /// Sends `state` to every open connection stream.
    func push(_ state: ConnectionState) {
        let observers = shared.withLock { shared in
            shared.current = state
            return shared.observers
        }
        for observer in observers { observer.yield(state) }
    }

    var submitted: [OrderDraft] { shared.withLock { $0.submitted } }
    var cancelled: [String] { shared.withLock { $0.cancelled } }
    var starts: Int { shared.withLock { $0.starts } }
    var observerCount: Int { shared.withLock { $0.observers.count } }
    var handlers: Handlers? { shared.withLock { $0.handlers } }

    /// The stream's closures; fails the test when no stream was started.
    func requireHandlers() throws -> Handlers {
        try #require(handlers)
    }
}

/// A `RestAPI` whose `account()` answers from a queue the test fills; an empty queue answers `fallback`. A queued
/// `.hold` waits until the test releases it with the answer to give. Every other call throws.
final class FakeRestAPI: RestAPI {
    enum Answer: Sendable {
        case account(AccountDTO)
        case failure
        case hold
    }

    struct Failure: Error {}

    private struct Shared {
        var queue: [Answer] = []
        var fallback: Answer = .failure
        var calls = 0
        var held: [CheckedContinuation<Answer, Never>] = []
    }

    private let shared = Mutex(Shared())

    init(fallback: Answer = .failure) {
        shared.withLock { $0.fallback = fallback }
    }

    /// Queues the answers of the next calls, in order.
    func enqueue(_ answers: Answer...) {
        shared.withLock { $0.queue += answers }
    }

    /// What a call answers once the queue is empty.
    func setFallback(_ answer: Answer) {
        shared.withLock { $0.fallback = answer }
    }

    func account() async throws -> AccountDTO {
        let answer = shared.withLock { shared in
            shared.calls += 1
            return shared.queue.isEmpty ? shared.fallback : shared.queue.removeFirst()
        }
        var given = answer
        if case .hold = answer {
            given = await withCheckedContinuation { continuation in
                shared.withLock { $0.held.append(continuation) }
            }
        }
        switch given {
        case .account(let account): return account
        case .failure, .hold: throw Failure()
        }
    }

    /// Lets the oldest held call return `answer`; false when no call is held.
    @discardableResult
    func release(_ answer: Answer) -> Bool {
        let held = shared.withLock { shared in
            shared.held.isEmpty ? nil : shared.held.removeFirst()
        }
        held?.resume(returning: answer)
        return held != nil
    }

    var calls: Int { shared.withLock { $0.calls } }
    var heldCount: Int { shared.withLock { $0.held.count } }

    func symbols() async throws -> [SymbolDTO] { throw Failure() }
    func candles(ticker: String, interval: CandleInterval, limit: Int) async throws -> [Candle] { throw Failure() }
    func transactions(cursor: String?, limit: Int) async throws -> TransactionPageDTO { throw Failure() }
    func serverTimeNs() async throws -> Int64 { throw Failure() }
    func lab() async throws -> LabSettings { throw Failure() }
    func setLab(_ patch: LabPatch) async throws -> LabSettings { throw Failure() }
    func dropConnections() async throws { throw Failure() }
    func resetServer() async throws -> String { throw Failure() }
}

/// A clock the test sets by hand.
final class MonotonicStub: Sendable {
    private let value: Mutex<UInt64>

    init(_ start: UInt64 = 1_000_000_000) {
        value = Mutex(start)
    }

    var now: UInt64 { value.withLock { $0 } }

    func advance(by nanoseconds: UInt64) {
        value.withLock { $0 += nanoseconds }
    }
}

/// Whether `condition` holds within `limit`, checked between short sleeps, and once more at the limit.
@MainActor
func until(within limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

/// A store over fakes, with a manual monotonic clock and a fixed wall clock (createdNs 77).
@MainActor
struct StoreRig {
    let client = FakeTradingClient()
    let rest: FakeRestAPI
    let latency = LatencyRecorder()
    let clock = MonotonicStub()
    let store: TradingStore

    init(rest: FakeRestAPI = FakeRestAPI()) {
        self.rest = rest
        let clock = clock
        store = TradingStore(
            client: client, rest: rest, latency: latency, monotonicNs: { clock.now }, wallNs: { 77 })
    }

    /// Starts the store and waits until its observer has subscribed to the connection.
    func start() async throws {
        let before = client.observerCount
        await store.start()
        let subscribed = await until { client.observerCount > before }
        #expect(subscribed, "the store did not subscribe to the connection states")
    }

    /// Hands `events` to the store through the stream's closure, in order.
    func deliver(_ events: [Tp_OrderEvent]) async throws {
        let handlers = try client.requireHandlers()
        for event in events { await handlers.onEvent(event) }
    }
}

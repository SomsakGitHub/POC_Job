import Contracts
import Synchronization
import TradeCore
import TradeNetworking

/// A trading client that keeps the three closures of its event stream for the test, counts what it is asked and reports
/// the states the test pushes. `submit` answers as its script says (every order is accepted unless the test chose
/// otherwise) and `cancel` answers false. Starting the event stream makes `startsAs` its state, as a supervised client
/// says `.connecting` the moment it starts.
final class FakeTradingClient: TradingClient {
    /// The three closures the store gave the event stream.
    struct Handlers: Sendable {
        /// Where the stream resumes: the last event number seen and the epoch it belongs to.
        let resumeFrom: @Sendable () -> (seq: UInt64, epoch: String?)
        /// Takes one order event.
        let onEvent: @Sendable (Tp_OrderEvent) async -> Void
        /// Called when the server cannot resume the stream where it left off.
        let onOutOfRange: @Sendable () async -> Void
    }

    /// What one call to `submit(_:)` does.
    enum SubmitAnswer: Sendable {
        /// Takes the order: the answer carries the server's id for it.
        case accepted
        /// Refuses the order for this reason.
        case rejected(RejectReason)
        /// Throws this error, as a call does that got no answer.
        case failure(any Error)
        /// Does not return until the test calls `releaseSubmit(call:_:)`.
        case hold
    }

    /// What the client counts between calls, under one lock.
    private struct Shared {
        /// The closures of the event stream; nil until it is started.
        var handlers: Handlers?
        /// How many times the event stream was started.
        var starts = 0
        /// How many times `stop()` was called.
        var stops = 0
        /// How many times `nudge()` was called.
        var nudges = 0
        /// The answers of `submit(_:)` still to give, oldest first.
        var submitScript: [SubmitAnswer]
        /// The answer of `submit(_:)` once the script is used up.
        var submitFallback: SubmitAnswer
        /// Every draft `submit(_:)` was given, in the order the calls arrived.
        var drafts: [OrderDraft] = []
        /// The submit calls that wait for a release, by the number of the call (0 is the first call).
        var heldSubmits: [Int: CheckedContinuation<SubmitResult, any Error>] = [:]
    }

    /// Where the client notes every call it gets.
    private let log: EventLog
    /// The states the client reports.
    private let hub = StateHub()
    /// The state starting the event stream makes current.
    private let startsAs: ConnectionState
    /// The client's counters.
    private let shared: Mutex<Shared>

    /// A client that notes its calls in `log` and says `startsAs` when its event stream starts. `submits` are the
    /// answers of the first calls of `submit(_:)`, one per call, and `submitFallback` is the answer of every call after
    /// them.
    init(
        log: EventLog, startsAs: ConnectionState = .connecting, submits: [SubmitAnswer] = [],
        submitFallback: SubmitAnswer = .accepted
    ) {
        self.log = log
        self.startsAs = startsAs
        shared = Mutex(Shared(submitScript: submits, submitFallback: submitFallback))
    }

    /// Notes the draft and gives the next answer of the script. A held call does not return until the test releases it
    /// by its number; the draft is noted first, so a test can wait for the call to be held.
    func submit(_ d: OrderDraft) async throws -> SubmitResult {
        let (number, answer) = shared.withLock { shared in
            shared.drafts.append(d)
            let answer = shared.submitScript.isEmpty ? shared.submitFallback : shared.submitScript.removeFirst()
            return (shared.drafts.count - 1, answer)
        }
        switch answer {
        case .accepted:
            return SubmitResult(
                orderId: "O-" + d.clientOrderId, accepted: true, rejectReason: nil, serverRecvNs: 1, serverAckNs: 2,
                clientRoundTripNs: 3
            )
        case .rejected(let reason):
            return SubmitResult(
                orderId: nil, accepted: false, rejectReason: reason, serverRecvNs: 1, serverAckNs: 2,
                clientRoundTripNs: 3
            )
        case .failure(let error):
            throw error
        case .hold:
            return try await withCheckedThrowingContinuation { continuation in
                shared.withLock { $0.heldSubmits[number] = continuation }
            }
        }
    }

    /// Lets the held submit call number `call` (0 is the first call) return `result`; false when that call is not held.
    @discardableResult
    func releaseSubmit(call: Int, _ result: Result<SubmitResult, any Error>) -> Bool {
        let held = shared.withLock { $0.heldSubmits.removeValue(forKey: call) }
        held?.resume(with: result)
        return held != nil
    }

    /// Cancels nothing.
    func cancel(orderId: String) async throws -> Bool {
        false
    }

    /// Keeps the closures for the test, notes the call and makes `startsAs` the current state.
    func startEventStream(
        resumeFrom: @escaping @Sendable () -> (seq: UInt64, epoch: String?),
        onEvent: @escaping @Sendable (Tp_OrderEvent) async -> Void,
        onOutOfRange: @escaping @Sendable () async -> Void
    ) {
        log.add("trading.startEventStream")
        shared.withLock { shared in
            shared.starts += 1
            shared.handlers = Handlers(resumeFrom: resumeFrom, onEvent: onEvent, onOutOfRange: onOutOfRange)
        }
        hub.push(startsAs)
    }

    /// A new stream of the client's states on every access, as the real client gives.
    var connection: AsyncStream<ConnectionState> {
        log.add("trading.connection")
        return hub.makeStream()
    }

    /// Notes and counts the call.
    func nudge() {
        log.add("trading.nudge")
        shared.withLock { $0.nudges += 1 }
    }

    /// Notes the stop, says `.stopped` and ends every stream.
    func stop() async {
        log.add("trading.stop")
        shared.withLock { $0.stops += 1 }
        hub.stop()
    }

    /// Sends `state` to everyone watching the connection.
    func push(_ state: ConnectionState) {
        hub.push(state)
    }

    /// The closures of the event stream; nil until it was started.
    var handlers: Handlers? { shared.withLock { $0.handlers } }
    /// How many times the event stream was started.
    var starts: Int { shared.withLock { $0.starts } }
    /// How many times `stop()` was called.
    var stops: Int { shared.withLock { $0.stops } }
    /// How many times `nudge()` was called.
    var nudges: Int { shared.withLock { $0.nudges } }
    /// How the streams that are over ended.
    var terminations: [StateHub.Termination] { hub.terminations }
    /// Every draft `submit(_:)` was given, in the order the calls arrived.
    var drafts: [OrderDraft] { shared.withLock { $0.drafts } }
    /// How many submit calls wait for a release.
    var heldSubmitCount: Int { shared.withLock { $0.heldSubmits.count } }
}

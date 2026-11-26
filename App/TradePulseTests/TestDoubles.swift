import Synchronization
import TradeNetworking

// The doubles the app's tests stand in for the network with. None of them opens a socket or waits for time to pass:
// each answers at once, or holds a call until the test lets it go. The trading client and the REST API are in
// `FakeTradingClient.swift` and `FakeRest.swift`.

/// The calls the fakes of one test received, in the order they arrived.
final class EventLog: Sendable {
    /// The entries so far, oldest first.
    private let lines = Mutex<[String]>([])

    /// Notes that `line` happened.
    func add(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    /// Everything noted so far, in the order it happened.
    var entries: [String] {
        lines.withLock { $0 }
    }
}

/// The connection states a fake client reports: every stream it hands out yields the current state first, if there is
/// one, and then every state the test pushes; a stream ends when the client is stopped.
final class StateHub: Sendable {
    /// How a stream of states ended.
    typealias Termination = AsyncStream<ConnectionState>.Continuation.Termination

    /// What the hub keeps between calls, under one lock.
    private struct Shared {
        /// The state a new stream says first; nil before the first one was pushed.
        var current: ConnectionState?
        /// The streams that are open.
        var observers: [AsyncStream<ConnectionState>.Continuation] = []
        /// How the streams that are over ended, in the order they ended.
        var terminations: [Termination] = []
    }

    /// The hub's state.
    private let shared = Mutex(Shared())

    /// A new stream, as the real clients hand out on every access.
    func makeStream() -> AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionState.self)
        continuation.onTermination = { [weak self] termination in
            self?.shared.withLock { $0.terminations.append(termination) }
        }
        shared.withLock { shared in
            if let current = shared.current { continuation.yield(current) }
            shared.observers.append(continuation)
        }
        return stream
    }

    /// Makes `state` the current one and sends it to every open stream.
    func push(_ state: ConnectionState) {
        let observers = shared.withLock { shared in
            shared.current = state
            return shared.observers
        }
        for observer in observers { observer.yield(state) }
    }

    /// What a stopped client does: says `.stopped` and ends every stream.
    func stop() {
        let observers = shared.withLock { shared in
            shared.current = .stopped
            defer { shared.observers = [] }
            return shared.observers
        }
        for observer in observers {
            observer.yield(.stopped)
            observer.finish()
        }
    }

    /// How the streams that are over ended: cancelled by their reader, or finished by the client.
    var terminations: [Termination] {
        shared.withLock { $0.terminations }
    }
}

/// A market client that records what it was asked, in order, and reports the states the test pushes. With
/// `holdsSubscribe` its first `subscribe` does not return until the test calls `releaseSubscribe()`.
final class FakeMarketClient: MarketDataClient {
    /// What the client counts between calls, under one lock.
    private struct Shared {
        /// The tickers of every `subscribe` call, in order.
        var subscribed: [[String]] = []
        /// How many times `start()` was called.
        var starts = 0
        /// How many times `stop()` was called.
        var stops = 0
        /// How many times `nudge()` was called.
        var nudges = 0
    }

    /// Where the client notes every call it gets.
    private let log: EventLog
    /// The states the client reports.
    private let hub = StateHub()
    /// Whether the first `subscribe` waits for `releaseSubscribe()`.
    private let holdsSubscribe: Bool
    /// Set when `subscribe` was entered.
    private let entered = Flag()
    /// What a held `subscribe` waits on.
    private let gate = AsyncStream<Void>.makeStream()
    /// The client's counters.
    private let shared = Mutex(Shared())

    /// A client that notes its calls in `log`.
    init(log: EventLog, holdsSubscribe: Bool = false) {
        self.log = log
        self.holdsSubscribe = holdsSubscribe
    }

    /// A new stream of the client's states on every access, as the real client gives.
    var connection: AsyncStream<ConnectionState> {
        log.add("market.connection")
        return hub.makeStream()
    }

    /// Like the supervised client, it says `.connecting` as soon as it starts.
    func start() {
        log.add("market.start")
        shared.withLock { $0.starts += 1 }
        hub.push(.connecting)
    }

    /// Notes the stop, says `.stopped` and ends every stream.
    func stop() async {
        log.add("market.stop")
        shared.withLock { $0.stops += 1 }
        hub.stop()
    }

    /// Notes the tickers, and waits for `releaseSubscribe()` when the client holds its subscribe.
    func subscribe(_ tickers: [String]) async {
        log.add("market.subscribe")
        shared.withLock { $0.subscribed.append(tickers) }
        entered.set()
        guard holdsSubscribe else { return }
        var iterator = gate.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    /// Notes the call.
    func unsubscribe(_ tickers: [String]) async {
        log.add("market.unsubscribe")
    }

    /// Notes and counts the call.
    func nudge() {
        log.add("market.nudge")
        shared.withLock { $0.nudges += 1 }
    }

    /// The offset between the server's clock and the client's, which a fake does not have.
    var clockOffsetNs: Int64 { 0 }

    /// Sends `state` to everyone watching the connection.
    func push(_ state: ConnectionState) {
        hub.push(state)
    }

    /// Lets a held `subscribe` return.
    func releaseSubscribe() {
        gate.continuation.yield()
    }

    /// The tickers of every `subscribe` call, in order.
    var subscribed: [[String]] { shared.withLock { $0.subscribed } }
    /// How many times `start()` was called.
    var starts: Int { shared.withLock { $0.starts } }
    /// How many times `stop()` was called.
    var stops: Int { shared.withLock { $0.stops } }
    /// How many times `nudge()` was called.
    var nudges: Int { shared.withLock { $0.nudges } }
    /// Whether `subscribe` was called, even if it has not returned yet.
    var hasEnteredSubscribe: Bool { entered.isSet }
    /// How the streams that are over ended.
    var terminations: [StateHub.Termination] { hub.terminations }
}

/// The `sleep` the environment waits with: it records every duration it was asked for and then, as the test chose,
/// returns at once, waits until the test calls `release()` (and throws `CancellationError` when its task is
/// cancelled first), or throws an error of the test's making.
final class FakeSleeper: Sendable {
    /// What every sleep does.
    enum Behavior: Sendable {
        /// Returns at once, as if the time had passed.
        case returnAtOnce
        /// Waits until `release()` and throws `CancellationError` when cancelled first.
        case holdUntilReleased
        /// Throws this error.
        case throwError(any Error)
    }

    /// What the sleeper keeps between calls, under one lock.
    private struct Shared {
        /// The durations asked for, in order.
        var durations: [Duration] = []
        /// The gates of the sleeps that wait for a release, oldest first.
        var gates: [AsyncStream<Void>.Continuation] = []
    }

    /// What every sleep does.
    private let behavior: Behavior
    /// The sleeper's record and gates.
    private let shared = Mutex(Shared())

    /// A sleeper whose sleeps all behave as `behavior`.
    init(_ behavior: Behavior = .returnAtOnce) {
        self.behavior = behavior
    }

    /// Records `duration` and then behaves as chosen. A sleep that waits for a release notes its request and its gate
    /// under one lock: a test that waits until `requested` says the sleep is there and then calls `release()` must find
    /// the gate, or the release would be lost and the sleep would wait for ever.
    func sleep(_ duration: Duration) async throws {
        switch behavior {
        case .returnAtOnce:
            shared.withLock { $0.durations.append(duration) }
        case .throwError(let error):
            shared.withLock { $0.durations.append(duration) }
            throw error
        case .holdUntilReleased:
            let (gate, opener) = AsyncStream<Void>.makeStream()
            shared.withLock { shared in
                shared.durations.append(duration)
                shared.gates.append(opener)
            }
            var iterator = gate.makeAsyncIterator()
            // An `AsyncStream` iterator returns nil when the waiting task is cancelled.
            guard await iterator.next() != nil else { throw CancellationError() }
        }
    }

    /// Lets the oldest held sleep return.
    func release() {
        let opener = shared.withLock { shared in
            shared.gates.isEmpty ? nil : shared.gates.removeFirst()
        }
        opener?.yield()
    }

    /// Every duration asked for so far, in order.
    var durations: [Duration] { shared.withLock { $0.durations } }

    /// How many sleeps were asked for.
    var requested: Int { durations.count }
}

/// A failure of the test's own, for a double that has to throw something that is not a `CancellationError`.
struct TestFailure: Error {}

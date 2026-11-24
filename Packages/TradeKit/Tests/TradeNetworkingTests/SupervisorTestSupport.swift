import Synchronization
import Testing
import TradeCore
@testable import TradeNetworking

// Fakes for the supervisor tests: a `sleep` that only returns when the test says so, and a run that only ends when the
// test says so. Nothing in these tests waits for wall-clock time; every step waits for an event the supervisor caused.

/// A `sleep` for a supervisor. Every call is announced on `requests`, in call order, and returns only when the test
/// finishes it; it throws `CancellationError` when the sleeping task is cancelled first.
final class FakeSleeper: Sendable {
    enum Outcome: Sendable, Equatable {
        case finished
        case cancelled
    }

    /// One call of `sleep`.
    struct Request: Sendable {
        let id: Int
        let duration: Duration
        fileprivate let opener: AsyncStream<(@Sendable () -> Void)?>.Continuation

        /// Lets the call return; `action` runs in the sleeping task just before it does.
        func finish(then action: (@Sendable () -> Void)? = nil) {
            opener.yield(action)
        }
    }

    let requests: AsyncStream<Request>
    private let announce: AsyncStream<Request>.Continuation
    private let state = Mutex<(next: Int, outcomes: [Int: Outcome])>((0, [:]))

    init() {
        (requests, announce) = AsyncStream.makeStream()
    }

    func sleep(_ duration: Duration) async throws {
        let (gate, opener) = AsyncStream<(@Sendable () -> Void)?>.makeStream()
        let id = state.withLock { state in
            defer { state.next += 1 }
            return state.next
        }
        announce.yield(Request(id: id, duration: duration, opener: opener))
        var iterator = gate.makeAsyncIterator()
        // An `AsyncStream` iterator returns nil when the waiting task is cancelled.
        guard let action = await iterator.next() else {
            state.withLock { $0.outcomes[id] = .cancelled }
            throw CancellationError()
        }
        state.withLock { $0.outcomes[id] = .finished }
        action?()
    }

    /// How the call ended, or nil while it is still sleeping.
    func outcome(of request: Request) -> Outcome? {
        state.withLock { $0.outcomes[request.id] }
    }

    /// How many times `sleep` has been called.
    var callCount: Int {
        state.withLock { $0.next }
    }
}

/// One call of the run closure. It does what the test tells it, in order (call `markConnected`, return, throw), and
/// ends when the test says so or when its task is cancelled. `markConnected` does not escape the run, so the test
/// asks the run to call it.
final class FakeRun: Sendable {
    enum End: Sendable, Equatable {
        case returned
        case threw
        case cancelled
    }

    private enum Command: Sendable {
        case connect
        case finish(throwing: Bool, then: (@Sendable () -> Void)?)
    }

    struct Failure: Error {}

    private struct Hold {
        var waiter: CheckedContinuation<Bool, Never>?
        /// Set by `release`: whether to call `markConnected` before returning.
        var released: Bool?
    }

    private let holdsAfterCancel: Bool
    private let commands: AsyncStream<Command>
    private let sink: AsyncStream<Command>.Continuation
    private let cancelSignal: AsyncStream<Void>
    private let cancelSink: AsyncStream<Void>.Continuation
    private let state = Mutex<(end: End?, returned: Bool, hold: Hold)>((nil, false, Hold()))

    fileprivate init(holdsAfterCancel: Bool) {
        self.holdsAfterCancel = holdsAfterCancel
        (commands, sink) = AsyncStream.makeStream()
        (cancelSignal, cancelSink) = AsyncStream.makeStream()
    }

    fileprivate func perform(_ markConnected: @Sendable () -> Void) async throws {
        defer { state.withLock { $0.returned = true } }
        var iterator = commands.makeAsyncIterator()
        // An `AsyncStream` iterator returns nil when the waiting task is cancelled.
        while let command = await iterator.next() {
            switch command {
            case .connect:
                markConnected()
            case .finish(let throwing, let action):
                state.withLock { $0.end = throwing ? .threw : .returned }
                action?()
                if throwing { throw Failure() }
                return
            }
        }
        state.withLock { $0.end = .cancelled }
        cancelSink.finish()
        if holdsAfterCancel {
            // Not cancellable: like a connection that takes a moment to close.
            let connect = await withCheckedContinuation { continuation in
                let released: Bool? = state.withLock { state in
                    if state.hold.released == nil { state.hold.waiter = continuation }
                    return state.hold.released
                }
                if let released { continuation.resume(returning: released) }
            }
            if connect { markConnected() }
        }
        throw CancellationError()
    }

    /// Makes the run call its `markConnected`.
    func markConnected() {
        sink.yield(.connect)
    }

    /// Makes the run return; `action` runs in the run's task just before it does.
    func succeed(then action: (@Sendable () -> Void)? = nil) {
        sink.yield(.finish(throwing: false, then: action))
    }

    /// Makes the run throw; `action` runs in the run's task just before it does.
    func fail(then action: (@Sendable () -> Void)? = nil) {
        sink.yield(.finish(throwing: true, then: action))
    }

    /// Waits until the run has seen its cancellation.
    func cancelled() async {
        for await _ in cancelSignal {}
    }

    /// Lets a run that `holdsAfterCancel` return after its cancellation; with `connectingFirst` it calls its
    /// `markConnected` just before it returns.
    func release(connectingFirst: Bool = false) {
        let waiter = state.withLock { state in
            state.hold.released = connectingFirst
            defer { state.hold.waiter = nil }
            return state.hold.waiter
        }
        waiter?.resume(returning: connectingFirst)
    }

    /// How the run ended, or nil while it runs.
    var end: End? { state.withLock { $0.end } }
    /// Whether the run closure has returned (or thrown) to its caller.
    var hasReturned: Bool { state.withLock { $0.returned } }
}

/// The run closure for a supervisor: every call is announced on `runs` as a `FakeRun`.
final class FakeRunner: Sendable {
    let runs: AsyncStream<FakeRun>
    private let announce: AsyncStream<FakeRun>.Continuation
    private let holdsAfterCancel: Bool
    private let calls = Mutex(0)

    init(holdsAfterCancel: Bool = false) {
        self.holdsAfterCancel = holdsAfterCancel
        (runs, announce) = AsyncStream.makeStream()
    }

    func run(_ markConnected: @Sendable () -> Void) async throws {
        calls.withLock { $0 += 1 }
        let run = FakeRun(holdsAfterCancel: holdsAfterCancel)
        announce.yield(run)
        try await run.perform(markConnected)
    }

    var callCount: Int { calls.withLock { $0 } }
}

/// A supervisor over a fake sleep with a fixed jitter, and its fakes. The stable time is 7 s, a length no backoff
/// wait has, so a test can tell the stable timer's sleep from a backoff wait by its duration.
struct SupervisorRig {
    static let stableAfter = Duration.seconds(7)

    let sleeper = FakeSleeper()
    let runner: FakeRunner
    let supervisor: ConnectionSupervisor
    private let jitterCalls = Counter()
    private let jitterHook = HookSlot()

    init(jitter: Double = 1.0, holdsAfterCancel: Bool = false) {
        runner = FakeRunner(holdsAfterCancel: holdsAfterCancel)
        let sleeper = sleeper
        let jitterCalls = jitterCalls
        let jitterHook = jitterHook
        supervisor = ConnectionSupervisor(
            name: "test", stableAfter: Self.stableAfter,
            jitter: {
                jitterCalls.increment()
                jitterHook.take()?()
                return jitter
            },
            sleep: { try await sleeper.sleep($0) }
        )
    }

    /// Starts the supervisor with the fake runner.
    func start() {
        let runner = runner
        supervisor.start { try await runner.run($0) }
    }

    /// How many times the supervisor asked for a jitter.
    var jitterCount: Int { jitterCalls.value }

    /// Runs `action` inside the next call of the jitter: after the run has ended and `.reconnecting` was emitted,
    /// before the backoff wait has begun.
    func onNextJitter(_ action: @escaping @Sendable () -> Void) {
        jitterHook.set(action)
    }

    /// Waits, by yielding and never by sleeping, until the supervisor's attempt count is `value`. False if it is not
    /// after many rounds, which only a broken supervisor causes.
    func attemptBecomes(_ value: Int) async -> Bool {
        for _ in 0..<100_000 {
            if supervisor.attempt == value { return true }
            await Task.yield()
        }
        return supervisor.attempt == value
    }
}

/// A count that one task raises while another reads it.
final class Counter: Sendable {
    private let count = Mutex(0)

    func increment() {
        count.withLock { $0 += 1 }
    }

    var value: Int { count.withLock { $0 } }
}

extension AsyncStream.Iterator {
    /// The next `count` elements, fewer if the stream finishes first.
    mutating func take(_ count: Int) async -> [Element] {
        var taken: [Element] = []
        while taken.count < count, let element = await next() {
            taken.append(element)
        }
        return taken
    }
}

/// One action, set by a test and taken (once) by the code that runs it.
final class HookSlot: Sendable {
    private let action = Mutex<(@Sendable () -> Void)?>(nil)

    func set(_ action: @escaping @Sendable () -> Void) {
        self.action.withLock { $0 = action }
    }

    /// The action, if one is set; it is then cleared.
    func take() -> (@Sendable () -> Void)? {
        action.withLock { action in
            defer { action = nil }
            return action
        }
    }
}

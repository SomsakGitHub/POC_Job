import Synchronization
import TradeCore

/// Keeps a connection alive: runs a connection closure, and when it ends (it returns, throws or is cancelled), waits a
/// backoff and runs it again, until `stop()`.
///
/// One pass of the loop emits `.connecting` and calls the run with a `markConnected` that the run calls once its
/// connection is proven; the first call of each run emits `.connected` and starts the stable timer. When the run ends,
/// the attempt count goes up by one, `.reconnecting(attempt:)` is emitted, and the loop waits
/// `backoff.delay(attempt: attempt - 1, jitter: jitter())` before the next pass. A run that stays up for
/// `stableAfter` sets the count back to 0, so a connection that drops after a long healthy spell is retried quickly.
/// The backoff wait and the stable timer both go through the injected `sleep`, so a test decides when they end.
///
/// All state sits behind one lock that is never held across an `await`, and every task the supervisor starts is
/// awaited by its owner: a run and its stable timer by the loop, the loop by `stop()`.
public final class ConnectionSupervisor: Sendable {
    /// The connection closure: it runs one connection until it ends, and calls `markConnected` once it is up.
    /// `markConnected` does not escape: it can only be called while the run is still running, so a run that has
    /// ended can never mark a later one as connected.
    public typealias Run = @Sendable (_ markConnected: @Sendable () -> Void) async throws -> Void

    private let name: String
    private let backoff: ReconnectBackoff
    private let stableAfter: Duration
    private let jitter: @Sendable () -> Double
    private let sleep: @Sendable (Duration) async throws -> Void
    private let shared = Mutex(SupervisorStorage())

    /// A supervisor whose loop task is named `name`. `jitter` is asked for a number in 0...1 once per backoff wait;
    /// `sleep` is every wait the supervisor makes (the backoff and the stable timer) and must throw when its task is
    /// cancelled, which is how a nudge or `stop()` ends a wait.
    public init(
        name: String, backoff: ReconnectBackoff = .init(), stableAfter: Duration = .seconds(5),
        jitter: @escaping @Sendable () -> Double = { .random(in: 0...1) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.name = name
        self.backoff = backoff
        self.stableAfter = stableAfter
        self.jitter = jitter
        self.sleep = sleep
    }

    /// A new stream of the connection's states; every access makes a new one, so any number of observers can watch.
    ///
    /// Before the first `start` it yields nothing until something happens. From `start` on it yields the current state
    /// first and then every change; a state is only emitted when it differs from the current one. After `stop()` it
    /// yields `.stopped` and finishes, and `stop()` finishes every stream that is open. It keeps the newest 16 states
    /// for an observer that falls behind, and an observer that drops its stream is forgotten.
    public var states: AsyncStream<ConnectionState> {
        let (stream, observer) = AsyncStream.makeStream(
            of: ConnectionState.self, bufferingPolicy: .bufferingNewest(16)
        )
        let id: UInt64? = shared.withLock { state in
            if let current = state.current { observer.yield(current) }
            guard state.current != .stopped else { return nil }
            let id = state.nextObserverID
            state.nextObserverID += 1
            state.observers[id] = observer
            return id
        }
        guard let id else {
            observer.finish()
            return stream
        }
        // Set outside the lock: `onTermination` takes the lock itself.
        observer.onTermination = { [weak self] _ in
            self?.shared.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Starts the loop, which runs `run` again and again until `stop()`.
    ///
    /// It does not wait: the state becomes `.connecting` at once and the loop runs in a task of its own. A `start` while
    /// a loop exists (running, or still being stopped) is ignored. A `start` after `stop()` has returned begins a new
    /// life: the attempt count is 0 again and nothing of the last life (its runs, its `markConnected`, its nudges)
    /// reaches the new one.
    public func start(_ run: @escaping Run) {
        shared.withLock { state in
            guard state.loop == nil else { return }
            state.life += 1
            state.attempt = 0
            state.stopping = false
            state.connectedRun = nil
            state.emit(.connecting)
            state.loop = makeLoop(run)
        }
    }

    /// Asks for a new connection now. Callable from anywhere; it does not wait.
    ///
    /// During a backoff wait it ends the wait, and the next run starts at once. While a run is active (connecting or
    /// connected) it cancels the run, which counts as a connection that ended: `.reconnecting(attempt:)` is emitted
    /// and the next run starts with no wait. Before `start`, after `stop()` and while stopping it does nothing.
    ///
    /// The exact rule: a nudge belongs to the phase it arrives in, a run (from its start until the loop has dealt with
    /// its end) or a wait (from `.reconnecting` until the next run starts), and each phase takes one nudge. A run's
    /// nudge cancels the run and means no wait follows it, even when the run was already returning; a wait's nudge
    /// ends the wait, even when it was already ending. A second nudge in the same phase is absorbed, and no nudge
    /// carries over into the next phase, so it never cancels a later run or shortens a later wait. A nudge between
    /// `start` and the first run is absorbed too: that run is starting anyway.
    public func nudge() {
        let task = shared.withLock { $0.nudge() }
        // Cancelled outside the lock: cancelling runs the task's cancellation handlers right here.
        task?.cancel()
    }

    /// Stops the loop and returns once it has ended.
    ///
    /// It cancels the run, its stable timer and any wait, emits `.stopped` and finishes every state stream. It is
    /// idempotent: a second `stop()` (at the same time or later) returns once the loop has ended and changes nothing.
    /// On a supervisor that never started it emits `.stopped` and finishes the streams. A `start` afterwards begins a
    /// new life.
    public func stop() async {
        let (loop, phaseTask, life) = shared.withLock { state in
            if state.loop != nil { state.stopping = true }
            return (state.loop, state.phaseTask, state.life)
        }
        phaseTask?.cancel()
        await loop?.value
        let finished = shared.withLock { state -> [AsyncStream<ConnectionState>.Continuation] in
            // A `start` after another `stop` finished this life began a new one, which is not this call's to end.
            guard state.life == life else { return [] }
            state.loop = nil
            state.stopping = false
            state.enter(.idle, task: nil)
            state.emit(.stopped)
            defer { state.observers = [:] }
            return Array(state.observers.values)
        }
        // Finished outside the lock: `finish` runs each stream's `onTermination`, which takes the lock.
        for observer in finished {
            observer.finish()
        }
    }

    /// The attempt count now (for tests that wait for the stable timer, whose effect shows only in the next failure).
    var attempt: Int {
        shared.withLock { $0.attempt }
    }

    /// How many state streams are open (for tests).
    var observerCount: Int {
        shared.withLock { $0.observers.count }
    }

    // MARK: The loop

    private func makeLoop(_ run: @escaping Run) -> Task<Void, Never> {
        if #available(macOS 26.0, iOS 26.0, *) {
            return Task(name: name) { await self.loop(run) }
        }
        return Task { await self.loop(run) }
    }

    private func loop(_ run: @escaping Run) async {
        while let pass = beginRun(run) {
            await pass.value
            switch shared.withLock({ $0.runEnded() }) {
            case .stop:
                return
            case .retry:
                continue
            case .wait(let attempt):
                // The jitter is the caller's closure: it is asked outside the lock.
                let delay = backoff.delay(attempt: attempt - 1, jitter: jitter())
                guard let wait = beginWait(delay) else { continue }
                await wait.value
            }
        }
    }

    /// Starts the next run, or returns nil if the supervisor is stopping.
    private func beginRun(_ run: @escaping Run) -> Task<Void, Never>? {
        shared.withLock { state in
            guard !state.stopping else { return nil }
            state.lastRunID += 1
            let id = state.lastRunID
            state.emit(.connecting)
            state.runIsLive = true
            let task = Task { await self.perform(run, id: id) }
            state.enter(.run(id), task: task)
            return task
        }
    }

    /// Starts the backoff wait, or returns nil if there is nothing to wait for: the supervisor is stopping (the loop
    /// then ends at its next step) or the wait was nudged before it began.
    private func beginWait(_ delay: Duration) -> Task<Void, Never>? {
        shared.withLock { state in
            guard !state.stopping, !state.phaseNudged else { return nil }
            let sleep = self.sleep
            let task = Task { _ = try? await sleep(delay) }
            state.phaseTask = task
            return task
        }
    }

    /// Runs `run` once, with its stable timer beside it. The timer starts at the run's first effective
    /// `markConnected` and sets the attempt count back to 0 if the run is still up when it ends; when the run ends
    /// first, the timer is cancelled and awaited before this returns.
    private func perform(_ run: Run, id: UInt64) async {
        let (connected, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let markConnected: @Sendable () -> Void = { [weak self] in
            guard let self, shared.withLock({ $0.markConnected(run: id) }) else { return }
            signal.yield()
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [sleep, stableAfter] in
                var iterator = connected.makeAsyncIterator()
                guard await iterator.next() != nil else { return }
                guard (try? await sleep(stableAfter)) != nil else { return }
                self.shared.withLock { $0.runWasStable(id) }
            }
            do {
                try await run(markConnected)
            } catch {
                // A throw, a return and a cancellation all mean the same: the connection has ended.
            }
            shared.withLock { state in
                if state.phase == .run(id) { state.runIsLive = false }
            }
            signal.finish()
            group.cancelAll()
        }
    }
}

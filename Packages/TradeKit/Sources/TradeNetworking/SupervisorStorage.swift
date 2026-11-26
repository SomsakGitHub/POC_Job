/// The state of a connection that a `ConnectionSupervisor` keeps alive, as an observer of its `states` sees it.
public enum ConnectionState: Sendable, Equatable {
    /// A run has started and has not proven its connection yet.
    case connecting
    /// The run has called its `markConnected`: the connection is up.
    case connected
    /// The connection ended and the next one is about to be tried. `attempt` counts the connections that ended since
    /// the last one that stayed up long enough, from 1.
    case reconnecting(attempt: Int)
    /// `stop()` has ended the supervisor; nothing more happens until the next `start`.
    case stopped
}

/// Everything a `ConnectionSupervisor` knows, behind its one lock.
///
/// The loop moves through phases: a run (from the moment it is started until the loop has dealt with its end) and a
/// wait (from the moment `.reconnecting` is emitted until the next run starts). A phase can be nudged once; what a
/// nudge does is decided by the phase it lands in, and the next phase always starts un-nudged.
struct SupervisorStorage {
    enum Phase: Equatable {
        /// No loop, or a loop that has not started its first run yet.
        case idle
        /// The run with this number.
        case run(UInt64)
        /// The time between two runs, the backoff wait included.
        case wait
    }

    /// What the loop does after a run has ended.
    enum AfterRun {
        /// The supervisor is stopping: leave the loop.
        case stop
        /// The run was nudged: start the next one at once.
        case retry
        /// Wait before retry number `attempt` (1-based).
        case wait(attempt: Int)
    }

    /// The newest state; nil before the first `start` or `stop`.
    private(set) var current: ConnectionState?
    var observers: [UInt64: AsyncStream<ConnectionState>.Continuation] = [:]
    var nextObserverID: UInt64 = 0

    /// The loop task, from `start` until `stop` has seen it end.
    var loop: Task<Void, Never>?
    /// Counts the `start`s, so that a `stop` can tell its own loop from one a later `start` began.
    var life: UInt64 = 0
    var stopping = false
    /// The connections that ended since the last stable one; the last `.reconnecting` carries it.
    var attempt = 0

    private(set) var phase: Phase = .idle
    /// What cancelling the phase means: the run's task, or the backoff wait's once it has started.
    var phaseTask: Task<Void, Never>?
    /// Whether the phase has been nudged.
    var phaseNudged = false
    /// Whether the current run's closure is still running (it is false from the instant it returned or threw).
    var runIsLive = false
    /// The run that has called `markConnected`.
    var connectedRun: UInt64?
    var lastRunID: UInt64 = 0

    /// Makes `state` the current one and tells every observer, unless it already is the current one.
    ///
    /// Observers are told under the lock, so they see the changes in the order they were made; `yield` never calls back
    /// into the supervisor (only `finish` and a consumer's cancellation run `onTermination`).
    mutating func emit(_ state: ConnectionState) {
        guard state != current else { return }
        current = state
        for observer in observers.values {
            observer.yield(state)
        }
    }

    /// Starts `phase`, un-nudged, cancelled through `task`.
    mutating func enter(_ phase: Phase, task: Task<Void, Never>?) {
        self.phase = phase
        phaseTask = task
        phaseNudged = false
    }

    /// Whether `markConnected` of run `id` takes effect: the run is the current one, still running, not nudged, the
    /// supervisor is not stopping and the run has not been marked before. If it does, `.connected` is emitted.
    mutating func markConnected(run id: UInt64) -> Bool {
        guard phase == .run(id), runIsLive, !stopping, !phaseNudged, connectedRun != id else { return false }
        connectedRun = id
        emit(.connected)
        return true
    }

    /// The stable timer of run `id` has run out: if the run is still up, the next failure is the first again.
    mutating func runWasStable(_ id: UInt64) {
        guard phase == .run(id), runIsLive, !stopping else { return }
        attempt = 0
    }

    /// The run's closure has returned or thrown. Ends the run phase and says what the loop does next, emitting
    /// `.reconnecting` unless the supervisor is stopping. A nudged run is followed by an already nudged wait, so a
    /// second nudge for the same end is absorbed.
    mutating func runEnded() -> AfterRun {
        let nudged = phaseNudged
        runIsLive = false
        guard !stopping else {
            enter(.idle, task: nil)
            return .stop
        }
        attempt += 1
        emit(.reconnecting(attempt: attempt))
        enter(.wait, task: nil)
        if nudged {
            phaseNudged = true
            return .retry
        }
        return .wait(attempt: attempt)
    }

    /// Marks the current phase as nudged and returns the task to cancel, if the phase has one. It does nothing when
    /// there is no loop, it is stopping, no phase has started yet, or this phase has been nudged already.
    mutating func nudge() -> Task<Void, Never>? {
        guard loop != nil, !stopping, phase != .idle, !phaseNudged else { return nil }
        phaseNudged = true
        return phaseTask
    }
}

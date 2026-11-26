import Testing
import TradeCore
// `@testable` only for `attempt` and `observerCount`, which let a test wait for a change that has no visible state.
@testable import TradeNetworking

/// The supervisor driven by a fake run and a fake `sleep`: every wait it makes is a `FakeSleeper` request that ends
/// when the test finishes it, so the tests never depend on how fast the machine is. Each step waits for the event that
/// proves the step before it happened (a state, a run, a sleep request); a broken supervisor makes a test hang, and the
/// time limit turns that into a failure.
@Suite(.timeLimit(.minutes(1)))
struct SupervisorTests {
    // MARK: Backoff

    /// Three failed runs wait 250 ms, 500 ms and 1 s at a jitter of 1.0, each through the injected `sleep`, with the
    /// 1-based attempt number in `.reconnecting`, and the jitter is asked for once per wait.
    @Test func retriesWithBackoffAfterFailure() async {
        let rig = SupervisorRig(jitter: 1.0)
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        var waits: [Duration] = []
        var seen: [ConnectionState] = []
        for _ in 0..<3 {
            seen += await states.take(1)
            let run = await runs.next()
            run?.fail()
            seen += await states.take(1)
            guard let wait = await sleeps.next() else { break }
            waits.append(wait.duration)
            wait.finish()
        }
        seen += await states.take(1)
        #expect(seen == [.connecting, .reconnecting(attempt: 1), .connecting, .reconnecting(attempt: 2),
                         .connecting, .reconnecting(attempt: 3), .connecting])
        #expect(waits == [.milliseconds(250), .milliseconds(500), .seconds(1)])
        #expect(rig.jitterCount == 3)
        await rig.supervisor.stop()
    }

    /// A jitter of 0.0 halves every wait: 125 ms, then 250 ms.
    @Test func jitterZeroHalvesTheWaits() async {
        let rig = SupervisorRig(jitter: 0.0)
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        var waits: [Duration] = []
        for _ in 0..<2 {
            await runs.next()?.fail()
            guard let wait = await sleeps.next() else { break }
            waits.append(wait.duration)
            wait.finish()
        }
        #expect(waits == [.milliseconds(125), .milliseconds(250)])
        await rig.supervisor.stop()
    }

    /// A run that returns and a run that throws both count as a connection that ended.
    @Test func aReturningRunAndAThrowingRunBothReconnect() async {
        let rig = SupervisorRig()
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        let first = await runs.next()
        first?.succeed()
        await sleeps.next()?.finish()
        let second = await runs.next()
        second?.fail()
        await sleeps.next()?.finish()
        let seen = await states.take(5)
        #expect(seen == [.connecting, .reconnecting(attempt: 1), .connecting, .reconnecting(attempt: 2), .connecting])
        #expect(first?.end == .returned)
        #expect(second?.end == .threw)
        await rig.supervisor.stop()
    }

    // MARK: The stable timer

    /// A run that stays connected for `stableAfter` (the stable timer's sleep, finished by the test) resets the count:
    /// the next failure is attempt 1 again and waits 250 ms.
    @Test func attemptResetsAfterStableRun() async {
        let rig = SupervisorRig()
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        await runs.next()?.fail()
        await sleeps.next()?.finish()
        let second = await runs.next()
        second?.markConnected()
        let stable = await sleeps.next()
        #expect(stable?.duration == SupervisorRig.stableAfter)
        let before = rig.supervisor.attempt
        stable?.finish()
        let reset = await rig.attemptBecomes(0)
        second?.fail()
        let wait = await sleeps.next()

        let seen = await states.take(5)
        #expect(before == 1)
        #expect(reset)
        #expect(seen == [.connecting, .reconnecting(attempt: 1), .connecting, .connected, .reconnecting(attempt: 1)])
        #expect(wait?.duration == .milliseconds(250))
        await rig.supervisor.stop()
    }

    /// A run that ends before `stableAfter` cancels its stable timer and the count goes on: attempt 2, 500 ms.
    @Test func aRunThatEndsEarlyCancelsItsStableTimer() async {
        let rig = SupervisorRig()
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        await runs.next()?.fail()
        await sleeps.next()?.finish()
        let second = await runs.next()
        second?.markConnected()
        let stable = await sleeps.next()
        second?.fail()
        let wait = await sleeps.next()

        let seen = await states.take(5)
        #expect(seen == [.connecting, .reconnecting(attempt: 1), .connecting, .connected, .reconnecting(attempt: 2)])
        #expect(stable?.duration == SupervisorRig.stableAfter)
        #expect(stable.map { rig.sleeper.outcome(of: $0) } == .cancelled)
        #expect(wait?.duration == .milliseconds(500))
        await rig.supervisor.stop()
    }

    /// `markConnected` takes effect once per run: a second call starts no second stable timer, and a call after the
    /// run was nudged does nothing. The sleep after the first stable timer is the backoff wait of the next failure.
    @Test func markConnectedTakesEffectOncePerRun() async {
        let rig = SupervisorRig(holdsAfterCancel: true)
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        let first = await runs.next()
        first?.markConnected()
        first?.markConnected()
        let stable = await sleeps.next()
        first?.fail()
        let wait = await sleeps.next()
        let seen = await states.take(3)
        #expect(seen == [.connecting, .connected, .reconnecting(attempt: 1)])
        #expect(stable?.duration == SupervisorRig.stableAfter)
        #expect(wait?.duration == .milliseconds(250))
        #expect(rig.sleeper.callCount == 2)
        wait?.finish()

        // A run that calls `markConnected` once it was nudged (while it winds down) is not connected: it is on its
        // way out. The next run then connects as usual.
        let second = await runs.next()
        rig.supervisor.nudge()
        await second?.cancelled()
        second?.release(connectingFirst: true)
        let third = await runs.next()
        third?.markConnected()
        let after = await states.take(4)
        #expect(after == [.connecting, .reconnecting(attempt: 2), .connecting, .connected])
        #expect(second?.hasReturned == true)

        // The third run holds after its cancellation too: `stop` waits for it to be let go.
        let supervisor = rig.supervisor
        async let stopped: Void = supervisor.stop()
        await third?.cancelled()
        third?.release()
        await stopped
    }

    // MARK: Nudge

    /// A nudge during a backoff wait cancels the wait (the injected `sleep` is cancelled) and the next run starts at
    /// once.
    @Test func nudgeSkipsBackoffWait() async {
        let rig = SupervisorRig()
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        await runs.next()?.fail()
        let wait = await sleeps.next()
        rig.supervisor.nudge()
        let second = await runs.next()

        let seen = await states.take(3)
        #expect(seen == [.connecting, .reconnecting(attempt: 1), .connecting])
        #expect(wait.map { rig.sleeper.outcome(of: $0) } == .cancelled)
        #expect(second != nil)
        await rig.supervisor.stop()
    }

    /// A nudge while connected cancels the run and goes straight to the next one with no wait: the next sleep the
    /// supervisor asks for is the wait after the second run (attempt 2, 500 ms).
    @Test func nudgeWhileConnectedRestartsRun() async {
        let rig = SupervisorRig()
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        let first = await runs.next()
        first?.markConnected()
        let stable = await sleeps.next()
        rig.supervisor.nudge()
        let second = await runs.next()
        second?.fail()
        let wait = await sleeps.next()

        let seen = await states.take(5)
        #expect(seen == [.connecting, .connected, .reconnecting(attempt: 1), .connecting, .reconnecting(attempt: 2)])
        #expect(first?.end == .cancelled)
        #expect(stable.map { rig.sleeper.outcome(of: $0) } == .cancelled)
        #expect(wait?.duration == .milliseconds(500))
        await rig.supervisor.stop()
    }

    /// A nudge while the run is still connecting restarts it the same way.
    @Test func nudgeWhileConnectingRestartsRun() async {
        let rig = SupervisorRig()
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        rig.start()

        let first = await runs.next()
        rig.supervisor.nudge()
        let second = await runs.next()

        let seen = await states.take(3)
        #expect(seen == [.connecting, .reconnecting(attempt: 1), .connecting])
        #expect(first?.end == .cancelled)
        #expect(second != nil)
        #expect(rig.sleeper.callCount == 0)
        await rig.supervisor.stop()
    }

    /// Two nudges in a row restart once: the second run is not cancelled, it ends when the test ends it.
    @Test func twoNudgesInARowRestartOnce() async {
        let rig = SupervisorRig()
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        rig.start()

        let first = await runs.next()
        first?.markConnected()
        let up = await states.take(2)
        rig.supervisor.nudge()
        rig.supervisor.nudge()
        let second = await runs.next()
        second?.markConnected()
        let connected = up + (await states.take(3))
        second?.fail()
        let ended = await states.take(1)

        #expect(connected == [.connecting, .connected, .reconnecting(attempt: 1), .connecting, .connected])
        #expect(ended == [.reconnecting(attempt: 2)])
        #expect(first?.end == .cancelled)
        #expect(second?.end == .threw)
        #expect(rig.runner.callCount == 2)
        await rig.supervisor.stop()
    }

    /// A nudge that arrives as the run is ending (from inside the run, just before it returns) is served by skipping
    /// the wait after it, and it is gone after that: the next run is not cancelled and the wait after it is a real
    /// one that the test has to finish.
    @Test func aNudgeAsTheRunEndsSkipsOnlyThatWait() async {
        let rig = SupervisorRig()
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        let supervisor = rig.supervisor
        await runs.next()?.succeed(then: { supervisor.nudge() })
        let second = await runs.next()
        second?.markConnected()
        let stable = await sleeps.next()
        second?.fail()
        let wait = await sleeps.next()

        let seen = await states.take(5)
        #expect(seen == [.connecting, .reconnecting(attempt: 1), .connecting, .connected, .reconnecting(attempt: 2)])
        #expect(stable?.duration == SupervisorRig.stableAfter)
        #expect(second?.end == .threw)
        #expect(wait?.duration == .milliseconds(500))
        #expect(wait.map { rig.sleeper.outcome(of: $0) } == .some(nil))
        await rig.supervisor.stop()
    }

    /// A nudge that arrives after `.reconnecting` but before the backoff wait has begun (from inside the jitter) is
    /// not lost: the wait never starts and the next run follows at once. The wait after that run is a real one.
    @Test func aNudgeBeforeTheWaitBeginsSkipsIt() async {
        let rig = SupervisorRig()
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        let supervisor = rig.supervisor
        rig.onNextJitter { supervisor.nudge() }
        await runs.next()?.fail()
        let second = await runs.next()
        #expect(rig.sleeper.callCount == 0)
        second?.fail()
        let wait = await sleeps.next()

        let seen = await states.take(4)
        #expect(seen == [.connecting, .reconnecting(attempt: 1), .connecting, .reconnecting(attempt: 2)])
        #expect(wait?.duration == .milliseconds(500))
        #expect(rig.jitterCount == 2)
        await rig.supervisor.stop()
    }

    /// A nudge that arrives as a wait is ending (from inside the sleep, just before it returns) ends that wait and
    /// nothing else: the run that follows is not cancelled.
    @Test func aNudgeAsTheWaitEndsDoesNotReachTheNextRun() async {
        let rig = SupervisorRig()
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        let supervisor = rig.supervisor
        await runs.next()?.fail()
        await sleeps.next()?.finish(then: { supervisor.nudge() })
        let second = await runs.next()
        second?.markConnected()
        let connected = await states.take(4)
        second?.fail()
        let ended = await states.take(1)

        #expect(connected == [.connecting, .reconnecting(attempt: 1), .connecting, .connected])
        #expect(ended == [.reconnecting(attempt: 2)])
        #expect(second?.end == .threw)
        await rig.supervisor.stop()
    }

    /// A nudge before `start` and one after `stop` do nothing: the runs that follow end only when the test ends them.
    /// The positive control: a nudge while the loop runs does cancel the run.
    @Test func nudgeWithoutALoopDoesNothing() async {
        let rig = SupervisorRig()
        rig.supervisor.nudge()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        let first = await runs.next()
        first?.fail()
        await sleeps.next()?.finish()
        #expect(first?.end == .threw)

        let second = await runs.next()
        rig.supervisor.nudge()
        await second?.cancelled()
        #expect(second?.end == .cancelled)
        // The nudged run is replaced at once; taking its replacement here means the next run taken below is the
        // second life's and not this one, which `stop` cancels.
        let replacement = await runs.next()
        #expect(replacement != nil)

        await rig.supervisor.stop()
        rig.supervisor.nudge()
        rig.start()
        var states = rig.supervisor.states.makeAsyncIterator()
        let third = await runs.next()
        third?.markConnected()
        let seen = await states.take(2)
        third?.fail()
        let ended = await states.take(1)
        #expect(seen == [.connecting, .connected])
        #expect(ended == [.reconnecting(attempt: 1)])
        #expect(third?.end == .threw)
        await rig.supervisor.stop()
    }

    // MARK: Stop

    /// `stop()` cancels the run, emits `.stopped`, finishes the stream and returns only after the run has returned,
    /// even when the run takes a moment to wind down after its cancellation.
    @Test func stopCancelsRun() async {
        let rig = SupervisorRig(holdsAfterCancel: true)
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        let run = await runs.next()
        run?.markConnected()
        let stable = await sleeps.next()
        let supervisor = rig.supervisor
        async let stopped: Void = supervisor.stop()
        await run?.cancelled()
        let returnedBeforeRelease = run?.hasReturned
        run?.release()
        await stopped

        let seen = await states.take(4)
        #expect(seen == [.connecting, .connected, .stopped])
        #expect(returnedBeforeRelease == false)
        #expect(run?.end == .cancelled)
        #expect(run?.hasReturned == true)
        #expect(stable.map { rig.sleeper.outcome(of: $0) } == .cancelled)
    }

    /// `stop()` during a backoff wait cancels the wait and starts no new run.
    @Test func stopDuringAWaitCancelsIt() async {
        let rig = SupervisorRig()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        await runs.next()?.fail()
        let wait = await sleeps.next()
        await rig.supervisor.stop()
        #expect(wait.map { rig.sleeper.outcome(of: $0) } == .cancelled)
        #expect(rig.runner.callCount == 1)
    }

    /// `stop()` twice is the same as once; a stream asked for after `stop` yields `.stopped` and finishes.
    @Test func stopIsIdempotent() async {
        let rig = SupervisorRig()
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        rig.start()
        _ = await runs.next()

        await rig.supervisor.stop()
        await rig.supervisor.stop()
        let seen = await states.take(3)
        var late = rig.supervisor.states.makeAsyncIterator()
        let lateSeen = await late.take(3)
        #expect(seen == [.connecting, .stopped])
        #expect(lateSeen == [.stopped])
    }

    /// Before `start` a stream yields nothing; `stop()` on a supervisor that never started emits `.stopped` and
    /// finishes it.
    @Test func stopBeforeStartOnlyStops() async {
        let rig = SupervisorRig()
        var states = rig.supervisor.states.makeAsyncIterator()
        await rig.supervisor.stop()
        let seen = await states.take(3)
        #expect(seen == [.stopped])
        #expect(rig.runner.callCount == 0)
    }

    // MARK: Start

    /// A second `start` while the loop runs is ignored: its run is never called, and the first one's loop goes on.
    @Test func startTwiceIsIgnored() async {
        let rig = SupervisorRig()
        let other = FakeRunner()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()
        rig.supervisor.start { try await other.run($0) }

        await runs.next()?.fail()
        await sleeps.next()?.finish()
        let second = await runs.next()
        #expect(second != nil)
        #expect(rig.runner.callCount == 2)
        #expect(other.callCount == 0)
        await rig.supervisor.stop()
    }

    /// `start` after `stop` begins a fresh life: `.connecting` first, the attempt count from 0 (the first wait is
    /// 250 ms again), and the first life's stable timer, cancelled by `stop`, resets nothing.
    @Test func startAfterStopBeginsAFreshLife() async {
        let rig = SupervisorRig()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        await runs.next()?.fail()
        await sleeps.next()?.finish()
        await runs.next()?.fail()
        await sleeps.next()?.finish()
        let old = await runs.next()
        old?.markConnected()
        let oldStable = await sleeps.next()
        await rig.supervisor.stop()
        #expect(oldStable.map { rig.sleeper.outcome(of: $0) } == .cancelled)

        rig.start()
        var states = rig.supervisor.states.makeAsyncIterator()
        let fresh = await runs.next()
        fresh?.fail()
        let wait = await sleeps.next()
        let seen = await states.take(2)
        #expect(seen == [.connecting, .reconnecting(attempt: 1)])
        #expect(wait?.duration == .milliseconds(250))

        wait?.finish()
        let next = await runs.next()
        next?.markConnected()
        let connected = await states.take(2)
        #expect(connected == [.connecting, .connected])
        await rig.supervisor.stop()
    }

    // MARK: The state stream

    /// The whole sequence of one failure and recovery.
    @Test func emitsStateSequence() async {
        let rig = SupervisorRig()
        var states = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        var sleeps = rig.sleeper.requests.makeAsyncIterator()
        rig.start()

        let first = await runs.next()
        first?.markConnected()
        _ = await sleeps.next()  // the stable timer
        first?.fail()
        await sleeps.next()?.finish()
        await runs.next()?.markConnected()

        let seen = await states.take(5)
        #expect(seen == [.connecting, .connected, .reconnecting(attempt: 1), .connecting, .connected])
        await rig.supervisor.stop()
    }

    /// A stream asked for later starts with the current state and then sees the same changes as the first.
    @Test func aSecondObserverStartsWithTheCurrentState() async {
        let rig = SupervisorRig()
        var first = rig.supervisor.states.makeAsyncIterator()
        var runs = rig.runner.runs.makeAsyncIterator()
        rig.start()

        let run = await runs.next()
        run?.markConnected()
        let early = await first.take(2)
        var second = rig.supervisor.states.makeAsyncIterator()
        run?.fail()
        let firstLater = await first.take(1)
        let secondSeen = await second.take(2)

        #expect(early == [.connecting, .connected])
        #expect(firstLater == [.reconnecting(attempt: 1)])
        #expect(secondSeen == [.connected, .reconnecting(attempt: 1)])
        await rig.supervisor.stop()
    }

    /// A stream that `stop` finished stays finished after a later `start`, and a new stream then replays the state of
    /// the new life.
    @Test func aStoppedStreamStaysFinished() async {
        let rig = SupervisorRig()
        var runs = rig.runner.runs.makeAsyncIterator()
        rig.start()
        _ = await runs.next()
        var old = rig.supervisor.states.makeAsyncIterator()
        await rig.supervisor.stop()
        rig.start()
        _ = await runs.next()

        let oldSeen = await old.take(3)
        var fresh = rig.supervisor.states.makeAsyncIterator()
        let freshSeen = await fresh.take(1)
        #expect(oldSeen == [.connecting, .stopped])
        #expect(freshSeen == [.connecting])
        await rig.supervisor.stop()
    }

    /// An observer whose stream is dropped is removed from the supervisor's list; one that is kept stays.
    @Test func aDroppedObserverIsRemoved() async {
        let rig = SupervisorRig()
        let kept = rig.supervisor.states
        do {
            let dropped = rig.supervisor.states
            _ = dropped
        }
        let count = rig.supervisor.observerCount
        #expect(count == 1)
        _ = kept
    }
}

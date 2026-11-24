import Observation
import QuartzCore
import Testing
import TradeNetworking
@testable import TradePulse

/// The display link behind the pump and what a view can observe of it. Everything here is synchronous: the main run
/// loop never gets a turn between a `start()` and the end of the test, so the real link cannot fire in the middle of
/// one and add a step of its own.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FramePumpLinkTests {
    // MARK: The link

    @Test func startMakesOneLinkAndStopRemovesIt() {
        let rig = PumpRig()
        let pump = rig.pump
        #expect(!pump.isRunning)
        #expect(pump.displayLink == nil)

        pump.start()
        let first = pump.displayLink
        #expect(pump.isRunning)
        #expect(first != nil)
        #expect(first?.isPaused == false)

        // A second start changes nothing: there is never more than one link.
        pump.start()
        #expect(pump.displayLink === first)

        pump.stop()
        #expect(!pump.isRunning)
        #expect(pump.displayLink == nil)
        // Stopping twice is harmless.
        pump.stop()
        #expect(!pump.isRunning)

        pump.start()
        #expect(pump.isRunning)
        #expect(pump.displayLink !== first)
        pump.stop()
    }

    @Test func stopInvalidatesTheLinkSoNothingHoldsIt() {
        weak var link: CADisplayLink?
        var made = false
        autoreleasepool {
            let rig = PumpRig()
            rig.pump.start()
            link = rig.pump.displayLink
            made = link != nil
            rig.pump.stop()
        }
        #expect(made)
        // An invalidated link has left the run loop, which was the only thing that held it.
        #expect(link == nil)
    }

    @Test func aStartedLinkIsHeldByTheRunLoopAndNotByThePump() {
        weak var link: CADisplayLink?
        autoreleasepool {
            let rig = PumpRig()
            rig.pump.start()
            link = rig.pump.displayLink
            // The pump goes away at the end of this block, without a `stop()`.
        }
        let survivor = link
        #expect(survivor != nil)
        survivor?.invalidate()
    }

    @Test func aRunningLinkDoesNotKeepItsPumpAlive() {
        weak var pump: FramePump?
        var link: CADisplayLink?
        autoreleasepool {
            let rig = PumpRig()
            rig.pump.start()
            pump = rig.pump
            link = rig.pump.displayLink
        }
        #expect(link != nil)
        // The run loop holds the link and the link holds its target, which must not hold the pump.
        #expect(pump == nil)
        link?.invalidate()
    }

    @Test func theLinkTargetStepsAPumpThatIsStillThere() {
        let rig = PumpRig()
        let target = FrameLinkTarget(pump: rig.pump)
        rig.apply(seq: 1)
        var invalidated = false
        target.handle(timestamp: 1.0, targetTimestamp: 1.016, duration: 0.016, invalidate: { invalidated = true })
        #expect(rig.pump.tick == 1)
        #expect(!invalidated)

        rig.apply(seq: 2)
        target.handle(timestamp: 1.016, targetTimestamp: 1.032, duration: 0.016, invalidate: { invalidated = true })
        #expect(rig.pump.tick == 2)
        #expect(rig.pump.frames == 1)
        #expect(!invalidated)
    }

    @Test func theLinkTargetPassesTheThreeNumbersOnInTheirOwnPlaces() {
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0)
        let target = FrameLinkTarget(pump: rig.pump)
        rig.apply(seq: 1, sendNs: 4_990_000_000)
        // Due 20 ms from now, on a display of 10 ms frames: the second frame is 25 ms after the first.
        target.handle(timestamp: 100.0, targetTimestamp: 100.020, duration: 0.010, invalidate: {})
        target.handle(timestamp: 100.025, targetTimestamp: 100.045, duration: 0.010, invalidate: {})
        let expected: Int64 = 5_000_000_000 + 20_000_000 - 4_990_000_000
        #expect(rig.latency.summary(.tickToRender) == summary(of: [expected]))
        #expect(rig.pump.frames == 1)
        #expect(rig.pump.hitches == 1)
    }

    @Test func theLinkTargetEndsTheLinkOnceThePumpIsGone() {
        let target = orphanedTarget()
        var invalidated = 0
        target.handle(timestamp: 1.0, targetTimestamp: 1.016, duration: 0.016, invalidate: { invalidated += 1 })
        #expect(invalidated == 1)
    }

    /// A target whose pump has already been released.
    private func orphanedTarget() -> FrameLinkTarget {
        let rig = PumpRig()
        return FrameLinkTarget(pump: rig.pump)
    }

    // MARK: A link that no run loop drives

    @Test func startAddsOneLinkToTheMainRunLoopInTheCommonModes() throws {
        let links = StubLinks()
        let rig = PumpRig(makeLink: { links.make($0, $1) })
        #expect(links.made.isEmpty)

        rig.pump.start()
        let link = try #require(links.made.first)
        #expect(links.made.count == 1)
        #expect(rig.pump.displayLink === link)
        #expect(link.registrations.count == 1)
        // The common modes include the one a scrolling list runs in, where the link has to keep firing.
        #expect(link.registrations.first?.loop === RunLoop.main)
        #expect(link.registrations.first?.mode == RunLoop.Mode.common)
        #expect(link.invalidations == 0)

        // A start while the link runs asks for no second link.
        rig.pump.start()
        #expect(links.made.count == 1)
        #expect(link.registrations.count == 1)

        // Stopping ends the link once, however often it is asked.
        rig.pump.stop()
        rig.pump.stop()
        #expect(link.invalidations == 1)
        #expect(rig.pump.displayLink == nil)
    }

    @Test func aFiredLinkGivesItsThreeTimesToTheStepEachInItsOwnPlace() throws {
        let links = StubLinks()
        let rig = PumpRig(nowNs: 5_000_000_000, mediaNow: 100.0, makeLink: { links.make($0, $1) })
        rig.pump.start()
        let request = try #require(links.requests.first)
        rig.apply(seq: 1, sendNs: 4_990_000_000)

        // Due 20 ms from now, on a display of 10 ms frames: the second frame is 25 ms after the first. The link is
        // fired by the selector it was made for, as the display would.
        let first = StubLink(timestamp: 100.0, targetTimestamp: 100.020, duration: 0.010)
        let second = StubLink(timestamp: 100.025, targetTimestamp: 100.045, duration: 0.010)
        _ = request.target.perform(request.selector, with: first)
        _ = request.target.perform(request.selector, with: second)

        let expected: Int64 = 5_000_000_000 + 20_000_000 - 4_990_000_000
        #expect(rig.latency.summary(.tickToRender) == summary(of: [expected]))
        #expect(rig.pump.tick == 1)
        #expect(rig.pump.frames == 1)
        #expect(rig.pump.hitches == 1)
        // The pump was there for both frames, so neither link was ended.
        #expect(first.invalidations == 0)
        #expect(second.invalidations == 0)
        rig.pump.stop()
    }

    @Test func aLinkThatFiresAfterItsPumpIsGoneIsEndedThroughTheLinkItself() throws {
        let links = StubLinks()
        weak var gone: FramePump?
        do {
            let rig = PumpRig(makeLink: { links.make($0, $1) })
            rig.pump.start()
            gone = rig.pump
        }
        #expect(gone == nil)

        let request = try #require(links.requests.first)
        let fired = StubLink(timestamp: 1.0, targetTimestamp: 1.016, duration: 0.016)
        _ = request.target.perform(request.selector, with: fired)
        #expect(fired.invalidations == 1)
    }

    // MARK: Observation

    @Test func aViewThatReadsTheTickIsNotInvalidatedByTheFrameCounters() {
        let rig = PumpRig()
        let changed = Flag()
        withObservationTracking {
            _ = rig.pump.tick
        } onChange: {
            changed.set()
        }
        // The counters move with every frame, and nothing was applied: the tick did not change.
        rig.step(at: 10.0)
        rig.step(at: 10.016)
        rig.step(at: 10.100)
        #expect(rig.pump.frames == 2)
        #expect(rig.pump.hitches == 1)
        #expect(!changed.isSet)

        rig.apply(seq: 1)
        rig.step(at: 10.116)
        #expect(changed.isSet)
    }

    @Test func theFrameAndHitchCountersCanBeObserved() {
        let rig = PumpRig()
        let framesChanged = Flag()
        let hitchesChanged = Flag()
        withObservationTracking {
            _ = rig.pump.frames
        } onChange: {
            framesChanged.set()
        }
        withObservationTracking {
            _ = rig.pump.hitches
        } onChange: {
            hitchesChanged.set()
        }
        // The first step has no interval and moves nothing.
        rig.step(at: 10.0)
        #expect(!framesChanged.isSet)
        #expect(!hitchesChanged.isSet)

        // A frame of the expected length is a frame and not a hitch.
        rig.step(at: 10.016)
        #expect(framesChanged.isSet)
        #expect(!hitchesChanged.isSet)

        rig.pump.step(timestamp: 10.100, targetTimestamp: 10.116, duration: 0.016)
        #expect(hitchesChanged.isSet)
    }

    @Test func aCounterThatDidNotChangeIsNotPublishedAgain() {
        let rig = PumpRig()
        rig.step(at: 10.0)
        rig.step(at: 10.016)
        let changed = Flag()
        withObservationTracking {
            _ = rig.pump.hitches
        } onChange: {
            changed.set()
        }
        // Frames pass without a hitch, so the hitch counter is never written. The pump writes a counter only when it
        // moved, and the Observation macro of this toolchain also drops a write of an equal value by itself; the test
        // holds the pump to what a view relies on, whichever of the two does it.
        rig.step(at: 10.032)
        rig.step(at: 10.048)
        #expect(rig.pump.frames == 3)
        #expect(!changed.isSet)
    }

    @Test func theLinkAndTheDrawCostAreNotPartOfWhatAViewObserves() {
        let rig = PumpRig()
        let changed = Flag()
        withObservationTracking {
            _ = rig.pump.isRunning
            _ = rig.pump.drawCost
            _ = rig.pump.displayLink
        } onChange: {
            changed.set()
        }
        rig.pump.start()
        rig.pump.notifyRendered(drawNs: 1_000_000)
        rig.pump.stop()
        #expect(!changed.isSet)
    }
}

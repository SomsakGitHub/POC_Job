import Contracts
import Synchronization
import Testing
import TradeCore
import TradeNetworking

// The latency samples the market state records. A sample is `(clientNs + offset) - serverSendNs`, with the offset
// being the server's clock minus the client's. A summary is compared with `summary(of:)`, the summary of a recorder
// that was fed exactly the expected samples, so that no test depends on how the recorder rounds what it holds.

/// A clock that notes, every time it is read, whether the update of the symbol it watches is already in the state.
private final class ClockProbe: Sendable {
    private struct Inner {
        var nowNs: Int64 = 0
        var state: MarketState?
        var visibleAtEachRead: [Bool] = []
    }

    private let inner = Mutex(Inner())

    func watch(_ state: MarketState, nowNs: Int64) {
        inner.withLock {
            $0.state = state
            $0.nowNs = nowNs
        }
    }

    func read() -> Int64 {
        let (state, nowNs) = inner.withLock { ($0.state, $0.nowNs) }
        let visible = state?.snapshot(1) != nil
        inner.withLock { $0.visibleAtEachRead.append(visible) }
        return nowNs
    }

    var visibleAtEachRead: [Bool] {
        inner.withLock { $0.visibleAtEachRead }
    }
}

extension MarketStateTests {
    // MARK: The formula

    @Test func tickToAppUsesOffset() {
        let rig = StateRig()
        rig.state.setClockOffset(200)
        rig.apply(symbolUpdate(seq: 1), sendNs: 1_000, receivedAtNs: 1_500)
        // (1_500 + 200) - 1_000
        #expect(rig.latency.summary(.tickToApp) == summary(of: [700]))
        #expect(rig.latency.summary(.tickToApp).clamped == 0)
    }

    @Test func theOffsetStartsAtZero() {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: 1), sendNs: 1_000, receivedAtNs: 1_500)
        #expect(rig.latency.summary(.tickToApp) == summary(of: [500]))
    }

    /// Each stage takes its own reading of the client clock and adds the offset in force to it.
    @Test func everyStageUsesTheSameFormulaOnItsOwnClockReading() {
        let rig = StateRig()
        rig.clock.set(140)
        rig.state.setClockOffset(10)
        rig.apply(symbolUpdate(seq: 1), sendNs: 100, receivedAtNs: 120)
        rig.state.markRendered(atNs: 150)
        #expect(rig.latency.summary(.tickToApp) == summary(of: [30]))
        #expect(rig.latency.summary(.tickToApplied) == summary(of: [50], metric: .tickToApplied))
        #expect(rig.latency.summary(.tickToRender) == summary(of: [60], metric: .tickToRender))
        for metric in [LatencyMetric.tickToApp, .tickToApplied, .tickToRender] {
            #expect(rig.latency.summary(metric).clamped == 0)
        }
        // The state records nothing that is not its own.
        for metric in [LatencyMetric.orderSubmitToAck, .orderServerProcessing, .orderSubmitToFill] {
            #expect(rig.count(metric) == 0)
        }
    }

    // MARK: The injected clock

    /// `tickToApplied` is read once per frame, from the injected clock, after the updates are in the state.
    @Test func tickToAppliedUsesTheInjectedClockAfterTheUpdatesAreApplied() {
        let probe = ClockProbe()
        let latency = LatencyRecorder()
        let state = MarketState(latency: latency, nowNs: { probe.read() })
        probe.watch(state, nowNs: 140)
        state.setClockOffset(10)
        #expect(probe.visibleAtEachRead == [])

        _ = state.apply(frame: marketFrame(sendNs: 100, updates: [symbolUpdate(seq: 1)]), receivedAtNs: 120)

        #expect(probe.visibleAtEachRead == [true])
        #expect(latency.summary(.tickToApplied) == summary(of: [50], metric: .tickToApplied))
        #expect(latency.summary(.tickToApp) == summary(of: [30]))
    }

    /// The clock is read only for a frame that records the sample: not for a heartbeat, an unstamped frame or a
    /// frame whose updates were all stale.
    @Test func theClockIsReadOnlyWhenASampleIsRecorded() {
        let probe = ClockProbe()
        let state = MarketState(latency: LatencyRecorder(), nowNs: { probe.read() })
        probe.watch(state, nowNs: 140)

        _ = state.apply(frame: marketFrame(sendNs: 100, updates: []), receivedAtNs: 120)
        _ = state.apply(frame: marketFrame(sendNs: 0, updates: [symbolUpdate(seq: 1)]), receivedAtNs: 120)
        #expect(probe.visibleAtEachRead == [])

        _ = state.apply(frame: marketFrame(sendNs: 100, updates: [symbolUpdate(seq: 2)]), receivedAtNs: 120)
        #expect(probe.visibleAtEachRead == [true])

        _ = state.apply(frame: marketFrame(sendNs: 100, updates: [symbolUpdate(seq: 2)]), receivedAtNs: 130)
        _ = state.apply(frame: marketFrame(sendNs: 100, updates: [symbolUpdate(seq: 1)]), receivedAtNs: 130)
        #expect(probe.visibleAtEachRead == [true])
    }

    // MARK: Once per frame

    /// A frame is one transport event, so two updates in it make one sample of each metric, not two.
    @Test func aFrameWithTwoUpdatesRecordsOneSamplePerMetric() {
        let rig = StateRig()
        rig.apply(symbolUpdate(symbol: 1, seq: 1), symbolUpdate(symbol: 2, seq: 1), sendNs: 100, receivedAtNs: 120)
        #expect(rig.count(.tickToApp) == 1)
        #expect(rig.count(.tickToApplied) == 1)
        #expect(rig.count(.tickToRender) == 0)
        rig.state.markRendered(atNs: 130)
        #expect(rig.count(.tickToRender) == 1)

        // A frame of three updates, one of them stale, still makes one sample of each.
        rig.apply(
            symbolUpdate(symbol: 1, seq: 1), symbolUpdate(symbol: 2, seq: 2), symbolUpdate(symbol: 3, seq: 1),
            sendNs: 200, receivedAtNs: 220
        )
        #expect(rig.count(.tickToApp) == 2)
        #expect(rig.count(.tickToApplied) == 2)
    }

    // MARK: Frames that record nothing

    @Test(arguments: [Int64(0), -1, .min])
    func anUnstampedFrameRecordsNoLatency(sendNs: Int64) {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: 1), sendNs: sendNs, receivedAtNs: 1_500)
        // The frame is applied all the same.
        #expect(rig.state.snapshot(1)?.seq == 1)
        #expect(rig.state.version == 1)
        #expect(rig.state.lastFrameAtNs == 1_500)
        // But it says when it was sent in no way that can be measured, and it leaves nothing to render.
        rig.state.markRendered(atNs: 2_000)
        for metric in LatencyMetric.allCases {
            #expect(rig.count(metric) == 0, "\(metric)")
        }

        // Positive control: the same frame, stamped, records.
        rig.apply(symbolUpdate(seq: 2), sendNs: 1_000, receivedAtNs: 1_600)
        rig.state.markRendered(atNs: 2_000)
        #expect(rig.count(.tickToApp) == 1)
        #expect(rig.count(.tickToApplied) == 1)
        #expect(rig.count(.tickToRender) == 1)
    }

    /// An unstamped frame neither sets a render stamp nor replaces the one that is waiting.
    @Test func anUnstampedFrameLeavesTheRenderStampAlone() {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: 1), sendNs: 0, receivedAtNs: 15)
        rig.state.markRendered(atNs: 50)
        #expect(rig.count(.tickToRender) == 0)

        rig.apply(symbolUpdate(seq: 2), sendNs: 10, receivedAtNs: 15)
        rig.apply(symbolUpdate(seq: 3), sendNs: 0, receivedAtNs: 25)
        rig.state.markRendered(atNs: 50)
        // The stamped frame is the one that was waiting: 50 - 10.
        #expect(rig.latency.summary(.tickToRender) == summary(of: [40], metric: .tickToRender))
    }

    // MARK: Clamping

    /// The state hands the raw sample to the recorder, which clamps it and counts it as clamped: a clock that is
    /// wrong by seconds shows as clamped samples, never as a negative or an absurd percentile.
    @Test func negativeLatencyIsClamped() {
        let rig = StateRig()
        rig.state.setClockOffset(-3_000_000_000)
        rig.apply(symbolUpdate(seq: 1), sendNs: 1_000, receivedAtNs: 1_500)
        rig.state.markRendered(atNs: 1_800)
        for metric in [LatencyMetric.tickToApp, .tickToApplied, .tickToRender] {
            let recorded = rig.latency.summary(metric)
            #expect(recorded.count == 1, "\(metric)")
            #expect(recorded.clamped == 1, "\(metric)")
            #expect(recorded.p50Ns == 0, "\(metric)")
            #expect(recorded.p99Ns == 0, "\(metric)")
        }

        // The other way round, a server clock far ahead gives a sample past the 10 s the recorder keeps.
        rig.state.setClockOffset(20_000_000_000)
        rig.apply(symbolUpdate(seq: 2), sendNs: 1_000, receivedAtNs: 1_500)
        let toApp = rig.latency.summary(.tickToApp)
        #expect(toApp.count == 2)
        #expect(toApp.clamped == 2)
        #expect(toApp.p99Ns == 10_000_000_000)

        // A sample in range is not counted as clamped.
        rig.state.setClockOffset(0)
        rig.apply(symbolUpdate(seq: 3), sendNs: 1_000, receivedAtNs: 1_050)
        let inRange = rig.latency.summary(.tickToApp)
        #expect(inRange.count == 3)
        #expect(inRange.clamped == 2)
    }

    /// Nothing overflows on the way to a sample, whatever the clocks and the offset say.
    @Test func latencyArithmeticNeverTraps() {
        let rig = StateRig()
        rig.clock.set(.max)
        rig.state.setClockOffset(.max)
        rig.apply(symbolUpdate(seq: 1), sendNs: 1, receivedAtNs: .max)
        rig.state.markRendered(atNs: .max)
        rig.state.setClockOffset(.min)
        rig.clock.set(.min)
        rig.apply(symbolUpdate(seq: 2), sendNs: .max, receivedAtNs: .min)
        rig.state.markRendered(atNs: .min)
        for metric in [LatencyMetric.tickToApp, .tickToApplied] {
            #expect(rig.latency.summary(metric).count == 2, "\(metric)")
            #expect(rig.latency.summary(metric).clamped == 2, "\(metric)")
        }
        #expect(rig.latency.summary(.tickToRender).count == 2)
        #expect(rig.latency.summary(.tickToRender).clamped == 2)
    }

    // MARK: Rendering

    @Test func markRenderedRecordsOncePerApply() {
        let rig = StateRig()
        rig.state.setClockOffset(10)
        rig.apply(symbolUpdate(seq: 1), sendNs: 100, receivedAtNs: 120)
        rig.state.markRendered(atNs: 150)
        // Nothing new was applied since, so there is nothing more to measure.
        rig.state.markRendered(atNs: 160)
        rig.state.markRendered(atNs: 170)
        #expect(rig.latency.summary(.tickToRender) == summary(of: [60], metric: .tickToRender))

        rig.apply(symbolUpdate(seq: 2), sendNs: 200, receivedAtNs: 220)
        rig.state.markRendered(atNs: 250)
        rig.state.markRendered(atNs: 260)
        #expect(rig.latency.summary(.tickToRender) == summary(of: [60, 60], metric: .tickToRender))
    }

    @Test func markRenderedWithNothingPendingRecordsNothing() {
        let rig = StateRig()
        rig.state.markRendered(atNs: 1_000)
        #expect(rig.count(.tickToRender) == 0)

        // A heartbeat leaves nothing to render either.
        rig.apply(sendNs: 100, receivedAtNs: 120)
        rig.state.markRendered(atNs: 150)
        #expect(rig.count(.tickToRender) == 0)

        // Positive control: an applied frame is measured.
        rig.apply(symbolUpdate(seq: 1), sendNs: 100, receivedAtNs: 120)
        rig.state.markRendered(atNs: 150)
        #expect(rig.count(.tickToRender) == 1)

        // A frame whose updates were all stale applied nothing, so it leaves nothing to render.
        rig.apply(symbolUpdate(seq: 1), sendNs: 200, receivedAtNs: 220)
        rig.state.markRendered(atNs: 250)
        #expect(rig.count(.tickToRender) == 1)
    }

    /// While several applied frames wait for the next draw, the OLDEST is the one measured: it is the one that has
    /// waited longest, and one draw shows them all.
    @Test func markRenderedMeasuresTheOldestPendingFrame() {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: 1), sendNs: 10, receivedAtNs: 15)
        rig.apply(symbolUpdate(seq: 2), sendNs: 30, receivedAtNs: 35)
        rig.state.markRendered(atNs: 50)
        // 50 - 10; the newer frame would have made it 20.
        #expect(rig.latency.summary(.tickToRender) == summary(of: [40], metric: .tickToRender))

        // The newer frame was forgotten with the draw, so the next draw has nothing, and the next frame starts over.
        rig.state.markRendered(atNs: 60)
        #expect(rig.count(.tickToRender) == 1)
        rig.apply(symbolUpdate(seq: 3), sendNs: 40, receivedAtNs: 45)
        rig.state.markRendered(atNs: 70)
        #expect(rig.latency.summary(.tickToRender) == summary(of: [40, 30], metric: .tickToRender))
    }

    /// The offset is the one in force when the frame is drawn, not the one when it was applied.
    @Test func markRenderedUsesTheOffsetInForceAtThatMoment() {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: 1), sendNs: 5, receivedAtNs: 10)
        rig.state.setClockOffset(10)
        rig.state.markRendered(atNs: 30)
        // 30 + 10 - 5; the offset of the apply, which was 0, would have made it 25.
        #expect(rig.latency.summary(.tickToRender) == summary(of: [35], metric: .tickToRender))
    }

    /// A frame applied while nothing was drawing is dropped, unmeasured, and the market it changed stays changed.
    @Test func discardPendingRenderLeavesNothingToMeasureAndTheVersionAsItWas() {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: 1), sendNs: 100, receivedAtNs: 120)
        let version = rig.state.version

        rig.state.discardPendingRender()
        rig.state.markRendered(atNs: 30_000_000_000)

        #expect(rig.count(.tickToRender) == 0)
        #expect(rig.state.version == version)
        #expect(rig.state.snapshot(1) != nil)

        // The next frame is measured as usual.
        rig.apply(symbolUpdate(seq: 2), sendNs: 200, receivedAtNs: 220)
        rig.state.markRendered(atNs: 250)
        #expect(rig.latency.summary(.tickToRender) == summary(of: [50], metric: .tickToRender))
    }
}

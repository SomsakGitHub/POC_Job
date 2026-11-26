import Foundation
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// How the Lab turns the pump's counters into the texts it shows, and what "Reset stats" starts over. The counters
/// move with every display frame, so the model reads them only when it is asked to take a sample, and the texts it
/// stores change at no other time. The clocks are set by hand: no test waits for a second to pass.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LabSamplingTests {
    /// The dash the texts show while nothing is measured.
    private let dash = "\u{2014}"

    /// A rig and the display time of its pump, which the tests move frame by frame.
    @MainActor private final class Display {
        /// The rig under test.
        let rig: LabRig
        /// The display's timestamp of the newest frame, in seconds.
        private var time = 10.0

        /// A display whose pump has been shown its first frame, which counts nothing because it has no interval.
        init(rig: LabRig = LabRig()) {
            self.rig = rig
            rig.pumpRig.step(at: time)
        }

        /// Shows `count` frames, each `seconds` after the one before.
        func show(_ count: Int, every seconds: Double = 0.016) {
            for _ in 0..<count {
                time += seconds
                rig.pumpRig.step(at: time)
            }
        }

        /// Moves the model's monotonic clock to `seconds` since its start.
        func clock(atSeconds seconds: Double) {
            rig.clock.set(Int64(seconds * 1_000_000_000))
        }

        /// The three texts the model stores, in the order the screen shows them.
        var texts: [String] { [rig.model.fpsText, rig.model.hitchText, rig.model.drawTimeText] }
    }

    // MARK: Sampling

    @Test func theTextsFollowTheCountersAtEachSampleAndStayPutBetweenThem() {
        let display = Display()
        let model = display.rig.model
        display.clock(atSeconds: 1.0)
        let beforeAnySample = display.texts

        model.sampleFrames()
        let baseline = display.texts
        display.show(29)
        display.show(1, every: 0.040)
        display.rig.pump.notifyRendered(drawNs: 2_000_000)
        let betweenSamples = display.texts
        display.clock(atSeconds: 1.5)
        model.sampleFrames()
        let firstRead = display.texts
        display.show(15)
        let afterMoreFrames = display.texts
        display.clock(atSeconds: 2.0)
        model.sampleFrames()
        let secondRead = display.texts

        let drawn = summary(of: [2_000_000])
        let drawText = "p50 \(LatencyFormat.string(ns: drawn.p50Ns)), p99 \(LatencyFormat.string(ns: drawn.p99Ns))"
        #expect(beforeAnySample == [dash, dash, dash])
        #expect(baseline == [dash, dash, dash], "the first sample is a baseline and has no rate")
        #expect(betweenSamples == [dash, dash, dash], "30 frames and a draw happened, and nothing was sampled")
        #expect(firstRead == ["60.0 fps", "1 hitch (3.3%)", drawText])
        #expect(afterMoreFrames == firstRead, "15 more frames, and nothing was sampled")
        #expect(secondRead == ["30.0 fps", "1 hitch (2.2%)", drawText])
        #expect(display.rig.pump.frames == 45)
    }

    @Test func theRateIsADashUntilTwoSamplesAreFarEnoughApart() {
        let display = Display()
        let model = display.rig.model
        display.clock(atSeconds: 1.0)
        model.sampleFrames()
        display.show(30)

        display.clock(atSeconds: 1.3)
        model.sampleFrames()
        let tooSoon = model.fpsText
        display.clock(atSeconds: 1.5)
        model.sampleFrames()

        #expect(tooSoon == dash)
        // Measured from the first sample: 30 frames in half a second.
        #expect(model.fpsText == "60.0 fps")
    }

    @Test func aSampleAfterALongPauseIsNotAnAverageOverTheTimeTheAppWasAway() {
        let display = Display()
        let model = display.rig.model
        display.clock(atSeconds: 1.0)
        model.sampleFrames()
        display.show(30)
        display.clock(atSeconds: 1.5)
        model.sampleFrames()
        let beforeThePause = model.fpsText

        // The app was in the background for ten seconds, with the display link stopped.
        display.show(30)
        display.clock(atSeconds: 11.5)
        model.sampleFrames()
        let afterThePause = model.fpsText
        display.show(30)
        display.clock(atSeconds: 12.0)
        model.sampleFrames()

        #expect(beforeThePause == "60.0 fps")
        #expect(afterThePause == dash)
        #expect(model.fpsText == "60.0 fps")
    }

    @Test func aClockAtItsLimitDoesNotTrapASample() {
        let rig = LabRig(monotonicNs: { UInt64.max })

        rig.model.sampleFrames()
        rig.model.sampleFrames()

        #expect(rig.model.fpsText == dash)
    }

    // MARK: Reset stats

    @Test func resetStatsShowsDashesAtOnceAndNotAfterTheNextSample() {
        let display = Display()
        let model = display.rig.model
        display.clock(atSeconds: 1.0)
        model.sampleFrames()
        display.show(30)
        display.rig.pump.notifyRendered(drawNs: 2_000_000)
        display.clock(atSeconds: 1.5)
        model.sampleFrames()
        let before = display.texts

        model.resetStats()

        #expect(!before.contains(dash), "the texts had numbers in them: \(before)")
        #expect(display.texts == [dash, dash, dash])
    }

    @Test func afterAResetTheRateCountsOnlyTheFramesSinceTheReset() {
        let display = Display()
        let model = display.rig.model
        display.clock(atSeconds: 1.0)
        model.sampleFrames()
        display.show(5)
        display.clock(atSeconds: 1.5)
        model.sampleFrames()
        let before = model.fpsText

        display.clock(atSeconds: 1.7)
        model.resetStats()
        display.show(20)
        display.clock(atSeconds: 2.2)
        model.sampleFrames()

        #expect(before == "10.0 fps")
        // 20 frames in the half second since the reset, and not the 5 frames before it taken off 25.
        #expect(model.fpsText == "40.0 fps")
    }

    @Test func aResetBeforeAnyFrameWasCountedDoesNotShowZeroFramesPerSecond() {
        // Nothing was shown since the first sample, so the counter is the same before and after the reset; the meter
        // must start over and not report 0.0 for the quiet span.
        let display = Display()
        let model = display.rig.model
        display.clock(atSeconds: 1.0)
        model.sampleFrames()

        display.clock(atSeconds: 1.6)
        model.resetStats()

        #expect(model.fpsText == dash)
        // The control: a quiet span between two samples is a measurement of 0.0.
        display.clock(atSeconds: 2.2)
        model.sampleFrames()
        #expect(model.fpsText == "0.0 fps")
    }

    @Test func resetStatsChangesNothingAboutTheServer() async {
        let rest = FakeRest(serverTime: ScriptedCall([.value(1)]), labRead: ScriptedCall([.value(busyLab)]))
        let rig = LabRig(rest: rest)
        await rig.model.load()
        await rig.model.probeRest()
        let before = (rig.model.settings, rig.model.settingsLoaded, rig.model.restStatus, rig.model.reconciliation)

        rig.model.resetStats()

        #expect(before.0 == busyLab)
        #expect(rig.model.settings == before.0)
        #expect(rig.model.settingsLoaded == before.1)
        #expect(rig.model.restStatus == before.2)
        #expect(rig.model.reconciliation == before.3)
        #expect(rest.labWrite.count == 0)
        #expect(rest.drops.count == 0)
        #expect(rest.resets.count == 0)
    }
}

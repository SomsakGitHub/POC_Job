import Contracts
import ExchangeServerKit
import Testing

/// The lab clamps what it is given instead of refusing it, and answers the settings that are now in force.
@Suite("LabControlsTests")
struct LabControlsTests {
    @Test func startsAtTheNeutralSettings() async {
        let settings = await LabControls().settings()
        #expect(settings == LabSettings())
    }

    @Test func applyAnswersTheSettingsNowInForceAndKeepsThem() async {
        let lab = LabControls()
        let patch = LabPatch(rateMultiplier: 2.5, stress: true, extraLatencyMs: 40, jitterMs: 15, dropUpdates: true)
        let expected = LabSettings(
            rateMultiplier: 2.5, stress: true, extraLatencyMs: 40, jitterMs: 15, dropUpdates: true
        )

        let applied = await lab.apply(patch)
        let stored = await lab.settings()
        #expect(applied == expected)
        #expect(stored == expected)
    }

    @Test func fieldsAbsentFromAPatchKeepTheirValue() async {
        let lab = LabControls()
        await lab.apply(LabPatch(rateMultiplier: 4, stress: true, extraLatencyMs: 100, jitterMs: 50, dropUpdates: true))
        var expected = LabSettings(
            rateMultiplier: 4, stress: true, extraLatencyMs: 100, jitterMs: 50, dropUpdates: true
        )

        // Each patch names one field; every other field must come back as it was.
        let steps: [(patch: LabPatch, change: (inout LabSettings) -> Void)] = [
            (LabPatch(stress: false), { $0.stress = false }),
            (LabPatch(rateMultiplier: 0.5), { $0.rateMultiplier = 0.5 }),
            (LabPatch(extraLatencyMs: 0), { $0.extraLatencyMs = 0 }),
            (LabPatch(jitterMs: 0), { $0.jitterMs = 0 }),
            (LabPatch(dropUpdates: false), { $0.dropUpdates = false }),
            (LabPatch(), { _ in }),
        ]
        for step in steps {
            step.change(&expected)
            let applied = await lab.apply(step.patch)
            #expect(applied == expected)
        }
    }

    @Test(arguments: [
        (sent: 0.05, effective: 0.1), (sent: 0.1, effective: 0.1), (sent: 0.5, effective: 0.5),
        (sent: 1.0, effective: 1.0), (sent: 9.99, effective: 9.99), (sent: 10.0, effective: 10.0),
        (sent: 10.01, effective: 10.0), (sent: 1e300, effective: 10.0),
        (sent: Double.greatestFiniteMagnitude, effective: 10.0), (sent: Double.leastNonzeroMagnitude, effective: 0.1),
    ])
    func rateMultiplierIsClampedIntoItsRange(sent: Double, effective: Double) async {
        let applied = await LabControls().apply(LabPatch(rateMultiplier: sent))
        #expect(applied.rateMultiplier == effective)
    }

    /// A rate that is not a usable positive number leaves the old one in place; it is not clamped to an end.
    @Test(arguments: [Double.nan, .infinity, -.infinity, 0, -0.0, -1, -1e300])
    func anUnusableRateMultiplierKeepsTheOldValue(sent: Double) async {
        let lab = LabControls()
        await lab.apply(LabPatch(rateMultiplier: 2.5))
        let applied = await lab.apply(LabPatch(rateMultiplier: sent, stress: true))
        #expect(applied.rateMultiplier == 2.5)
        #expect(applied.stress == true, "the other fields of the patch are still applied")
    }

    @Test(arguments: [
        (sent: Int.min, effective: 0), (sent: -1, effective: 0), (sent: 0, effective: 0), (sent: 1, effective: 1),
        (sent: 4999, effective: 4999), (sent: 5000, effective: 5000), (sent: 5001, effective: 5000),
        (sent: Int.max, effective: 5000),
    ])
    func extraLatencyIsClampedIntoItsRange(sent: Int, effective: Int) async {
        let applied = await LabControls().apply(LabPatch(extraLatencyMs: sent))
        #expect(applied.extraLatencyMs == effective)
    }

    @Test(arguments: [
        (sent: Int.min, effective: 0), (sent: -1, effective: 0), (sent: 0, effective: 0), (sent: 1, effective: 1),
        (sent: 1999, effective: 1999), (sent: 2000, effective: 2000), (sent: 2001, effective: 2000),
        (sent: Int.max, effective: 2000),
    ])
    func jitterIsClampedIntoItsRange(sent: Int, effective: Int) async {
        let applied = await LabControls().apply(LabPatch(jitterMs: sent))
        #expect(applied.jitterMs == effective)
    }

    @Test(arguments: [true, false])
    func stressAndDropUpdatesAreTakenAsSent(flag: Bool) async {
        let lab = LabControls()
        await lab.apply(LabPatch(stress: !flag, dropUpdates: !flag))
        let applied = await lab.apply(LabPatch(stress: flag, dropUpdates: flag))
        #expect(applied.stress == flag)
        #expect(applied.dropUpdates == flag)
    }
}

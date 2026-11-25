import CoreGraphics
import Observation
import Testing
import TradeCore
@testable import TradePulse

/// What the chart does with the fingers and what it says to VoiceOver: how far a drag or a pinch moves the window,
/// which input is ignored, and what makes the chart draw again.
@Suite(.timeLimit(.minutes(1)))
struct ChartGestureTests {
    // MARK: Pan

    @Test func aDragMovesTheOffsetByWholeCandlesBackInTimeWhenItGoesRight() {
        // Slots of 10 points: the offset moves by the drag's length in slots, rounded to the nearest whole candle.
        let cases: [(start: Int, translation: CGFloat, expected: Int)] = [
            (0, 0, 0), (0, 10, 1), (0, 14, 1), (0, 16, 2), (0, 25, 3), (0, -10, -1), (0, -16, -2), (5, 30, 8),
            (5, -30, 2), (240, 100, 250),
        ]
        #expect(cases.count == 10)
        for (start, translation, expected) in cases {
            let moved = CandleChartView.panOffset(start: start, translation: translation, slotWidth: 10)
            #expect(moved == expected, "from \(start) by \(translation) points")
        }
    }

    @Test func aDragThatIsNotAFiniteDistanceOnAFiniteSlotChangesNothing() {
        let nan = CGFloat.nan
        let infinity = CGFloat.infinity
        let cases: [(translation: CGFloat, slotWidth: CGFloat)] = [
            (nan, 10), (infinity, 10), (-infinity, 10), (50, 0), (50, -5), (50, nan), (nan, nan), (50, -infinity),
        ]
        #expect(cases.count == 8)
        for (translation, slotWidth) in cases {
            let moved = CandleChartView.panOffset(start: 7, translation: translation, slotWidth: slotWidth)
            #expect(moved == 7, "a drag of \(translation) over slots of \(slotWidth)")
        }
        // Control: the same start and a usable drag do move it.
        #expect(CandleChartView.panOffset(start: 7, translation: 50, slotWidth: 10) == 12)
    }

    @Test func aDragOfAnyLengthAnswersWithoutTrapping() {
        let far = CandleChartView.panOffset(start: 100, translation: CGFloat.greatestFiniteMagnitude, slotWidth: 1)
        let back = CandleChartView.panOffset(start: 100, translation: -CGFloat.greatestFiniteMagnitude, slotWidth: 1)
        let tiny = CandleChartView.panOffset(start: 100, translation: 1, slotWidth: CGFloat.leastNonzeroMagnitude)
        #expect(far > 100)
        #expect(back < 100)
        #expect(tiny > 100)
    }

    // MARK: Zoom

    @Test func aPinchScalesTheNumberOfCandlesInView() {
        // Pinching out (magnification above 1) shows fewer candles, pinching in more.
        let cases: [(magnification: CGFloat, expected: Int)] = [
            (1, 60), (2, 30), (0.5, 120), (1.5, 40), (1.01, 59), (0.99, 61), (4, 15), (0.25, 240),
        ]
        #expect(cases.count == 8)
        for (magnification, expected) in cases {
            let shown = CandleChartView.visibleCount(start: 60, magnification: magnification)
            #expect(shown == expected, "a pinch of \(magnification)")
        }
    }

    @Test func aPinchThatIsNotAPositiveFiniteScaleChangesNothing() {
        let cases: [CGFloat] = [0, -1, -0.5, .nan, .infinity, -.infinity]
        #expect(cases.count == 6)
        for magnification in cases {
            let shown = CandleChartView.visibleCount(start: 60, magnification: magnification)
            #expect(shown == 60, "a pinch of \(magnification)")
        }
        #expect(CandleChartView.visibleCount(start: 60, magnification: 2) == 30)
    }

    @Test func aPinchOfAnySizeAnswersWithoutTrapping() {
        let huge = CandleChartView.visibleCount(start: 300, magnification: CGFloat.leastNonzeroMagnitude)
        let tiny = CandleChartView.visibleCount(start: 300, magnification: CGFloat.greatestFiniteMagnitude)
        #expect(huge >= 300)
        #expect(tiny <= 1)
    }

    // MARK: Words

    @Test func theChartIsDescribedByItsSymbolAndLastPrice() {
        #expect(CandleChartView.accessibilityLabel(ticker: "PTT", last: satang(3425)) == "Price chart, PTT, last 34.25")
        #expect(CandleChartView.accessibilityLabel(ticker: "AOT", last: nil) == "Price chart, AOT, no price yet")
    }

    // MARK: What makes the chart draw again

    @MainActor
    @Test func theChartDrawsAgainWhenAnythingItIsDrawnFromChanges() async {
        let changes: [(name: String, apply: @MainActor (ModelRig, FramePump) -> Void)] = [
            ("a frame that carried prices", { rig, pump in
                rig.market.feed(last: 3_500)
                pump.step(timestamp: 10, targetTimestamp: 10.016, duration: 0.016)
            }),
            ("a candle that changed", { rig, _ in
                // The price is the one the model has already seen, so the candle is the only thing that changed.
                rig.market.feed(last: 3_425, candle1m: candle(openTimeMs: 18_600_000))
                rig.model.refreshFromState()
            }),
            ("the zoom", { rig, _ in rig.model.visibleCount = 100 }),
            ("the pan", { rig, _ in rig.model.panOffset = 10 }),
            ("the style", { rig, _ in rig.model.style = .line }),
            ("the last price", { rig, _ in
                rig.market.feed(last: 3_600)
                rig.model.refreshFromState()
            }),
        ]
        #expect(changes.count == 6)
        for change in changes {
            let rig = ModelRig(rest: FakeRest(candles: [.candles(history(count: 300))]))
            await rig.model.loadHistory()
            rig.market.feed(last: 3_425)
            rig.model.refreshFromState()
            let pump = FramePump(marketState: rig.market.state)
            let told = Flag()
            withObservationTracking {
                _ = CandleChartView.redrawKey(model: rig.model, pump: pump)
            } onChange: {
                told.set()
            }
            #expect(!told.isSet, "before \(change.name)")

            change.apply(rig, pump)

            #expect(told.isSet, "\(change.name)")
        }
    }

    @MainActor
    @Test func theChartDoesNotDrawAgainWhenNothingChanged() async {
        let rig = ModelRig(rest: FakeRest(candles: [.candles(history(count: 300))]))
        await rig.model.loadHistory()
        rig.market.feed(last: 3_450, candle1m: candle(openTimeMs: 18_600_000))
        rig.model.refreshFromState()
        let pump = FramePump(marketState: rig.market.state)
        pump.step(timestamp: 10, targetTimestamp: 10.016, duration: 0.016)
        let told = Flag()
        withObservationTracking {
            _ = CandleChartView.redrawKey(model: rig.model, pump: pump)
        } onChange: {
            told.set()
        }

        // The model looks again at a market that has not changed, and the display runs another frame: no new tick.
        rig.model.refreshFromState()
        pump.step(timestamp: 10.016, targetTimestamp: 10.032, duration: 0.016)
        #expect(!told.isSet)

        // Control: a frame that carries a new price does draw the chart again.
        rig.market.feed(last: 3_460)
        pump.step(timestamp: 10.032, targetTimestamp: 10.048, duration: 0.016)
        #expect(told.isSet)
    }

    @MainActor
    @Test func theKeyHoldsWhatTheChartIsDrawnFrom() async {
        let rig = ModelRig(rest: FakeRest(candles: [.candles(history(count: 300))]))
        await rig.model.loadHistory()
        rig.market.feed(last: 3_450)
        rig.model.refreshFromState()
        rig.model.visibleCount = 90
        rig.model.panOffset = 12
        rig.model.style = .line
        let pump = FramePump(marketState: rig.market.state)

        let key = CandleChartView.redrawKey(model: rig.model, pump: pump)

        #expect(key.visibleCount == 90)
        #expect(key.panOffset == 12)
        #expect(key.style == .line)
        #expect(key.lastPrice == satang(3_450))
        #expect(key.version == rig.model.series.version)
        #expect(key.tick == pump.tick)
    }
}

import CoreGraphics
import Observation
import Testing
import TradeCore
import UIKit
@testable import TradePulse

/// What the chart does with the fingers and what it says to VoiceOver: how far a drag or a pinch moves the window,
/// which touches are left to the scroll view, which input is ignored, and what makes the chart draw again.
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

    @Test func aDragBeginsAPanOnlyWhenItIsMostlyHorizontal() {
        let nan = CGFloat.nan
        let infinity = CGFloat.infinity
        let cases: [(across: CGFloat, down: CGFloat, begins: Bool, why: String)] = [
            (30, 5, true, "further across than down"),
            (-30, 5, true, "further across, to the left"),
            (30, -5, true, "further across, a little up"),
            (-30, -5, true, "further across, to the left and a little up"),
            (30, 0, true, "straight across"),
            (-30, 0, true, "straight across to the left"),
            (9, 8, true, "just further across than down"),
            (5, 30, false, "further down than across"),
            (-5, 30, false, "further down, a little to the left"),
            (5, -30, false, "further up than across"),
            (-5, -30, false, "further up, a little to the left"),
            (0, 30, false, "straight down"),
            (0, -30, false, "straight up"),
            (8, 9, false, "just further down than across"),
            (10, 10, false, "as far across as down"),
            (-10, 10, false, "as far to the left as down"),
            (10, -10, false, "as far across as up"),
            (-10, -10, false, "as far to the left as up"),
            (0, 0, false, "no distance"),
            (nan, 5, false, "a width that is not a number"),
            (5, nan, false, "a height that is not a number"),
            (nan, nan, false, "nothing that is a number"),
            (infinity, 5, false, "an infinite width"),
            (-infinity, 0, false, "an infinite width to the left"),
            (5, infinity, false, "an infinite height"),
            (30, -infinity, false, "an infinite height upwards"),
            (infinity, infinity, false, "everything infinite"),
        ]
        #expect(cases.count == 27)
        // Both answers are in the table, so a function that always gives one of them is caught.
        #expect(cases.filter(\.begins).count == 7)
        #expect(cases.filter { !$0.begins }.count == 20)
        for (across, down, begins, why) in cases {
            let answer = CandleChartView.beginsPan(translation: CGSize(width: across, height: down))
            #expect(answer == begins, "\(why): \(across) across and \(down) down")
        }
    }

    // MARK: Pan recognizer

    @Test func aTouchIsRefusedAsAPanOnlyOnceItHasGoneFarEnoughAndIsNotMostlySideways() {
        let nan = CGFloat.nan
        let infinity = CGFloat.infinity
        let cases: [(across: CGFloat, down: CGFloat, refused: Bool, why: String)] = [
            (0, 0, false, "it has not moved"),
            (7, 0, false, "short of the distance, across"),
            (0, 7, false, "short of the distance, down: not judged yet"),
            (0, -7.9, false, "short of the distance, up: not judged yet"),
            (5, 5, false, "short of the distance, on the diagonal"),
            (8, 0, false, "exactly the distance, straight across"),
            (-8, 0, false, "exactly the distance, straight across to the left"),
            (30, 5, false, "mostly across"),
            (-30, 12, false, "mostly across, to the left"),
            (7, 5, false, "mostly across, just past the distance"),
            (0, 8, true, "exactly the distance, straight down"),
            (0, -8, true, "exactly the distance, straight up"),
            (0, 30, true, "straight down"),
            (3, 12, true, "mostly down"),
            (-3, -12, true, "mostly up, a little to the left"),
            (5, 7, true, "mostly down, just past the distance"),
            (6, 6, true, "exactly diagonal, just past the distance"),
            (-10, 10, true, "exactly diagonal, to the left"),
            (nan, 0, true, "a width that is not a number"),
            (0, nan, true, "a height that is not a number"),
            (infinity, 0, true, "an infinite width"),
            (0, -infinity, true, "an infinite height upwards"),
            (nan, nan, true, "nothing that is a number"),
            (infinity, infinity, true, "everything infinite"),
        ]
        #expect(cases.count == 24)
        // Both answers are in the table, and so are movements that are judged and let through, so a function that
        // always gives one answer, or that refuses everything it judges, is caught.
        #expect(cases.filter(\.refused).count == 14)
        #expect(cases.filter { !$0.refused }.count == 10)
        for (across, down, refused, why) in cases {
            let answer = ChartPanRecognizer.refuses(movement: CGSize(width: across, height: down))
            #expect(answer == refused, "\(why): \(across) across and \(down) down")
        }
    }

    @Test func aPanCountsFromTheModelsOffsetWhenItBeginsAndIsForgottenWhenItIsOver() {
        typealias State = UIGestureRecognizer.State
        let cases: [(state: State, previous: Int?, modelOffset: Int, expected: Int?, why: String)] = [
            (.began, nil, 5, 5, "a pan that begins counts from the offset the model has"),
            (.began, 9, 5, 5, "a pan that begins does not take the start an earlier pan left behind"),
            (.changed, 9, 12, 9, "a pan that goes on keeps its start although the model has moved"),
            (.changed, nil, 12, 12, "a pan first seen going on counts from the offset the model has"),
            (.ended, 9, 12, nil, "a pan that ended has no start"),
            (.ended, nil, 12, nil, "a pan that ended with no start kept has none"),
            (.cancelled, 9, 12, nil, "a pan that was cancelled has no start"),
            (.cancelled, nil, 12, nil, "a pan that was cancelled with no start kept has none"),
            (.failed, 9, 12, nil, "a pan that failed has no start"),
            (.failed, nil, 12, nil, "a pan that failed with no start kept has none"),
            (.possible, 9, 12, nil, "a pan that has not begun has no start"),
        ]
        #expect(cases.count == 11)
        // Both kinds of answer are in the table, so a function that always gives a start, or never, is caught.
        #expect(cases.filter { $0.expected != nil }.count == 4)
        #expect(cases.filter { $0.expected == nil }.count == 7)
        for (state, previous, modelOffset, expected, why) in cases {
            let start = ChartPan.start(for: state, previous: previous, modelOffset: modelOffset)
            #expect(start == expected, "\(why)")
        }
    }

    @Test func aPanThatEndedWasCancelledOrFailedLeavesNoStartForTheNextOne() {
        let ends: [UIGestureRecognizer.State] = [.ended, .cancelled, .failed]
        #expect(ends.count == 3)
        for end in ends {
            // What the pan keeps from one call to the next, as the recognizer's action updates it.
            var held = ChartPan.start(for: .began, previous: nil, modelOffset: 5)
            #expect(held == 5, "\(end): the pan began where the model was")
            held = ChartPan.start(for: .changed, previous: held, modelOffset: 9)
            #expect(held == 5, "\(end): the pan went on from where it began")
            held = ChartPan.start(for: end, previous: held, modelOffset: 9)
            #expect(held == nil, "\(end): the pan is over")
            // The next pan begins where the model is now, and not where the one before it began.
            held = ChartPan.start(for: .began, previous: held, modelOffset: 9)
            #expect(held == 9, "\(end): the next pan began where the model was")
        }
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

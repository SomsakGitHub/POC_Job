import SwiftUI
import UIKit

/// The pan of the chart: dragging sideways moves the window of candles back and forward in time.
///
/// It is a UIKit gesture recognizer and not a SwiftUI `DragGesture`, because a `DragGesture` on the chart keeps the
/// scroll view around the screen from scrolling up and down, even when it is attached to run beside the scroll view's
/// own gesture: a swipe that starts on the chart would not move the screen. A test inside the drag that the movement
/// is mostly up and down comes too late, because the scroll view has lost the touch by then. The recognizer of this
/// pan decides first. It fails as soon as the touch has gone a few points and is not mostly sideways, and a touch that
/// fails is left to the scroll view. Only a touch that starts out sideways pans, and it goes on panning whichever way
/// it moves afterwards.
///
/// The pan turns the movement of the finger into a new offset for the model and nothing more: the model holds the
/// offset between its limits itself.
struct ChartPan: UIGestureRecognizerRepresentable {
    /// What the pan keeps from one call to the next.
    final class Coordinator {
        /// The offset of the model when the pan in progress began; nil when no pan is in progress.
        var start: Int?
    }

    /// The model whose window the pan moves.
    let model: StockDetailViewModel
    /// How wide one candle's slot is now, in points. It is called each time a movement is handled, so that the width it
    /// gives is the width of that moment and never one that a layout or a pinch has changed since.
    let slotWidth: @MainActor () -> CGFloat

    /// The coordinator that keeps the start of the pan in progress.
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    /// The recognizer: one finger, which fails for a touch that does not start out sideways.
    func makeUIGestureRecognizer(context: Context) -> ChartPanRecognizer {
        let recognizer = ChartPanRecognizer()
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }

    /// Moves the model's window by as many candles as the finger has gone since the pan began, and forgets the start
    /// when the pan is over, whether it ended or was cancelled. A recognizer that fails has no pan to move, and UIKit
    /// does not call the action for it; `start(for:previous:modelOffset:)` gives it no start all the same.
    func handleUIGestureRecognizerAction(_ recognizer: ChartPanRecognizer, context: Context) {
        let start = Self.start(for: recognizer.state, previous: context.coordinator.start, modelOffset: model.panOffset)
        context.coordinator.start = start
        guard let start, let translation = context.converter.localTranslation else { return }
        model.panOffset = CandleChartView.panOffset(start: start, translation: translation.x, slotWidth: slotWidth())
    }

    /// The offset that a pan in `state` counts from, or nil when no pan is in progress.
    ///
    /// A pan that has just begun counts from `modelOffset`, the offset the model has now, whatever the pan before it
    /// left behind. One that is going on keeps `previous`, because the model's offset moves with the pan itself and so
    /// cannot be read again as the start; one that is seen without its beginning takes `modelOffset`. A pan that has
    /// ended, was cancelled or failed has no start, so the next pan cannot be given it.
    nonisolated static func start(for state: UIGestureRecognizer.State, previous: Int?, modelOffset: Int) -> Int? {
        switch state {
        case .began: modelOffset
        case .changed: previous ?? modelOffset
        default: nil
        }
    }
}

/// A pan recognizer that gives up on a touch that does not start out sideways, so that the scroll view around the chart
/// keeps that touch.
///
/// Once a touch has gone `slop` points from where it began, the recognizer asks `CandleChartView.beginsPan` whether
/// that movement is a pan. If it is not, the recognizer fails and the scroll view scrolls with the touch. If it is, the
/// recognizer goes on as any pan recognizer does and begins when the touch has gone the distance the system asks of a
/// pan, which is more than `slop`. The question is asked at each move until the pan has begun and not afterwards, so
/// that a pan which has begun is not stopped when the finger turns.
final class ChartPanRecognizer: UIPanGestureRecognizer {
    /// How far a touch must have gone before it is judged, in points: the distance a drag needs to count as one.
    nonisolated static let slop: CGFloat = 8

    /// Where the touch began, in the coordinates of the recognizer's view.
    private var origin = CGPoint.zero

    /// Notes where the touch began, then goes on as a pan recognizer does.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        origin = touches.first?.location(in: view) ?? .zero
        super.touchesBegan(touches, with: event)
    }

    /// Fails the recognizer when the touch has gone far enough to be judged and is not a pan, and otherwise goes on as
    /// a pan recognizer does.
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let touch = touches.first {
            let point = touch.location(in: view)
            let movement = CGSize(width: point.x - origin.x, height: point.y - origin.y)
            if Self.refuses(movement: movement) {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    /// Whether a touch that has gone `movement` from where it began is refused as a pan: it has gone `slop` points or
    /// more, and `CandleChartView.beginsPan` says that the movement does not begin a pan.
    ///
    /// A touch that has gone less than `slop` is not judged yet, whichever way it has gone. A movement that is not a
    /// finite distance is refused, because it is not a touch.
    nonisolated static func refuses(movement: CGSize) -> Bool {
        let length = hypot(movement.width, movement.height)
        guard length.isFinite else { return true }
        return length >= slop && !CandleChartView.beginsPan(translation: movement)
    }
}

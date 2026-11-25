import SwiftUI
import TradeCore

/// The price chart: candlesticks or a line, the volume bars under them and a line across at the last price, over the
/// window of candles the user has panned and zoomed to.
///
/// It draws again when a frame carried new prices (`pump.tick`) or when anything it is drawn from changed (see
/// `RedrawKey`), and not otherwise. Each draw reads the candles once, builds a `ChartScene` of the window in view and
/// paints it, then tells the pump what the drawing cost. The view has no timer and starts no task.
struct CandleChartView: View {
    /// Everything the picture is drawn from that changes while the chart is on screen. The view reads it in its body,
    /// so that a change to any of it makes the chart draw again, and the drawing uses these values and no others.
    struct RedrawKey: Equatable {
        /// The frame counter of the pump: it moves when a frame carried new prices.
        let tick: UInt64
        /// The version of the candles.
        let version: UInt64
        /// How many candles are in view.
        let visibleCount: Int
        /// How many candles the window sits back from the newest.
        let panOffset: Int
        /// Candles or a line.
        let style: ChartStyle
        /// The last price, for the line across the chart.
        let lastPrice: Price?
    }

    /// The most candles a drag or a pinch is taken to mean: far more than a series holds, and far enough from the
    /// limits of an `Int` that arithmetic with it cannot overflow.
    private nonisolated static let reach = 1_000_000.0

    /// The model whose candles are drawn and whose window the gestures move.
    let model: StockDetailViewModel
    /// The pump: its tick says that the market moved, and it is told what each draw cost.
    let pump: FramePump

    /// The width of the canvas, for turning a drag in points into candles.
    @State private var width: CGFloat = 0
    /// The pan offset when the drag in progress began; nil when no pan is in progress. It is a gesture state, which
    /// SwiftUI sets back to nil when the drag ends and also when it is cancelled (by the system, an alert, the app
    /// going to the background or another gesture taking over); `onEnded` is not called for a cancelled drag.
    @GestureState private var panStart: Int?
    /// The number of candles in view when the pinch in progress began; nil when no pinch is in progress. A gesture
    /// state for the same reason as `panStart`.
    @GestureState private var zoomStart: Int?

    /// The canvas, with the pan and the pinch, described to VoiceOver as one picture.
    var body: some View {
        let key = Self.redrawKey(model: model, pump: pump)
        let model = model
        let pump = pump
        Canvas(rendersAsynchronously: false) { context, size in
            Self.draw(key, of: model, pump: pump, into: &context, size: size)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { width = $0 })
        .contentShape(Rectangle())
        .simultaneousGesture(panGesture)
        .simultaneousGesture(zoomGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(ticker: model.symbol.ticker, last: key.lastPrice))
        .accessibilityAddTraits(.isImage)
    }

    // MARK: What makes the chart draw again

    /// What the chart is drawn from, read in the body so that the chart is evaluated again when any of it changes.
    @MainActor
    static func redrawKey(model: StockDetailViewModel, pump: FramePump) -> RedrawKey {
        RedrawKey(
            tick: pump.tick, version: model.series.version, visibleCount: model.visibleCount,
            panOffset: model.panOffset, style: model.style, lastPrice: model.lastPrice
        )
    }

    // MARK: Drawing

    /// Draws the chart and hands the pump the time the drawing took.
    ///
    /// The time runs from the first line of this function to the last, on the monotonic clock of the machine, and is
    /// worked out once. The candles are read once, so that the scene and everything painted from it are one moment.
    /// The renderer runs on the main thread, which is what the pump and the model need.
    private static func draw(
        _ key: RedrawKey, of model: StockDetailViewModel, pump: FramePump, into context: inout GraphicsContext,
        size: CGSize
    ) {
        MainActor.assumeIsolated {
            let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let scene = ChartScene.make(
                candles: model.series.all, style: key.style, visibleCount: key.visibleCount,
                panOffset: key.panOffset, size: size, lastPrice: key.lastPrice
            )
            paint(scene, into: &context, width: size.width)
            pump.notifyRendered(drawNs: Int64(clamping: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- started))
        }
    }

    /// Fills and strokes what `scene` holds: the volume bars behind, then the candles or the line, then the line
    /// across at the last price. An up candle is a filled body and a down candle a hollow one, so that direction does
    /// not rest on colour alone.
    private static func paint(_ scene: ChartScene, into context: inout GraphicsContext, width: CGFloat) {
        for bar in scene.volumes {
            let rect = CGRect(x: bar.x - bar.width / 2, y: bar.top, width: bar.width, height: bar.height)
            context.fill(Path(rect), with: .color(Color.secondary.opacity(0.35)))
        }
        for mark in scene.candles {
            let color = mark.isUp ? Color.green : Color.red
            var wick = Path()
            wick.move(to: CGPoint(x: mark.x, y: mark.wickTop))
            wick.addLine(to: CGPoint(x: mark.x, y: mark.wickBottom))
            context.stroke(wick, with: .color(color), lineWidth: 1)
            let body = CGRect(x: mark.x - mark.width / 2, y: mark.bodyTop, width: mark.width, height: mark.bodyHeight)
            if mark.isUp {
                context.fill(Path(body), with: .color(color))
            } else {
                context.stroke(Path(body.insetBy(dx: 0.5, dy: 0.5)), with: .color(color), lineWidth: 1)
            }
        }
        if scene.line.count > 1 {
            var path = Path()
            path.addLines(scene.line)
            context.stroke(path, with: .color(.primary), lineWidth: 1.5)
        }
        if let y = scene.lastPriceY {
            var across = Path()
            across.move(to: CGPoint(x: 0, y: y))
            across.addLine(to: CGPoint(x: width, y: y))
            context.stroke(across, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    // MARK: Gestures

    /// How wide one candle's slot is now, in points.
    private var slotWidth: CGFloat {
        width / CGFloat(max(model.visibleCount, 1))
    }

    /// Dragging the chart moves the window by whole candles from where it was when the drag began. A drag that is
    /// mostly vertical is left to the scroll view the chart sits in, unless it began as a pan.
    ///
    /// One closure takes the start (the first time it runs for a drag) and uses it, so the result does not depend on
    /// which of two closures SwiftUI calls first for an event, and there is no `onEnded` that a cancelled drag would
    /// skip: `panStart` is the gesture's own state, so SwiftUI clears it for an ended and for a cancelled drag alike
    /// and the next drag starts from the offset the model has then.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($panStart) { value, start, _ in
                guard start != nil || Self.beginsPan(translation: value.translation) else { return }
                let base = start ?? model.panOffset
                start = base
                model.panOffset = Self.panOffset(
                    start: base, translation: value.translation.width, slotWidth: slotWidth
                )
            }
    }

    /// Pinching changes how many candles are in view from the count when the pinch began. Like the drag, it takes its
    /// start and uses it in one closure; that start is a gesture state, so a cancelled pinch cannot leave it behind.
    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($zoomStart) { value, start, _ in
                let base = start ?? model.visibleCount
                start = base
                model.visibleCount = Self.visibleCount(start: base, magnification: value.magnification)
            }
    }

    /// Whether a drag that has gone `translation` points from where it began starts a pan: it does when it is mostly
    /// horizontal, that is when it has gone further across than up or down. A mostly vertical drag is left to the
    /// scroll view the chart sits in, and so is one that has gone exactly as far across as up or down, because it
    /// does not yet say which way it means to go. A drag whose width is not a finite number starts nothing, and nor
    /// does one whose height is not a number or is infinite, because the width is then not the greater of the two.
    nonisolated static func beginsPan(translation: CGSize) -> Bool {
        translation.width.isFinite && abs(translation.width) > abs(translation.height)
    }

    /// The pan offset that a drag of `translation` points leads to, from the offset `start` it began at: the drag in
    /// slots (`slotWidth` points each), rounded to whole candles, so dragging right moves back in time.
    ///
    /// A translation that is not a number or is infinite, and a slot width that is not a positive finite number, are
    /// not a drag: the answer is `start`. The model holds the result inside the candles there are.
    nonisolated static func panOffset(start: Int, translation: CGFloat, slotWidth: CGFloat) -> Int {
        guard translation.isFinite, slotWidth.isFinite, slotWidth > 0 else { return start }
        let slots = (Double(translation) / Double(slotWidth)).rounded()
        return Int(clamping: Int128(start) + Int128(min(max(slots, -reach), reach)))
    }

    /// The number of candles in view that a pinch of `magnification` leads to, from the count `start` when it began:
    /// the count divided by the magnification, rounded, so pinching out shows fewer candles.
    ///
    /// A magnification that is not a positive finite number is not a pinch: the answer is `start`. The model holds the
    /// result between its limits.
    nonisolated static func visibleCount(start: Int, magnification: CGFloat) -> Int {
        guard magnification.isFinite, magnification > 0 else { return start }
        let count = (Double(start) / Double(magnification)).rounded()
        return Int(min(max(count, 0), reach))
    }

    // MARK: Words

    /// What VoiceOver says for the chart of `ticker`: that it is a price chart, and the last price if there is one.
    nonisolated static func accessibilityLabel(ticker: String, last: Price?) -> String {
        guard let last else { return "Price chart, \(ticker), no price yet" }
        return "Price chart, \(ticker), last \(last.description)"
    }
}

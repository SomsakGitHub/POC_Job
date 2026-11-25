import CoreGraphics
import TradeCore

/// What the chart draws for one frame, as plain numbers in points of the canvas: where each candle's wick and body
/// are, how tall each volume bar is, the points of the line, and where the last-price line is. Building the scene is
/// all the arithmetic of a frame; painting it is only filling and stroking what it holds, so the arithmetic can be
/// tested without a screen.
///
/// Only the candles in view are in a scene. Slots count from the left: with fewer candles than the window holds, they
/// stand in the leftmost slots and keep the width they have when the window is full.
struct ChartScene: Equatable {
    /// One candle: the wick from its high to its low and the body from its open to its close.
    struct CandleMark: Equatable {
        /// Which candle this is, as the series knows it.
        let openTimeMs: Int64
        /// The horizontal centre of the candle.
        let x: CGFloat
        /// The top of the wick, which is the higher of the high and the low in the picture (0 is the top).
        let wickTop: CGFloat
        /// The bottom of the wick.
        let wickBottom: CGFloat
        /// The top of the body.
        let bodyTop: CGFloat
        /// The height of the body: never less than one point, so that a candle that closed where it opened shows.
        let bodyHeight: CGFloat
        /// The width of the body.
        let width: CGFloat
        /// Whether the candle closed at or above where it opened. An up candle is drawn filled and a down one hollow,
        /// so that colour is not the only thing that tells them apart.
        let isUp: Bool
    }

    /// One volume bar, standing on the bottom edge of the canvas.
    struct VolumeMark: Equatable {
        /// Which candle the bar belongs to.
        let openTimeMs: Int64
        /// The horizontal centre of the bar.
        let x: CGFloat
        /// The top of the bar.
        let top: CGFloat
        /// The width of the bar: that of the candle above it.
        let width: CGFloat
        /// The height of the bar, more than 0: a candle with no volume has no bar.
        let height: CGFloat
    }

    /// The candles, left to right; empty in the line style.
    let candles: [CandleMark]
    /// The volume bars, left to right, in both styles.
    let volumes: [VolumeMark]
    /// The points of the line through the closing prices, left to right; empty in the candle style.
    let line: [CGPoint]
    /// Where the line across the chart for the last price is, or nil when there is no last price or it lies outside
    /// the prices the chart shows.
    let lastPriceY: CGFloat?

    /// A scene with nothing to draw.
    static let empty = ChartScene(candles: [], volumes: [], line: [], lastPriceY: nil)

    /// Whether there is nothing to draw.
    var isEmpty: Bool {
        self == Self.empty
    }

    /// The scene for `candles` (the whole series, oldest first) on a canvas of `size`.
    ///
    /// `visibleCount` and `panOffset` choose the window of candles in view, as `ChartLayout.visibleWindow` does. The
    /// prices on the canvas run over the window's own range, padded; the volume bars are scaled by the window's
    /// largest volume. A series with no candles in view, a canvas with no room and a volume of 0 everywhere draw
    /// nothing, and no input makes this trap. The last price is drawn only if it falls inside the padded range: one
    /// that is far outside would flatten the candles if the range grew to fit it, and a line at the edge would claim
    /// a price that the chart does not show.
    static func make(
        candles all: [Candle], style: ChartStyle, visibleCount: Int, panOffset: Int, size: CGSize, lastPrice: Price?
    ) -> ChartScene {
        let window = ChartLayout.visibleWindow(total: all.count, visibleCount: visibleCount, panOffset: panOffset)
        let visible = all[window]
        guard !visible.isEmpty else { return .empty }
        let range = ChartLayout.paddedRange(of: visible)
        let layout = ChartLayout(size: size, visibleCount: visibleCount, priceRange: range)
        guard layout.width > 0, layout.height > 0 else { return .empty }

        let largestVolume = visible.map(\.volume).max() ?? 0
        var marks: [CandleMark] = []
        var points: [CGPoint] = []
        var bars: [VolumeMark] = []
        for (slot, candle) in visible.enumerated() {
            let x = layout.x(index: slot)
            switch style {
            case .candle:
                marks.append(mark(of: candle, at: x, in: layout))
            case .line:
                points.append(CGPoint(x: x, y: layout.y(price: candle.close)))
            }
            let height = layout.volumeHeight(volume: candle.volume, maxVolume: largestVolume)
            if height > 0 {
                bars.append(
                    VolumeMark(
                        openTimeMs: candle.openTimeMs, x: x, top: layout.height - height, width: layout.candleWidth,
                        height: height
                    )
                )
            }
        }
        let lastY = lastPrice.flatMap { range.contains($0) ? layout.y(price: $0) : nil }
        return ChartScene(candles: marks, volumes: bars, line: points, lastPriceY: lastY)
    }

    /// The mark of `candle` standing at `x`. Its wick runs between the two heights of its high and its low whichever
    /// is higher, because a candle off the wire is taken as it came and its high can be below its low.
    private static func mark(of candle: Candle, at x: CGFloat, in layout: ChartLayout) -> CandleMark {
        let high = layout.y(price: candle.high)
        let low = layout.y(price: candle.low)
        let open = layout.y(price: candle.open)
        let close = layout.y(price: candle.close)
        return CandleMark(
            openTimeMs: candle.openTimeMs, x: x, wickTop: min(high, low), wickBottom: max(high, low),
            bodyTop: min(open, close), bodyHeight: max(abs(open - close), 1), width: layout.candleWidth,
            isUp: candle.close >= candle.open
        )
    }
}

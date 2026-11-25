import CoreGraphics

/// Where things go on a price chart: the slot of each candle, the height of a price and of a volume bar, and which
/// candles are in view. Pure arithmetic over a size and a price range, so it needs no screen to be tested.
///
/// The canvas is cut in two. The price pane is the top of it and the volume pane the bottom `volumeFraction` of it;
/// the width is cut into `visibleCount` equal slots, one per candle. The layout is total: whatever it is given (a size
/// that is zero, negative or not a number, a price range of no height, prices at the `Int64` bounds, volumes of zero or
/// less) every method answers with a finite number and none of them traps, so a chart can be drawn from a series
/// whatever the series looks like.
public struct ChartLayout: Sendable {
    /// What the volume pane takes of the height when the caller gives no usable fraction.
    private static let defaultVolumeFraction = 0.2
    /// The most the volume pane may take: half of the height, so the prices always keep at least as much room.
    private static let largestVolumeFraction = 0.5
    /// How much of its slot a candle fills; the rest is the gap between neighbours.
    private static let candleFill = 0.7

    /// The width of the canvas in points; 0 when the size given had a width that is negative or not finite.
    public let width: CGFloat
    /// The height of the canvas in points; 0 when the size given had a height that is negative or not finite.
    public let height: CGFloat
    /// How many slots the width is divided into: the count given, and at least 1.
    public let visibleCount: Int
    /// The part of the height that is the volume pane, from 0 to 0.5.
    public let volumeFraction: Double
    /// The width of one candle's slot.
    public let slotWidth: CGFloat
    /// The height of the volume pane, the bottom `volumeFraction` of the canvas.
    public let volumePaneHeight: CGFloat
    /// The height of the price pane, the top of the canvas: what the volume pane leaves.
    public let pricePaneHeight: CGFloat

    /// The lowest price of the range, in satang. It is kept as the raw `Int64` so that `y(price:)` can take the height
    /// of the range in `Int128`, which two prices at the bounds of an `Int64` do not overflow.
    private let lower: Int64
    /// The highest price of the range, in satang, kept as the raw `Int64` for the same reason as `lower`.
    private let upper: Int64

    /// A layout for a canvas of `size`, with `visibleCount` candle slots across it, showing the prices of `priceRange`.
    ///
    /// A width or height that is negative or not finite counts as 0, and a `visibleCount` below 1 as 1. The
    /// `volumeFraction` is held between 0 and 0.5, and NaN is taken to be the default 0.2.
    public init(size: CGSize, visibleCount: Int, priceRange: ClosedRange<Price>, volumeFraction: Double = 0.2) {
        let width = Self.extent(size.width)
        let height = Self.extent(size.height)
        let fraction = volumeFraction.isNaN
            ? Self.defaultVolumeFraction : min(max(volumeFraction, 0), Self.largestVolumeFraction)
        let slots = max(visibleCount, 1)
        self.width = width
        self.height = height
        self.visibleCount = slots
        self.volumeFraction = fraction
        slotWidth = CGFloat(Double(width) / Double(slots))
        // The two panes are cut from the one height, so they always add up to it.
        volumePaneHeight = CGFloat(Double(height) * fraction)
        pricePaneHeight = height - volumePaneHeight
        lower = priceRange.lowerBound.satang
        upper = priceRange.upperBound.satang
    }

    /// The width of a candle: 70% of its slot, so that neighbours do not touch.
    public var candleWidth: CGFloat {
        CGFloat(Double(slotWidth) * Self.candleFill)
    }

    /// The horizontal centre of slot `index`, counted from the left edge of the canvas.
    ///
    /// An index outside `0..<visibleCount` is a slot beyond the canvas: its centre is a finite number outside
    /// `0...width`, however far out it is.
    public func x(index: Int) -> CGFloat {
        Self.finite((Double(index) + 0.5) * Double(slotWidth))
    }

    /// The vertical position of `price` in the price pane: 0 (the top) at the upper end of the range and the height of
    /// the pane at the lower end, in a straight line between them.
    ///
    /// A price outside the range is held at the nearest edge of the pane, so nothing is ever drawn outside it. A range
    /// of no height puts every price in the middle of the pane. The distances between prices are worked out in
    /// `Int128`, so two prices at the `Int64` bounds can be subtracted.
    public func y(price: Price) -> CGFloat {
        let paneHeight = Double(pricePaneHeight)
        let range = Int128(upper) - Int128(lower)
        guard range > 0 else { return CGFloat(paneHeight / 2) }
        let belowTop = Int128(upper) - Int128(price.satang)
        let fraction = min(max(Double(belowTop) / Double(range), 0), 1)
        return CGFloat(paneHeight * fraction)
    }

    /// The height of the bar for `volume` shares when the biggest bar, `maxVolume` shares, fills the volume pane.
    ///
    /// A volume or a maximum of 0 or less gives a bar of no height, and a volume above the maximum gives a full bar.
    public func volumeHeight(volume: Int64, maxVolume: Int64) -> CGFloat {
        guard volume > 0, maxVolume > 0 else { return 0 }
        return CGFloat(min(1, Double(volume) / Double(maxVolume)) * Double(volumePaneHeight))
    }

    /// The candles in view, as indices into a series of `total` candles.
    ///
    /// `panOffset` is how many candles the window sits back from the newest one, so 0 shows the newest. The window
    /// holds `visibleCount` candles, held between 1 and `total`, and the pan is held between 0 and the room there is
    /// to go back; both are held before anything is subtracted, so no `Int` can overflow it. Fewer candles than the
    /// window holds are all shown, and no candles make an empty window.
    public static func visibleWindow(total: Int, visibleCount: Int, panOffset: Int) -> Range<Int> {
        guard total > 0 else { return 0..<0 }
        let count = min(max(visibleCount, 1), total)
        let pan = min(max(panOffset, 0), total - count)
        return (total - pan - count)..<(total - pan)
    }

    /// The prices a chart of `candles` is drawn over: from the lowest to the highest of all four prices of every
    /// candle, widened on both sides by a twentieth of that span or the tick size at the highest price, whichever is
    /// more, so a flat series still has height and the last candle does not touch the edge.
    ///
    /// All four prices are looked at, because a candle off the wire is taken as it came and its `high` can be below its
    /// `low`. The lower end is never below 0, and the range always has a width (also for prices at the `Int64`
    /// bounds, where the padding may only fit on one side). No candles give 0 to 100.00 baht.
    public static func paddedRange(of candles: ArraySlice<Candle>) -> ClosedRange<Price> {
        guard let first = candles.first else { return Price(satang: 0)...Price(satang: 10_000) }
        var lowest = first.lowestPrice
        var highest = first.highestPrice
        for candle in candles.dropFirst() {
            lowest = min(lowest, candle.lowestPrice)
            highest = max(highest, candle.highestPrice)
        }
        let span = Int128(highest) - Int128(lowest)
        let padding = max(span / 20, Int128(TickRules.tickSize(at: Price(satang: highest)).satang))
        let bottom = max(Int128(lowest) - padding, 0)
        let top = max(Int128(highest) + padding, bottom + 1)
        return Price(satang: Int64(clamping: bottom))...Price(satang: Int64(clamping: top))
    }

    /// `length` as a length of the canvas: 0 when it is negative or not a number (infinity included).
    private static func extent(_ length: CGFloat) -> CGFloat {
        length.isFinite && length > 0 ? length : 0
    }

    /// `value` held between the smallest and the biggest finite `Double`, so that a product too big for a `Double`
    /// is a very large number and not infinity.
    private static func finite(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, -Double.greatestFiniteMagnitude), Double.greatestFiniteMagnitude))
    }
}

extension Candle {
    /// The lowest of the four prices, in satang: whichever of them it is, not only `low`.
    fileprivate var lowestPrice: Int64 {
        min(open.satang, high.satang, low.satang, close.satang)
    }

    /// The highest of the four prices, in satang: whichever of them it is, not only `high`.
    fileprivate var highestPrice: Int64 {
        max(open.satang, high.satang, low.satang, close.satang)
    }
}

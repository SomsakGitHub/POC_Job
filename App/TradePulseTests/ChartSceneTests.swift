import CoreGraphics
import Testing
import TradeCore
@testable import TradePulse

/// What the chart puts on the canvas for a series of candles: which candles are in view, where each one stands, how
/// tall its volume bar is, and when nothing is drawn at all. The scene is plain numbers, so it is checked here without
/// a screen.
@Suite(.timeLimit(.minutes(1)))
struct ChartSceneTests {
    /// The canvas of these tests: 400 by 300 points, so that with 20 slots a slot is 20 points wide, the price pane is
    /// 240 points high and the volume pane 60.
    private static let size = CGSize(width: 400, height: 300)

    /// Four candles, all prices in satang. The lowest price is 3300 and the highest 3600, a span of 300, so the chart's
    /// range is 3275 to 3625 (a twentieth of the span is 15, which is less than the tick size of 25 at that price).
    ///   - up with a body from 3400 to 3450, volume 100;
    ///   - down with a body from 3450 to 3400, volume 200;
    ///   - flat, every price 3400, volume 50;
    ///   - up with a body from 3420 to 3510, volume 0.
    private static let four: [Candle] = [
        ohlc(60_000, 3400, 3500, 3300, 3450, volume: 100),
        ohlc(120_000, 3450, 3600, 3400, 3400, volume: 200),
        ohlc(180_000, 3400, 3400, 3400, 3400, volume: 50),
        ohlc(240_000, 3420, 3520, 3380, 3510, volume: 0),
    ]

    /// A candle that opens at `time` milliseconds with these four prices in satang.
    private static func ohlc(
        _ time: Int64, _ open: Int64, _ high: Int64, _ low: Int64, _ close: Int64, volume: Int64
    ) -> Candle {
        Candle(
            openTimeMs: time, open: satang(open), high: satang(high), low: satang(low), close: satang(close),
            volume: volume
        )
    }

    /// Where a price of `satang` stands on that canvas: the price pane is 240 points for the range 3275 to 3625.
    private func y(_ satang: Int64) -> CGFloat {
        240 * CGFloat(3625 - satang) / 350
    }

    /// Whether `a` and `b` are the same number to a billionth.
    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) < 1e-9
    }

    /// The scene the chart builds for `candles`, with a default for every other argument: the candle style, a window of
    /// 20 candles at the newest, the canvas of these tests and no last price (`last` is given in satang).
    private func scene(
        _ candles: [Candle], style: ChartStyle = .candle, visibleCount: Int = 20, panOffset: Int = 0,
        size: CGSize = Self.size, last: Int64? = nil
    ) -> ChartScene {
        ChartScene.make(
            candles: candles, style: style, visibleCount: visibleCount, panOffset: panOffset, size: size,
            lastPrice: last.map { satang($0) }
        )
    }

    // MARK: The candles in view

    @Test func theSceneHoldsOnlyTheCandlesInView() {
        let all = history(count: 300)
        let newest = scene(all, visibleCount: 30)
        #expect(newest.candles.map(\.openTimeMs) == all[270..<300].map(\.openTimeMs))
        #expect(newest.volumes.map(\.openTimeMs) == all[270..<300].map(\.openTimeMs))

        let back = scene(all, visibleCount: 30, panOffset: 100)
        #expect(back.candles.map(\.openTimeMs) == all[170..<200].map(\.openTimeMs))

        // Further back than the data goes: the oldest candles, not nothing.
        let oldest = scene(all, visibleCount: 30, panOffset: 10_000)
        #expect(oldest.candles.map(\.openTimeMs) == all[0..<30].map(\.openTimeMs))
        let beyond = scene(all, visibleCount: 30, panOffset: Int.max)
        #expect(beyond == oldest)
    }

    @Test func aCountBelowOneShowsTheNewestCandle() {
        let all = history(count: 30)
        let one = scene(all, visibleCount: 0, panOffset: 0)
        #expect(one.candles.map(\.openTimeMs) == [all[29].openTimeMs])
    }

    @Test func fewerCandlesThanSlotsStandInTheLeftmostSlots() {
        let drawn = scene(Self.four)
        #expect(drawn.candles.count == 4)
        #expect(drawn.candles.map(\.x) == [10, 30, 50, 70])
        #expect(drawn.candles.allSatisfy { near($0.width, 14) })
    }

    // MARK: Candles

    @Test func eachCandleHasItsWickBodyAndDirection() throws {
        let marks = scene(Self.four).candles
        try #require(marks.count == 4)

        // Up: the wick runs from the high to the low and the body from the close (top) to the open.
        #expect(near(marks[0].wickTop, y(3500)))
        #expect(near(marks[0].wickBottom, y(3300)))
        #expect(near(marks[0].bodyTop, y(3450)))
        #expect(near(marks[0].bodyHeight, y(3400) - y(3450)))
        #expect(marks[0].isUp)

        // Down: the same box with the other corner, and not up.
        #expect(near(marks[1].wickTop, y(3600)))
        #expect(near(marks[1].wickBottom, y(3400)))
        #expect(near(marks[1].bodyTop, y(3450)))
        #expect(near(marks[1].bodyHeight, y(3400) - y(3450)))
        #expect(!marks[1].isUp)

        #expect(near(marks[3].bodyTop, y(3510)))
        #expect(near(marks[3].bodyHeight, y(3420) - y(3510)))
        #expect(marks[3].isUp)
    }

    @Test func aCandleThatClosesWhereItOpenedIsUpAndHasABodyOfOnePoint() throws {
        let marks = scene(Self.four).candles
        try #require(marks.count == 4)
        let flat = marks[2]
        #expect(flat.isUp)
        #expect(near(flat.bodyTop, y(3400)))
        #expect(near(flat.bodyHeight, 1))
        #expect(near(flat.wickTop, y(3400)))
        #expect(near(flat.wickBottom, y(3400)))
    }

    @Test func aBodyThatIsTallerThanOnePointKeepsItsHeight() throws {
        let marks = scene(Self.four).candles
        try #require(marks.count == 4)
        #expect(marks[3].bodyHeight > 1)
        #expect(marks[0].bodyHeight > 1)
    }

    @Test func aWickIsDrawnFromTheTopEvenWhenTheHighIsBelowTheLow() throws {
        // A candle off the wire is taken as it came: here the high is below the low.
        let odd = Self.ohlc(60_000, 3400, 3300, 3500, 3450, volume: 1)
        let marks = scene([odd]).candles
        try #require(marks.count == 1)
        let mark = marks[0]
        #expect(mark.wickTop <= mark.wickBottom)
        #expect(mark.wickBottom - mark.wickTop > 0)
        #expect(mark.wickTop >= 0)
        #expect(mark.wickBottom <= 240)
    }

    // MARK: Volume

    @Test func volumeBarsAreScaledByTheLargestVolumeInView() {
        let bars = scene(Self.four).volumes
        // The candle with no volume has no bar; the others fill the 60-point pane in proportion to 200.
        #expect(bars.map(\.openTimeMs) == [60_000, 120_000, 180_000])
        #expect(zip(bars.map(\.height), [30, 60, 15]).allSatisfy { near($0, $1) })
        #expect(zip(bars.map(\.top), [270, 240, 285]).allSatisfy { near($0, $1) })
        #expect(bars.map(\.x) == [10, 30, 50])
        #expect(bars.allSatisfy { near($0.width, 14) })
    }

    @Test func aBigVolumeOutsideTheViewDoesNotShrinkTheBars() throws {
        var all = history(count: 300)
        all[0].volume = 1_000_000
        let bars = scene(all, visibleCount: 30).volumes
        // The window holds volumes 370 to 399: the newest fills the pane, the oldest in view is 370 of 399.
        try #require(bars.count == 30)
        #expect(near(bars[29].height, 60))
        #expect(near(bars[0].height, 60 * 370 / 399))
    }

    @Test func noVolumeAnywhereDrawsNoBars() {
        let silent = Self.four.map { candle -> Candle in
            var quiet = candle
            quiet.volume = 0
            return quiet
        }
        let drawn = scene(silent)
        #expect(drawn.candles.count == 4)
        #expect(drawn.volumes.isEmpty)
    }

    // MARK: The line

    @Test func theLineStyleDrawsOnePointPerCloseAndNoCandles() {
        let drawn = scene(Self.four, style: .line)
        #expect(drawn.candles.isEmpty)
        #expect(drawn.line.map(\.x) == [10, 30, 50, 70])
        #expect(zip(drawn.line, [3450, 3400, 3400, 3510]).allSatisfy { near($0.y, y($1)) })
        // The volume bars are drawn in both styles.
        #expect(drawn.volumes.count == 3)
    }

    @Test func theCandleStyleDrawsNoLine() {
        let drawn = scene(Self.four, style: .candle)
        #expect(drawn.line.isEmpty)
        #expect(!drawn.candles.isEmpty)
    }

    // MARK: The last-price line

    @Test func theLastPriceLineStandsAtTheLastPriceInsideTheRange() {
        let drawn = scene(Self.four, last: 3500)
        let line = drawn.lastPriceY
        #expect(line != nil)
        #expect(near(line ?? -1, y(3500)))
    }

    @Test func theLastPriceLineIsOmittedOutsideTheRangeAndKeptAtItsEdges() {
        // The range of these candles is 3275 to 3625 with the padding; their own prices go from 3300 to 3600.
        let inside = scene(Self.four, last: 3620)
        #expect(near(inside.lastPriceY ?? -1, y(3620)))

        let top = scene(Self.four, last: 3625)
        let bottom = scene(Self.four, last: 3275)
        #expect(near(top.lastPriceY ?? -1, 0))
        #expect(near(bottom.lastPriceY ?? -1, 240))

        #expect(scene(Self.four, last: 3626).lastPriceY == nil)
        #expect(scene(Self.four, last: 3274).lastPriceY == nil)
        #expect(scene(Self.four, last: 0).lastPriceY == nil)
        #expect(scene(Self.four, last: Int64.max).lastPriceY == nil)
        #expect(scene(Self.four, last: Int64.min).lastPriceY == nil)
    }

    @Test func noLastPriceNoLine() {
        #expect(scene(Self.four, last: nil).lastPriceY == nil)
    }

    // MARK: Nothing to draw

    @Test func noCandlesDrawNothingEvenWithALastPrice() {
        let drawn = scene([], last: 3500)
        #expect(drawn == ChartScene.empty)
        #expect(drawn.isEmpty)
        #expect(!scene(Self.four).isEmpty)
    }

    @Test func aCanvasWithNoRoomDrawsNothing() {
        let awkward: [CGSize] = [
            CGSize(width: 0, height: 0), CGSize(width: 0, height: 300), CGSize(width: 400, height: 0),
            CGSize(width: -1, height: 300), CGSize(width: 400, height: -1), CGSize(width: CGFloat.nan, height: 300),
            CGSize(width: 400, height: CGFloat.nan), CGSize(width: CGFloat.infinity, height: 300),
        ]
        #expect(awkward.count == 8)
        for size in awkward {
            let drawn = scene(Self.four, size: size, last: 3500)
            #expect(drawn == ChartScene.empty, "a canvas of \(size.width) by \(size.height)")
        }
        // The same candles on a canvas with room are drawn.
        #expect(!scene(Self.four, size: CGSize(width: 400, height: 300)).isEmpty)
    }

    // MARK: Odd numbers

    @Test func aFlatSeriesStillHasHeightAndEveryNumberIsFinite() {
        let flat = (0..<5).map { index in
            Candle(
                openTimeMs: Int64(index) * 60_000, open: satang(3425), high: satang(3425), low: satang(3425),
                close: satang(3425), volume: 10
            )
        }
        let drawn = scene(flat, last: 3425)
        #expect(drawn.candles.count == 5)
        #expect(drawn.candles.allSatisfy { $0.wickTop.isFinite && $0.bodyTop.isFinite && $0.bodyHeight == 1 })
        // Everything stands in the middle of the price pane: a range of one price gets padding on both sides.
        #expect(drawn.candles.allSatisfy { near($0.wickTop, 120) })
        #expect(near(drawn.lastPriceY ?? -1, 120))
    }

    @Test func pricesAtTheBoundsOfInt64StayInsideThePricePane() throws {
        let low = Int64.min
        let high = Int64.max
        let extremes: [Candle] = [
            Self.ohlc(60_000, low, high, low, 0, volume: Int64.max),
            Self.ohlc(120_000, high, high, high, high, volume: Int64.min),
            Self.ohlc(180_000, -5, 5, -5, 5, volume: 1),
        ]
        let drawn = scene(extremes, last: Int64.max)
        #expect(drawn.candles.count == 3)
        for mark in drawn.candles {
            for value in [mark.x, mark.wickTop, mark.wickBottom, mark.bodyTop, mark.bodyHeight, mark.width] {
                #expect(value.isFinite)
            }
            #expect(mark.wickTop >= 0)
            #expect(mark.wickBottom <= 240)
        }
        // The first candle has the biggest volume, the second has none and so no bar, and the third has so little that
        // its bar is hardly there but is more than nothing: two bars, so the loop has something to look at.
        try #require(drawn.volumes.count == 2)
        for bar in drawn.volumes {
            #expect(bar.height.isFinite && bar.top.isFinite)
            #expect(bar.height <= 60)
        }
        // The last price is the highest there is, which is inside the range, so a line across is drawn.
        let lastY = try #require(drawn.lastPriceY)
        #expect(lastY.isFinite)
    }
}

import CoreGraphics
import Testing
import TradeCore

/// A price of `satang` satang.
private func price(_ satang: Int64) -> Price {
    Price(satang: satang)
}

/// A candle whose four prices are all `satang`: the shape of a market that did not move.
private func flat(_ satang: Int64, openTimeMs: Int64 = 0) -> Candle {
    Candle(
        openTimeMs: openTimeMs, open: price(satang), high: price(satang), low: price(satang), close: price(satang),
        volume: 1
    )
}

/// A candle with the four prices as given, in whatever order: a candle off the wire is taken as it came.
private func candle(open: Int64, high: Int64, low: Int64, close: Int64) -> Candle {
    Candle(openTimeMs: 0, open: price(open), high: price(high), low: price(low), close: price(close), volume: 1)
}

/// The layout of a 400 x 300 canvas with 20 slots over the prices 34.00 to 35.00 and the default volume fraction: a
/// price pane 240 high, a volume pane 60 high, and slots 20 wide.
private let layout = ChartLayout(
    size: CGSize(width: 400, height: 300), visibleCount: 20, priceRange: price(3400)...price(3500)
)

/// Where a chart puts prices, candles and volume bars on a canvas, which candles are in view, and the range of prices
/// a chart is drawn over. Every answer must be a finite number, whatever the canvas, the range and the candles are.
struct ChartLayoutTests {
    // MARK: Prices

    @Test func yDecreasesAsPriceIncreases() {
        let ys = [3400, 3425, 3450, 3475, 3500].map { layout.y(price: price($0)) }
        #expect(ys.count == 5)
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 > $1 })
        // The lower bound is the bottom of the price pane, the upper bound its top, and the middle is the middle.
        #expect(abs(ys[0] - 240) < 1e-9)
        #expect(abs(ys[2] - 120) < 1e-9)
        #expect(abs(ys[4]) < 1e-9)
    }

    @Test func yIsClampedIntoThePricePane() {
        let above = [3501, 4000, 1_000_000, Int64.max].map { layout.y(price: price($0)) }
        let below = [3399, 3000, 0, -1, Int64.min].map { layout.y(price: price($0)) }
        #expect(above.count == 4)
        #expect(below.count == 5)
        #expect(above.allSatisfy { $0 == 0 })
        #expect(below.allSatisfy { abs($0 - 240) < 1e-9 })
        // A taller canvas has a taller pane, and the clamp follows it.
        let tall = ChartLayout(
            size: CGSize(width: 400, height: 1000), visibleCount: 20, priceRange: price(3400)...price(3500)
        )
        #expect(abs(tall.y(price: price(0)) - 800) < 1e-9)
        #expect(tall.y(price: price(Int64.max)) == 0)
    }

    @Test func aRangeOfZeroHeightMapsEveryPriceToTheMiddleOfThePane() {
        let flat = ChartLayout(
            size: CGSize(width: 400, height: 300), visibleCount: 20, priceRange: price(3425)...price(3425)
        )
        let ys = [3425, 0, -5, Int64.max, Int64.min].map { flat.y(price: price($0)) }
        #expect(ys.count == 5)
        #expect(ys.allSatisfy { abs($0 - 120) < 1e-9 })
    }

    @Test func pricesAtTheInt64BoundsAreSubtractedWithoutTrapping() {
        let wide = ChartLayout(
            size: CGSize(width: 400, height: 300), visibleCount: 20, priceRange: price(Int64.min)...price(Int64.max)
        )
        #expect(abs(wide.y(price: price(Int64.min)) - 240) < 1e-9)
        #expect(abs(wide.y(price: price(0)) - 120) < 1e-9)
        #expect(wide.y(price: price(Int64.max)) == 0)
    }

    // MARK: Slots

    @Test func xIsTheCentreOfTheSlotAndCandlesFillSeventyPercentOfIt() {
        #expect(abs(layout.x(index: 0) - 10) < 1e-9)
        #expect(abs(layout.x(index: 1) - 30) < 1e-9)
        #expect(abs(layout.x(index: 19) - 390) < 1e-9)
        #expect(abs(layout.candleWidth - 14) < 1e-9)
    }

    @Test func anIndexOutsideTheWindowIsAFiniteNumberOutsideTheCanvas() {
        #expect(abs(layout.x(index: -1) - -10) < 1e-9)
        #expect(abs(layout.x(index: 20) - 410) < 1e-9)
        #expect(layout.x(index: Int.min).isFinite)
        #expect(layout.x(index: Int.max).isFinite)
        #expect(layout.x(index: Int.max) > 400)
        #expect(layout.x(index: Int.min) < 0)
    }

    @Test func aVisibleCountBelowOneCountsAsOne() {
        for count in [0, -1, Int.min] {
            let one = ChartLayout(
                size: CGSize(width: 400, height: 300), visibleCount: count, priceRange: price(3400)...price(3500)
            )
            #expect(abs(one.x(index: 0) - 200) < 1e-9)
            #expect(abs(one.candleWidth - 280) < 1e-9)
        }
    }

    @Test func aSizeThatIsNegativeOrNotFiniteCountsAsZero() {
        let sizes = [
            CGSize(width: -50, height: -50), CGSize(width: CGFloat.nan, height: CGFloat.nan),
            CGSize(width: CGFloat.infinity, height: -CGFloat.infinity), CGSize(width: 0, height: 0),
        ]
        #expect(sizes.count == 4)
        for size in sizes {
            let empty = ChartLayout(size: size, visibleCount: 20, priceRange: price(3400)...price(3500))
            #expect(empty.x(index: 5) == 0)
            #expect(empty.candleWidth == 0)
            #expect(empty.y(price: price(3450)) == 0)
            #expect(empty.volumeHeight(volume: 5, maxVolume: 10) == 0)
        }
        // One side that is not usable does not take the other with it.
        let flatHeight = ChartLayout(
            size: CGSize(width: 400, height: CGFloat.nan), visibleCount: 20, priceRange: price(3400)...price(3500)
        )
        #expect(abs(flatHeight.x(index: 0) - 10) < 1e-9)
        #expect(flatHeight.y(price: price(3450)) == 0)
    }

    // MARK: Panes

    @Test func theVolumePaneIsTheBottomFractionOfTheHeight() {
        // 300 x 0.2 = 60 for the volume pane; the price pane keeps the other 240.
        #expect(abs(layout.volumeHeight(volume: 100, maxVolume: 100) - 60) < 1e-9)
        #expect(abs(layout.y(price: price(3400)) - 240) < 1e-9)
        let half = ChartLayout(
            size: CGSize(width: 400, height: 300), visibleCount: 20, priceRange: price(3400)...price(3500),
            volumeFraction: 0.5
        )
        #expect(abs(half.volumeHeight(volume: 100, maxVolume: 100) - 150) < 1e-9)
        #expect(abs(half.y(price: price(3400)) - 150) < 1e-9)
    }

    @Test func theVolumeFractionIsClampedAndNaNMeansTheDefault() {
        func volumePane(_ fraction: Double) -> CGFloat {
            ChartLayout(
                size: CGSize(width: 400, height: 300), visibleCount: 20, priceRange: price(3400)...price(3500),
                volumeFraction: fraction
            ).volumeHeight(volume: 1, maxVolume: 1)
        }
        #expect(abs(volumePane(0.9) - 150) < 1e-9)
        #expect(abs(volumePane(.infinity) - 150) < 1e-9)
        #expect(volumePane(-1) == 0)
        #expect(volumePane(-.infinity) == 0)
        #expect(abs(volumePane(.nan) - 60) < 1e-9)
        #expect(abs(volumePane(0.1) - 30) < 1e-9)
    }

    @Test func volumeHeightZeroMaxIsZero() {
        let heights = [
            layout.volumeHeight(volume: 0, maxVolume: 0),
            layout.volumeHeight(volume: 500, maxVolume: 0),
            layout.volumeHeight(volume: 500, maxVolume: -5),
            layout.volumeHeight(volume: Int64.max, maxVolume: Int64.min),
        ]
        // Equal to 0 is false for NaN, so this also says that nothing is NaN.
        #expect(heights == [0, 0, 0, 0])
        // And the same layout does give a height when there is a volume to scale against.
        #expect(abs(layout.volumeHeight(volume: 50, maxVolume: 100) - 30) < 1e-9)
    }

    @Test func aVolumeOfZeroOrLessIsAnEmptyBar() {
        #expect(layout.volumeHeight(volume: 0, maxVolume: 100) == 0)
        #expect(layout.volumeHeight(volume: -3, maxVolume: 100) == 0)
        #expect(layout.volumeHeight(volume: Int64.min, maxVolume: 100) == 0)
    }

    @Test func aVolumeAboveTheMaximumIsNeverTallerThanThePane() {
        #expect(abs(layout.volumeHeight(volume: 250, maxVolume: 100) - 60) < 1e-9)
        #expect(abs(layout.volumeHeight(volume: Int64.max, maxVolume: 1) - 60) < 1e-9)
        #expect(abs(layout.volumeHeight(volume: Int64.max, maxVolume: Int64.max) - 60) < 1e-9)
    }

    // MARK: Everything is finite

    @Test func layoutIsFiniteForDegenerateInputs() {
        let sizes = [
            CGSize.zero, CGSize(width: -10, height: -10), CGSize(width: CGFloat.nan, height: 100),
            CGSize(width: 100, height: CGFloat.infinity), CGSize(width: -CGFloat.infinity, height: CGFloat.nan),
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            CGSize(width: 300, height: 0), CGSize(width: 0, height: 300), CGSize(width: 390, height: 300),
        ]
        let counts = [Int.min, -1, 0, 1, 2, 300, Int.max]
        let ranges = [
            price(3425)...price(3425), price(0)...price(0), price(3400)...price(3500),
            price(Int64.min)...price(Int64.max), price(Int64.max)...price(Int64.max),
            price(Int64.min)...price(Int64.min), price(-5)...price(5),
        ]
        let fractions = [0.2, Double.nan, -1, 0, 0.5, 0.9, .infinity, -.infinity]
        var layouts: [ChartLayout] = []
        for size in sizes {
            for count in counts {
                for range in ranges {
                    for fraction in fractions {
                        layouts.append(
                            ChartLayout(size: size, visibleCount: count, priceRange: range, volumeFraction: fraction)
                        )
                    }
                }
            }
        }
        // The loop below has something to run on: the table is the product of the four lists.
        #expect(layouts.count == sizes.count * counts.count * ranges.count * fractions.count)
        #expect(!layouts.isEmpty)

        let indices = [Int.min, -1, 0, 1, 299, Int.max]
        let prices = [Int64.min, -1, 0, 1, 3425, Int64.max]
        let volumes = [Int64.min, -1, 0, 1, 1000, Int64.max]
        var failures: [String] = []
        for candidate in layouts {
            if !candidate.candleWidth.isFinite { failures.append("candleWidth \(candidate)") }
            for index in indices where !candidate.x(index: index).isFinite {
                failures.append("x(\(index)) \(candidate)")
            }
            for satang in prices where !candidate.y(price: price(satang)).isFinite {
                failures.append("y(\(satang)) \(candidate)")
            }
            for volume in volumes {
                for maxVolume in volumes where !candidate.volumeHeight(volume: volume, maxVolume: maxVolume).isFinite {
                    failures.append("volumeHeight(\(volume), \(maxVolume)) \(candidate)")
                }
            }
        }
        #expect(failures.isEmpty, "not finite: \(failures.prefix(3))")
    }

    // MARK: The window

    @Test func visibleWindowClampsPan() {
        #expect(ChartLayout.visibleWindow(total: 100, visibleCount: 20, panOffset: 0) == 80..<100)
        #expect(ChartLayout.visibleWindow(total: 100, visibleCount: 20, panOffset: 10) == 70..<90)
        #expect(ChartLayout.visibleWindow(total: 100, visibleCount: 20, panOffset: 80) == 0..<20)
        // Further back than the oldest candle, or forward of the newest, stops at the end of the data.
        #expect(ChartLayout.visibleWindow(total: 100, visibleCount: 20, panOffset: 81) == 0..<20)
        #expect(ChartLayout.visibleWindow(total: 100, visibleCount: 20, panOffset: 1_000_000) == 0..<20)
        #expect(ChartLayout.visibleWindow(total: 100, visibleCount: 20, panOffset: -5) == 80..<100)
        // Fewer candles than the window holds: all of them, wherever the pan is.
        #expect(ChartLayout.visibleWindow(total: 10, visibleCount: 20, panOffset: 0) == 0..<10)
        #expect(ChartLayout.visibleWindow(total: 10, visibleCount: 20, panOffset: 7) == 0..<10)
        #expect(ChartLayout.visibleWindow(total: 10, visibleCount: 20, panOffset: -7) == 0..<10)
    }

    @Test func visibleWindowOfNoCandlesIsEmpty() {
        #expect(ChartLayout.visibleWindow(total: 0, visibleCount: 20, panOffset: 0) == 0..<0)
        #expect(ChartLayout.visibleWindow(total: 0, visibleCount: 20, panOffset: 5) == 0..<0)
        #expect(ChartLayout.visibleWindow(total: -1, visibleCount: 20, panOffset: 0) == 0..<0)
        #expect(ChartLayout.visibleWindow(total: Int.min, visibleCount: Int.min, panOffset: Int.min) == 0..<0)
    }

    @Test func theWindowHoldsAtLeastOneCandleAndAtMostAllOfThem() {
        #expect(ChartLayout.visibleWindow(total: 50, visibleCount: 0, panOffset: 0) == 49..<50)
        #expect(ChartLayout.visibleWindow(total: 50, visibleCount: -3, panOffset: 0) == 49..<50)
        #expect(ChartLayout.visibleWindow(total: 50, visibleCount: Int.min, panOffset: 0) == 49..<50)
        #expect(ChartLayout.visibleWindow(total: 50, visibleCount: 51, panOffset: 0) == 0..<50)
        #expect(ChartLayout.visibleWindow(total: 50, visibleCount: Int.max, panOffset: 0) == 0..<50)
    }

    @Test func thePanIsClampedBeforeAnySubtraction() {
        // These would trap in the subtraction if the offset were used as it is.
        #expect(ChartLayout.visibleWindow(total: 100, visibleCount: 20, panOffset: Int.max) == 0..<20)
        #expect(ChartLayout.visibleWindow(total: 100, visibleCount: 20, panOffset: Int.min) == 80..<100)
        #expect(ChartLayout.visibleWindow(total: Int.max, visibleCount: 1, panOffset: Int.max) == 0..<1)
        let newest = ChartLayout.visibleWindow(total: Int.max, visibleCount: 1, panOffset: Int.min)
        #expect(newest == (Int.max - 1)..<Int.max)
        #expect(ChartLayout.visibleWindow(total: Int.max, visibleCount: Int.max, panOffset: Int.max) == 0..<Int.max)
    }

    @Test func theWindowAlwaysStaysInsideTheData() {
        let totals = [0, 1, 5, 300]
        let counts = [Int.min, -1, 0, 1, 20, 300, Int.max]
        let pans = [Int.min, -1, 0, 1, 7, 1000, Int.max]
        var checked = 0
        var failures: [String] = []
        for total in totals {
            for count in counts {
                for pan in pans {
                    let window = ChartLayout.visibleWindow(total: total, visibleCount: count, panOffset: pan)
                    let expectedCount = total == 0 ? 0 : min(max(count, 1), total)
                    if window.lowerBound < 0 || window.upperBound > total || window.count != expectedCount {
                        failures.append("(\(total), \(count), \(pan)) gave \(window)")
                    }
                    checked += 1
                }
            }
        }
        #expect(checked == totals.count * counts.count * pans.count)
        #expect(failures.isEmpty, "\(failures.prefix(3))")
    }

    // MARK: The padded range

    @Test func flatSeriesGetsNonZeroRange() {
        let candles = (0..<30).map { flat(3425, openTimeMs: Int64($0) * 60_000) }
        let range = ChartLayout.paddedRange(of: candles[...])
        let tick = TickRules.tickSize(at: price(3425)).satang
        #expect(tick == 25)
        #expect(range.upperBound.satang - range.lowerBound.satang >= tick)
        #expect(range == price(3400)...price(3450))
        let chart = ChartLayout(size: CGSize(width: 400, height: 300), visibleCount: 30, priceRange: range)
        let y = chart.y(price: price(3425))
        #expect(y.isFinite)
        #expect(abs(y - 120) < 1e-9)
    }

    @Test func emptyCandlesGiveDefaultRange() {
        let range = ChartLayout.paddedRange(of: ArraySlice<Candle>())
        #expect(range == price(0)...price(10_000))
        // The default range is a usable one.
        let chart = ChartLayout(size: CGSize(width: 400, height: 300), visibleCount: 30, priceRange: range)
        #expect(chart.y(price: price(5_000)).isFinite)
        #expect(abs(chart.y(price: price(5_000)) - 120) < 1e-9)
    }

    @Test func theRangeIsWidenedByAnyOfTheFourPricesBeingTheExtreme() {
        let fields: [WritableKeyPath<Candle, Price>] = [\.open, \.high, \.low, \.close]
        #expect(fields.count == 4)
        for field in fields {
            var tall = flat(5_000)
            tall[keyPath: field] = price(9_000)
            var short = flat(5_000)
            short[keyPath: field] = price(1_000)
            // 1,000 to 9,000 is 8,000 wide: a twentieth is 400, more than the 25 of a tick.
            #expect(ChartLayout.paddedRange(of: [tall, short][...]) == price(600)...price(9_400), "\(field)")
        }
    }

    @Test func aCandleWithHighBelowLowIsTakenAsItCame() {
        let candles = [
            candle(open: 3_500, high: 3_420, low: 3_410, close: 3_415),
            candle(open: 3_415, high: 3_300, low: 3_420, close: 3_418),
        ]
        // 3,300 to 3,500 is 200 wide: a twentieth is 10, less than the 25 of a tick at 35.00.
        #expect(ChartLayout.paddedRange(of: candles[...]) == price(3_275)...price(3_525))
    }

    @Test func theRangeIsWidenedByATwentiethOfTheSpanWhenThatIsMoreThanATick() {
        let candles = [candle(open: 10_000, high: 20_000, low: 10_000, close: 15_000)]
        // 10,000 wide: a twentieth is 500, more than the 100 of a tick at 200.00.
        #expect(ChartLayout.paddedRange(of: candles[...]) == price(9_500)...price(20_500))
    }

    @Test func theRangeIsWidenedByTheTickOfTheHighestPriceWhenTheSpanIsSmall() {
        // The tick at 100.10 is 50 and at 99.90 it is 25: the highest price says which one is used.
        let candles = [candle(open: 9_990, high: 10_010, low: 9_990, close: 10_000)]
        #expect(ChartLayout.paddedRange(of: candles[...]) == price(9_940)...price(10_060))
    }

    @Test func theLowerEndNeverGoesBelowZero() {
        let candles = [candle(open: 10, high: 20_000, low: 10, close: 5_000)]
        // A twentieth of the 19,990 span is 999: 10 - 999 is below zero.
        #expect(ChartLayout.paddedRange(of: candles[...]) == price(0)...price(20_999))
    }

    @Test func aRangeAtTheTopOfInt64KeepsItsWidthOnTheLowSide() {
        let range = ChartLayout.paddedRange(of: [flat(Int64.max)][...])
        // The upper end cannot grow past the bound, and the lower end still has the padding of a tick of 200.
        #expect(range.lowerBound < range.upperBound)
        #expect(range == price(Int64.max - 200)...price(Int64.max))
        let chart = ChartLayout(size: CGSize(width: 400, height: 300), visibleCount: 30, priceRange: range)
        #expect(chart.y(price: price(Int64.max)).isFinite)
        #expect(chart.y(price: price(Int64.max)) == 0)
    }

    @Test func aRangeAtTheBottomOfInt64HasAWidthToo() {
        let range = ChartLayout.paddedRange(of: [flat(Int64.min)][...])
        #expect(range.lowerBound < range.upperBound)
        #expect(range.lowerBound.satang >= 0)
    }

    @Test func pricesBelowZeroStillGiveARangeThatIsNotBelowZero() {
        let range = ChartLayout.paddedRange(of: [candle(open: -100, high: -50, low: -100, close: -60)][...])
        #expect(range.lowerBound.satang >= 0)
        #expect(range.lowerBound < range.upperBound)
    }

    @Test func aSeriesThatSpansAllOfInt64DoesNotTrap() {
        let candles = [candle(open: Int64.min, high: Int64.max, low: Int64.min, close: Int64.max)]
        let range = ChartLayout.paddedRange(of: candles[...])
        #expect(range == price(0)...price(Int64.max))
    }

    @Test func theRangeOfASliceIsTheRangeOfThatSliceOnly() {
        let candles = [flat(100_000), flat(3_425), flat(3_430), flat(1)]
        let window = ChartLayout.paddedRange(of: candles[1...2])
        // 3,425 to 3,430 is 5 wide: a tick of 25 is the padding.
        #expect(window == price(3_400)...price(3_455))
    }
}

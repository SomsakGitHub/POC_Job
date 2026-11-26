import Testing
import TradeCore

private func price(_ satang: Int64) -> Price {
    Price(satang: satang)
}

private func requireSendable<T: Sendable>(_: T.Type) {}

/// A realistic epoch-millisecond timestamp that starts a bucket for every interval (it is a multiple of 1 s, 1 min and
/// 5 min), so `base + n` is `n` ms into a fresh bucket whichever interval a test uses.
private let base: Int64 = 1_700_000_100_000

/// A candle that opened with a single trade: open, high, low and close are all that price.
private func opened(at openTimeMs: Int64, price satang: Int64, volume: Int64) -> Candle {
    Candle(
        openTimeMs: openTimeMs, open: price(satang), high: price(satang), low: price(satang), close: price(satang),
        volume: volume
    )
}

struct CandleIntervalTests {
    @Test func casesAreOneSecondOneMinuteFiveMinutesInThatOrder() {
        #expect(CandleInterval.allCases == [.s1, .m1, .m5])
    }

    @Test(arguments: [
        (CandleInterval.s1, 1, "1s"),
        (.m1, 60, "1m"),
        (.m5, 300, "5m"),
    ] as [(CandleInterval, Int, String)])
    func secondsEqualTheRawValueAndTheLabelIsTheShortName(interval: CandleInterval, seconds: Int, label: String) {
        #expect(interval.seconds == seconds)
        #expect(interval.seconds == interval.rawValue)
        #expect(interval.label == label)
    }

    /// The start of the bucket is `ms - ms % width`.
    @Test(arguments: [
        // Inside the first bucket, on the boundary, and one millisecond either side of it.
        (CandleInterval.s1, 0, 0),
        (.s1, 1, 0),
        (.s1, 999, 0),
        (.s1, 1000, 1000),
        (.s1, 1001, 1000),
        (.m1, 59_999, 0),
        (.m1, 60_000, 60_000),
        (.m1, 60_001, 60_000),
        (.m5, 299_999, 0),
        (.m5, 300_000, 300_000),
        (.m5, 300_001, 300_000),
        // Real epoch milliseconds.
        (.s1, 1_700_000_000_999, 1_700_000_000_000),
        (.s1, 1_700_000_059_999, 1_700_000_059_000),
        (.m1, 1_700_000_000_000, 1_699_999_980_000),
        (.m1, 1_700_000_059_999, 1_700_000_040_000),
        (.m5, 1_700_000_000_000, 1_699_999_800_000),
        (.m5, 1_700_000_300_000, 1_700_000_100_000),
    ] as [(CandleInterval, Int64, Int64)])
    func bucketStartIsTheTimeMinusTheRemainderOfTheWidth(interval: CandleInterval, ms: Int64, expected: Int64) {
        #expect(interval.bucketStartMs(forMs: ms) == expected)
    }

    /// The remainder keeps the sign of the dividend, so a negative time is rounded toward zero, not down: -1500 ms
    /// is in the bucket that starts at -1000, and everything from -999 to 999 is one bucket starting at 0. Real
    /// timestamps are positive; this pins the documented behaviour of the formula for the rest of the `Int64` range.
    @Test(arguments: [
        (CandleInterval.s1, -1, 0),
        (.s1, -999, 0),
        (.s1, -1000, -1000),
        (.s1, -1001, -1000),
        (.s1, -1500, -1000),
        (.m1, -59_999, 0),
        (.m1, -60_000, -60_000),
        (.m1, -60_001, -60_000),
        (.m5, -299_999, 0),
        (.m5, -300_000, -300_000),
        (.m5, -300_001, -300_000),
    ] as [(CandleInterval, Int64, Int64)])
    func negativeTimesRoundTowardZero(interval: CandleInterval, ms: Int64, expected: Int64) {
        #expect(interval.bucketStartMs(forMs: ms) == expected)
    }

    /// The subtraction moves toward zero, so it cannot overflow: the extremes of `Int64` do not trap.
    @Test(arguments: [
        (CandleInterval.s1, Int64.max, 9_223_372_036_854_775_000),
        (.s1, Int64.min, -9_223_372_036_854_775_000),
        (.m1, Int64.max, 9_223_372_036_854_720_000),
        (.m1, Int64.min, -9_223_372_036_854_720_000),
        (.m5, Int64.max, 9_223_372_036_854_600_000),
        (.m5, Int64.min, -9_223_372_036_854_600_000),
        (.s1, Int64.max - 1, 9_223_372_036_854_775_000),
        (.s1, Int64.min + 1, -9_223_372_036_854_775_000),
    ] as [(CandleInterval, Int64, Int64)])
    func extremeTimesDoNotTrap(interval: CandleInterval, ms: Int64, expected: Int64) {
        #expect(interval.bucketStartMs(forMs: ms) == expected)
    }

    /// For any time the start is a multiple of the width, within one width of the time (below it for a positive time,
    /// above it for a negative one), and a start is its own bucket start.
    @Test(arguments: CandleInterval.allCases)
    func bucketStartIsAWidthMultipleNextToTheTimeAndIdempotent(interval: CandleInterval) {
        let width = Int64(interval.seconds) * 1000
        let times: [Int64] = [
            0, 1, 999, 1000, 59_999, 60_000, 299_999, 300_000, 1_700_000_000_123, .max, .max - 1,
            -1, -999, -1500, -299_999, -300_001, -1_700_000_000_123, .min, .min + 1,
        ]
        for ms in times {
            let start = interval.bucketStartMs(forMs: ms)
            #expect(start % width == 0, "\(ms)")
            #expect((ms - start).magnitude < UInt64(width), "\(ms)")
            #expect(ms >= 0 ? start <= ms : start >= ms, "\(ms)")
            #expect(interval.bucketStartMs(forMs: start) == start, "\(ms)")
        }
    }
}

struct CandleTests {
    private let original = Candle(
        openTimeMs: 1_700_000_100_000, open: price(3425), high: price(3450), low: price(3410), close: price(3430),
        volume: 600
    )

    /// The memberwise initialiser takes the fields in declared order, each one landing in its own property.
    @Test func initStoresEachFieldWhereItBelongs() {
        #expect(original.openTimeMs == 1_700_000_100_000)
        #expect(original.open == price(3425))
        #expect(original.high == price(3450))
        #expect(original.low == price(3410))
        #expect(original.close == price(3430))
        #expect(original.volume == 600)
    }

    /// Equality covers every field: `CandleSeries` decides whether anything changed with it, so a field it skipped
    /// would be an update the chart never sees.
    @Test func equalityComparesEveryField() {
        func changing(_ change: (inout Candle) -> Void) -> Candle {
            var copy = original
            change(&copy)
            return copy
        }

        #expect(original == changing { _ in })
        #expect(original != changing { $0.openTimeMs += 1 })
        #expect(original != changing { $0.open = price(3426) })
        #expect(original != changing { $0.high = price(3451) })
        #expect(original != changing { $0.low = price(3411) })
        #expect(original != changing { $0.close = price(3431) })
        #expect(original != changing { $0.volume += 1 })
    }

    @Test func theTypesAreSendable() {
        requireSendable(CandleInterval.self)
        requireSendable(Candle.self)
        requireSendable(CandleAggregator.self)
    }
}

struct CandleAggregatorTests {
    @Test func startsWithoutACandle() {
        #expect(CandleAggregator(interval: .s1).current == nil)
    }

    @Test func theFirstTradeOpensTheCandleAndClosesNothing() {
        var aggregator = CandleAggregator(interval: .s1)

        #expect(aggregator.add(price: price(3425), quantity: 100, atMs: base + 250) == nil)

        #expect(aggregator.current == opened(at: base, price: 3425, volume: 100))
    }

    /// Three trades inside one second make one candle: open is the first price, high and low the extremes, close the
    /// last, volume the sum, and no call closes anything.
    @Test func threeTradesInsideOneSecondFormOneCandle() {
        var aggregator = CandleAggregator(interval: .s1)

        let closed = [
            aggregator.add(price: price(3425), quantity: 100, atMs: base + 100),
            aggregator.add(price: price(3450), quantity: 200, atMs: base + 400),
            aggregator.add(price: price(3410), quantity: 300, atMs: base + 900),
        ]

        #expect(closed == [nil, nil, nil])
        #expect(
            aggregator.current
                == Candle(
                    openTimeMs: base, open: price(3425), high: price(3450), low: price(3410), close: price(3410),
                    volume: 600
                )
        )
    }

    /// Open is the first price and close the last even when neither is an extreme: all four prices here differ.
    @Test func openAndCloseAreTheFirstAndLastPriceNotTheExtremes() {
        var aggregator = CandleAggregator(interval: .s1)

        for (offset, satang) in [(100, 3430), (200, 3450), (300, 3400), (400, 3420)] as [(Int64, Int64)] {
            #expect(aggregator.add(price: price(satang), quantity: 10, atMs: base + offset) == nil)
        }

        #expect(
            aggregator.current
                == Candle(
                    openTimeMs: base, open: price(3430), high: price(3450), low: price(3400), close: price(3420),
                    volume: 40
                )
        )
    }

    /// Within one bucket the order of the calls decides open and close; `atMs` only picks the bucket.
    @Test func withinABucketTheOrderOfCallsNotTheTimestampDecidesOpenAndClose() {
        var aggregator = CandleAggregator(interval: .s1)
        _ = aggregator.add(price: price(3450), quantity: 100, atMs: base + 800)

        #expect(aggregator.add(price: price(3410), quantity: 100, atMs: base + 100) == nil)

        #expect(
            aggregator.current
                == Candle(
                    openTimeMs: base, open: price(3450), high: price(3450), low: price(3410), close: price(3410),
                    volume: 200
                )
        )
    }

    /// The trade that opens the next bucket returns the candle that just closed, unchanged by that trade, and starts
    /// the next one.
    @Test func theFirstTradeOfTheNextSecondReturnsThePreviousCandle() {
        var aggregator = CandleAggregator(interval: .s1)
        _ = aggregator.add(price: price(3425), quantity: 100, atMs: base + 100)
        _ = aggregator.add(price: price(3450), quantity: 200, atMs: base + 400)
        _ = aggregator.add(price: price(3410), quantity: 300, atMs: base + 900)

        let closed = aggregator.add(price: price(3440), quantity: 500, atMs: base + 1000)

        #expect(
            closed
                == Candle(
                    openTimeMs: base, open: price(3425), high: price(3450), low: price(3410), close: price(3410),
                    volume: 600
                )
        )
        #expect(aggregator.current == opened(at: base + 1000, price: 3440, volume: 500))
    }

    /// The last millisecond of a bucket is still in it; the first millisecond of the next one closes it.
    @Test(arguments: CandleInterval.allCases)
    func aTradeOnTheBucketBoundaryBelongsToTheNextCandle(interval: CandleInterval) {
        let width = Int64(interval.seconds) * 1000
        var aggregator = CandleAggregator(interval: interval)
        _ = aggregator.add(price: price(3425), quantity: 100, atMs: base)

        #expect(aggregator.add(price: price(3430), quantity: 100, atMs: base + width - 1) == nil)
        #expect(aggregator.current?.openTimeMs == base)

        let closed = aggregator.add(price: price(3440), quantity: 100, atMs: base + width)
        #expect(closed?.openTimeMs == base)
        #expect(closed?.close == price(3430))
        #expect(closed?.volume == 200)
        #expect(aggregator.current == opened(at: base + width, price: 3440, volume: 100))
    }

    /// A quiet stretch yields one close and no candles for the empty buckets in between. (For one second this is the
    /// five-second gap.)
    @Test(arguments: CandleInterval.allCases)
    func aGapOfFiveBucketsYieldsNoPhantomCandles(interval: CandleInterval) {
        let width = Int64(interval.seconds) * 1000
        var aggregator = CandleAggregator(interval: interval)
        var closed: [Candle] = []

        let trades = [(0, 3425), (width / 2, 3430), (5 * width, 3440), (5 * width + 1, 3435)] as [(Int64, Int64)]
        for (offset, satang) in trades {
            if let candle = aggregator.add(price: price(satang), quantity: 100, atMs: base + offset) {
                closed.append(candle)
            }
        }

        #expect(
            closed == [
                Candle(
                    openTimeMs: base, open: price(3425), high: price(3430), low: price(3425), close: price(3430),
                    volume: 200
                )
            ]
        )
        #expect(
            aggregator.current
                == Candle(
                    openTimeMs: base + 5 * width, open: price(3440), high: price(3440), low: price(3435),
                    close: price(3435), volume: 200
                )
        )
    }

    /// Trades arrive in time order. One for an earlier bucket than the current candle is late: it returns nil, changes
    /// nothing, and creates nothing backwards.
    @Test func aTradeForAnEarlierBucketIsIgnored() {
        var aggregator = CandleAggregator(interval: .s1)
        _ = aggregator.add(price: price(3425), quantity: 100, atMs: base + 3000)
        let before = aggregator.current

        // One bucket earlier, several, the epoch, a negative time, and the earliest time there is.
        for late in [base + 2999, base + 1000, base, 0, -1, Int64.min] {
            #expect(aggregator.add(price: price(9999), quantity: 999, atMs: late) == nil)
            #expect(aggregator.current == before)
        }

        // The candle is intact and still accepts trades.
        #expect(aggregator.add(price: price(3430), quantity: 50, atMs: base + 3500) == nil)
        #expect(aggregator.current?.close == price(3430))
        #expect(aggregator.current?.volume == 150)
    }

    /// Volume saturates at `Int64.max` instead of wrapping to a negative number.
    @Test func volumeSaturatesAtInt64MaxInsteadOfWrapping() {
        var aggregator = CandleAggregator(interval: .s1)
        _ = aggregator.add(price: price(3425), quantity: Int64.max - 5, atMs: base)
        #expect(aggregator.current?.volume == Int64.max - 5)

        _ = aggregator.add(price: price(3425), quantity: 3, atMs: base + 1)
        #expect(aggregator.current?.volume == Int64.max - 2)

        // Three more would make Int64.max + 1.
        _ = aggregator.add(price: price(3425), quantity: 3, atMs: base + 2)
        #expect(aggregator.current?.volume == Int64.max)

        _ = aggregator.add(price: price(3425), quantity: Int64.max, atMs: base + 3)
        #expect(aggregator.current?.volume == Int64.max)

        // A new bucket starts from the quantity alone.
        _ = aggregator.add(price: price(3425), quantity: 7, atMs: base + 1000)
        #expect(aggregator.current?.volume == 7)
    }

    /// A quantity of zero or less adds no volume, so volume never decreases. The trade's price still counts: it opens a
    /// candle, moves the extremes and sets the close like any other.
    @Test(arguments: [0, -1, -100, Int64.min] as [Int64])
    func aQuantityOfZeroOrLessAddsNoVolumeButTheTradeStillCounts(quantity: Int64) {
        var aggregator = CandleAggregator(interval: .s1)
        _ = aggregator.add(price: price(3425), quantity: 100, atMs: base)

        #expect(aggregator.add(price: price(3440), quantity: quantity, atMs: base + 1) == nil)
        #expect(
            aggregator.current
                == Candle(
                    openTimeMs: base, open: price(3425), high: price(3440), low: price(3425), close: price(3440),
                    volume: 100
                )
        )

        // As the first trade of a candle it opens one with no volume.
        let closed = aggregator.add(price: price(3450), quantity: quantity, atMs: base + 1000)
        #expect(closed?.volume == 100)
        #expect(aggregator.current == opened(at: base + 1000, price: 3450, volume: 0))
    }

    /// Nothing traps at the extremes of `Int64`: earliest then latest time, smallest and largest price and quantity.
    @Test func extremeInputsDoNotTrap() {
        var aggregator = CandleAggregator(interval: .s1)
        #expect(aggregator.add(price: price(.min), quantity: .max, atMs: .min) == nil)

        let closed = aggregator.add(price: price(.max), quantity: .max, atMs: .max)
        #expect(closed == opened(at: -9_223_372_036_854_775_000, price: .min, volume: .max))
        #expect(aggregator.current == opened(at: 9_223_372_036_854_775_000, price: .max, volume: .max))

        // Both price extremes inside one bucket.
        #expect(aggregator.add(price: price(.min), quantity: .max, atMs: .max) == nil)
        #expect(
            aggregator.current
                == Candle(
                    openTimeMs: 9_223_372_036_854_775_000, open: price(.max), high: price(.max), low: price(.min),
                    close: price(.min), volume: .max
                )
        )
    }
}

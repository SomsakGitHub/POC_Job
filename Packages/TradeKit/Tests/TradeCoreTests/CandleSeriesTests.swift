import Testing
import TradeCore

private func price(_ satang: Int64) -> Price {
    Price(satang: satang)
}

private func requireSendable<T: Sendable>(_: T.Type) {}

/// A candle that opens at `second` (in seconds, so a test reads as a timeline). `close` tells candles apart: the same
/// `second` and `close` make equal candles, a different `close` is a changed candle (high and low follow it).
private func candle(_ second: Int64, close: Int64 = 100, volume: Int64 = 10) -> Candle {
    Candle(
        openTimeMs: second * 1000,
        open: price(100),
        high: price(max(100, close)),
        low: price(min(100, close)),
        close: price(close),
        volume: volume
    )
}

/// A candle opening at 1 s with every field set explicitly, to build variants that differ in one field.
private func withFields(
    open: Int64 = 100, high: Int64 = 120, low: Int64 = 90, close: Int64 = 110, volume: Int64 = 50
) -> Candle {
    Candle(
        openTimeMs: 1000, open: price(open), high: price(high), low: price(low), close: price(close), volume: volume
    )
}

/// The timeline of a series: the open time of each candle, in seconds.
private func seconds(_ candles: [Candle]) -> [Int64] {
    candles.map { $0.openTimeMs / 1000 }
}

private func isAscending(_ candles: [Candle]) -> Bool {
    zip(candles, candles.dropFirst()).allSatisfy { $0.openTimeMs < $1.openTimeMs }
}

struct CandleSeriesTests {
    // MARK: A new series

    @Test func aNewSeriesIsEmptyAtVersionZero() {
        let series = CandleSeries(interval: .m1)

        #expect(series.all.isEmpty)
        #expect(series.version == 0)
        #expect(series.interval == .m1)
    }

    /// The default capacity is 1000 candles: the newest 1000 of a longer history.
    @Test func theDefaultCapacityIs1000() {
        var series = CandleSeries(interval: .s1)

        series.seed(history: (1...1200).map { candle($0) })

        #expect(series.all.count == 1000)
        #expect(series.all.first == candle(201))
        #expect(series.all.last == candle(1200))
    }

    // MARK: Seed, then apply

    @Test func seedThenApplyWithTheSameOpenTimeReplacesTheLastCandle() {
        var series = CandleSeries(interval: .s1, capacity: 10)
        series.seed(history: [candle(1), candle(2), candle(3)])
        #expect(series.all == [candle(1), candle(2), candle(3)])

        series.apply(current: candle(3, close: 150))

        #expect(series.all == [candle(1), candle(2), candle(3, close: 150)])
    }

    /// A later open time appends. The candle that was in progress is closed with the last state it had.
    @Test func applyWithALaterOpenTimeAppends() {
        var series = CandleSeries(interval: .s1, capacity: 10)
        series.seed(history: [candle(1), candle(2), candle(3)])
        series.apply(current: candle(3, close: 120))

        series.apply(current: candle(4))
        #expect(series.all == [candle(1), candle(2), candle(3, close: 120), candle(4)])

        // A gap is not filled in: the open times only have to increase.
        series.apply(current: candle(9))
        #expect(seconds(series.all) == [1, 2, 3, 4, 9])
    }

    /// An earlier open time is ignored, whether it is for a candle already closed or for one never seen: closed
    /// candles are final.
    @Test(arguments: [3, 2, 1, 0, -5, Int64.min / 1000] as [Int64])
    func applyWithAnEarlierOpenTimeIsIgnored(second: Int64) {
        var series = CandleSeries(interval: .s1, capacity: 10)
        series.seed(history: [candle(2), candle(3), candle(4)])
        let versionBefore = series.version

        series.apply(current: candle(second, close: 999))

        #expect(series.all == [candle(2), candle(3), candle(4)])
        #expect(series.version == versionBefore)
    }

    @Test func seedEmptyThenApplyWorks() {
        var series = CandleSeries(interval: .s1, capacity: 3)

        series.seed(history: [])
        #expect(series.all.isEmpty)

        series.apply(current: candle(5))
        #expect(series.all == [candle(5)])

        series.apply(current: candle(5, close: 120))
        #expect(series.all == [candle(5, close: 120)])

        series.apply(current: candle(6))
        #expect(series.all == [candle(5, close: 120), candle(6)])
    }

    /// Applying to a series that was never seeded works the same: the first candle is the one in progress.
    @Test func applyOnASeriesThatWasNeverSeededWorks() {
        var series = CandleSeries(interval: .s1, capacity: 3)

        series.apply(current: candle(5))
        series.apply(current: candle(5, close: 120))
        series.apply(current: candle(6))

        #expect(series.all == [candle(5, close: 120), candle(6)])
    }

    /// Seeding with nothing clears the series, and nothing is "in progress" afterwards: the next candle is accepted
    /// even if it is older than what was there before.
    @Test func seedEmptyClearsAPopulatedSeriesAndTheNextApplyStartsAgain() {
        var series = CandleSeries(interval: .s1, capacity: 5)
        series.seed(history: [candle(7), candle(8), candle(9)])

        series.seed(history: [])
        #expect(series.all.isEmpty)

        series.apply(current: candle(2))
        #expect(series.all == [candle(2)])
    }

    /// `seed` replaces everything, and its last candle is the one in progress.
    @Test func seedReplacesEverythingAndTheLastSeededCandleIsInProgress() {
        var series = CandleSeries(interval: .s1, capacity: 10)
        series.seed(history: [candle(1), candle(2), candle(3)])

        series.seed(history: [candle(10), candle(11)])
        #expect(series.all == [candle(10), candle(11)])

        series.apply(current: candle(11, close: 130))
        #expect(series.all == [candle(10), candle(11, close: 130)])
    }

    /// Seeding over an updated series puts the history back: what `apply` changed is gone.
    @Test func seedOverwritesWhatApplyChanged() {
        var series = CandleSeries(interval: .s1, capacity: 10)
        series.seed(history: [candle(1), candle(2), candle(3)])
        series.apply(current: candle(3, close: 140))
        series.apply(current: candle(4))

        series.seed(history: [candle(1), candle(2), candle(3)])

        #expect(series.all == [candle(1), candle(2), candle(3)])
    }

    // MARK: Version

    /// Version starts at 0 and counts the changes to `all`: one step for each operation that altered it, none for an
    /// operation that left it as it was.
    @Test func versionChangesOnlyWhenTheContentChanges() {
        var series = CandleSeries(interval: .s1, capacity: 5)
        #expect(series.version == 0)

        series.seed(history: [])
        #expect(series.version == 0, "nothing to nothing")

        series.seed(history: [candle(1), candle(2), candle(3)])
        #expect(series.version == 1, "nothing to three candles")

        series.seed(history: [candle(1), candle(2), candle(3)])
        #expect(series.version == 1, "seeding what is already there")

        series.apply(current: candle(3))
        #expect(series.version == 1, "applying the candle that is already in progress")

        series.apply(current: candle(3, close: 120))
        #expect(series.version == 2, "the in-progress candle changed")

        series.apply(current: candle(3, close: 120))
        #expect(series.version == 2, "the same update again")

        series.apply(current: candle(2, close: 500))
        #expect(series.version == 2, "an earlier candle is ignored")

        series.apply(current: candle(4))
        #expect(series.version == 3, "a later candle is appended")

        series.seed(history: [])
        #expect(series.version == 4, "cleared")

        series.seed(history: [])
        #expect(series.version == 4, "already empty")

        series.apply(current: candle(1))
        #expect(series.version == 5, "the first candle of an empty series")
    }

    /// Same open time, but the candle differs in one field from the one in progress: that is a change, and the volume
    /// counts as much as a price. A series that only watched the prices would never tell the chart about a trade that
    /// moved nothing but volume.
    @Test(arguments: [
        ("open", withFields(open: 101)),
        ("high", withFields(high: 121)),
        ("low", withFields(low: 89)),
        ("close", withFields(close: 111)),
        ("volume", withFields(volume: 51)),
    ] as [(String, Candle)])
    func aChangeInAnySingleFieldBumpsTheVersion(field: String, changed: Candle) {
        var series = CandleSeries(interval: .s1, capacity: 5)
        series.seed(history: [withFields()])
        #expect(series.version == 1)

        series.apply(current: changed)

        #expect(series.all == [changed], "\(field)")
        #expect(series.version == 2, "\(field)")
    }

    /// What is compared is what the series would keep, not what was passed: a longer history whose newest candles are
    /// the ones already held changes nothing.
    @Test func seedingALongerHistoryWithTheSameNewestCandlesLeavesTheVersion() {
        var series = CandleSeries(interval: .s1, capacity: 3)
        series.seed(history: [candle(3), candle(4), candle(5)])
        #expect(series.version == 1)

        series.seed(history: [candle(1), candle(2), candle(3), candle(4), candle(5)])

        #expect(seconds(series.all) == [3, 4, 5])
        #expect(series.version == 1)
    }

    // MARK: Capacity

    /// A capacity of one holds only the candle in progress: closing it just drops it.
    @Test func capacityOneHoldsOnlyTheCandleInProgress() {
        var series = CandleSeries(interval: .s1, capacity: 1)

        series.seed(history: [candle(1), candle(2), candle(3)])
        #expect(series.all == [candle(3)])

        series.apply(current: candle(3, close: 120))
        #expect(series.all == [candle(3, close: 120)])

        series.apply(current: candle(4))
        #expect(series.all == [candle(4)])

        series.apply(current: candle(2))
        #expect(series.all == [candle(4)])

        series.apply(current: candle(5))
        series.apply(current: candle(6))
        #expect(series.all == [candle(6)])
    }

    /// The in-progress candle counts toward the capacity: with two, one closed candle and the one in progress.
    @Test func capacityTwoHoldsOneClosedCandleAndTheOneInProgress() {
        var series = CandleSeries(interval: .s1, capacity: 2)

        series.seed(history: [candle(1), candle(2), candle(3)])
        #expect(series.all == [candle(2), candle(3)])

        series.apply(current: candle(3, close: 120))
        #expect(series.all == [candle(2), candle(3, close: 120)])

        series.apply(current: candle(4))
        #expect(series.all == [candle(3, close: 120), candle(4)])

        series.apply(current: candle(5))
        #expect(series.all == [candle(4), candle(5)])
    }

    @Test func aHistoryExactlyAtCapacityKeepsAllOfIt() {
        var series = CandleSeries(interval: .s1, capacity: 3)

        series.seed(history: [candle(1), candle(2), candle(3)])
        #expect(series.all == [candle(1), candle(2), candle(3)])

        series.apply(current: candle(4))
        #expect(series.all == [candle(2), candle(3), candle(4)])
    }

    @Test func aHistoryShorterThanTheCapacityKeepsAllOfIt() {
        var series = CandleSeries(interval: .s1, capacity: 5)

        series.seed(history: [candle(1), candle(2)])
        #expect(series.all == [candle(1), candle(2)])

        series.apply(current: candle(3))
        #expect(series.all == [candle(1), candle(2), candle(3)])
    }

    /// Only the newest `capacity` candles of a longer history are kept, and the last of them is in progress.
    @Test func aHistoryLongerThanTheCapacityKeepsTheNewestCandles() {
        var series = CandleSeries(interval: .s1, capacity: 3)

        series.seed(history: (1...5).map { candle($0) })
        #expect(series.all == [candle(3), candle(4), candle(5)])

        series.apply(current: candle(5, close: 120))
        #expect(series.all == [candle(3), candle(4), candle(5, close: 120)])

        series.apply(current: candle(6))
        #expect(series.all == [candle(4), candle(5, close: 120), candle(6)])
    }

    /// A capacity below 1 is clamped to 1, like the ring buffer's.
    @Test(arguments: [0, -1, Int.min])
    func aCapacityBelowOneIsClampedToOne(capacity: Int) {
        var series = CandleSeries(interval: .s1, capacity: capacity)

        series.seed(history: [candle(1), candle(2), candle(3)])
        #expect(series.all == [candle(3)])

        series.apply(current: candle(4))
        #expect(series.all == [candle(4)])
    }

    /// An enormous capacity allocates nothing up front and never trims.
    @Test func aHugeCapacityKeepsEverything() {
        var series = CandleSeries(interval: .s1, capacity: .max)

        series.seed(history: [candle(1), candle(2), candle(3)])
        series.apply(current: candle(4))

        #expect(seconds(series.all) == [1, 2, 3, 4])
    }

    /// Whatever the capacity and however the series is fed, it never holds more than the capacity and stays ascending
    /// by open time, with the newest applied candle last.
    @Test(arguments: [1, 2, 3, 5, 8])
    func neverHoldsMoreThanTheCapacityAndStaysAscending(capacity: Int) {
        var series = CandleSeries(interval: .s1, capacity: capacity)

        series.seed(history: (1...20).map { candle($0) })
        #expect(series.all.count == capacity)
        #expect(isAscending(series.all))
        #expect(series.all.last == candle(20))

        for second in 21...60 {
            series.apply(current: candle(Int64(second)))
            series.apply(current: candle(Int64(second), close: 130))
            series.apply(current: candle(Int64(second) - 3))

            #expect(series.all.count == capacity, "after \(second)")
            #expect(isAscending(series.all), "after \(second)")
            #expect(series.all.last == candle(Int64(second), close: 130), "after \(second)")
        }

        series.seed(history: (100...130).map { candle($0) })
        #expect(series.all.count == capacity)
        #expect(isAscending(series.all))
        #expect(series.all.last == candle(130))
    }

    // MARK: Input that breaks the contract

    /// The server sends history ascending by open time. Anything else is kept as given (the last `capacity` candles, in
    /// the order received) without sorting and without trapping, including duplicates.
    @Test func historyThatIsNotAscendingIsKeptAsGivenWithoutTrapping() {
        var series = CandleSeries(interval: .s1, capacity: 3)

        series.seed(history: [candle(5), candle(1), candle(4), candle(2), candle(3)])
        #expect(seconds(series.all) == [4, 2, 3])

        series.seed(history: [candle(2), candle(2), candle(2)])
        #expect(seconds(series.all) == [2, 2, 2])

        // Later and earlier are still judged against the last candle.
        series.apply(current: candle(3))
        #expect(seconds(series.all) == [2, 2, 3])
        series.apply(current: candle(1))
        #expect(seconds(series.all) == [2, 2, 3])
    }

    @Test func extremeOpenTimesDoNotTrap() {
        var series = CandleSeries(interval: .s1, capacity: 2)
        let earliest = Candle(
            openTimeMs: .min, open: price(.min), high: price(.max), low: price(.min), close: price(0), volume: .max
        )
        let latest = Candle(
            openTimeMs: .max, open: price(.max), high: price(.max), low: price(.min), close: price(0), volume: .min
        )

        series.apply(current: earliest)
        series.apply(current: latest)
        series.apply(current: earliest)

        #expect(series.all == [earliest, latest])
    }

    @Test func theSeriesIsSendable() {
        requireSendable(CandleSeries.self)
    }
}

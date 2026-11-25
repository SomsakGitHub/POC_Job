import Contracts
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// What the detail screen's model loads and shows: the history of the chosen interval, the live candle on top of it,
/// and which of several answers to a request for history is allowed to count. The gap reloads are in
/// `StockDetailGapReloadTests` and the state the views read in `StockDetailStateTests`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StockDetailViewModelTests {
    // MARK: History

    @Test func historySeedsSeries() async {
        let rest = FakeRest(candles: [.candles(history(count: 300))])
        let rig = ModelRig(rest: rest)
        #expect(rig.model.series.all.isEmpty)

        await rig.model.loadHistory()

        #expect(rig.model.series.all.count == 300)
        #expect(rig.model.series.all == history(count: 300))
        // The history is asked for by the ticker, for the model's interval, 300 candles deep.
        #expect(rest.candleCalls == [FakeRest.CandleCall(ticker: "PTT", interval: .m1, limit: 300)])
        #expect(!rig.model.isLoading)
        #expect(!rig.model.loadFailed)
    }

    @Test func theLiveCandleIsAppliedRightAfterTheHistoryIsSeeded() async {
        let past = history(count: 300)
        let rig = ModelRig(rest: FakeRest(candles: [.candles(past)]))
        // The feed is already past the newest candle of the history.
        let live = candle(openTimeMs: past[299].openTimeMs + 60_000, close: 3_777)
        rig.market.feed(candle1m: live)

        await rig.model.loadHistory()

        #expect(rig.model.series.all.count == 301)
        #expect(rig.model.series.all.last == live)
    }

    @Test func aReloadWithFewerCandlesHoldsThePanInsideTheNewRoom() async {
        let rest = FakeRest(candles: [.candles(history(count: 300)), .candles(history(count: 100))])
        let rig = ModelRig(rest: rest)
        await rig.model.loadHistory()
        rig.model.panOffset = 200
        #expect(rig.model.panOffset == 200)

        await rig.model.loadHistory()

        // 100 candles with 60 in view leave room to go back by 40.
        #expect(rig.model.series.all.count == 100)
        #expect(rig.model.panOffset == 40)
    }

    @Test func anEmptyHistoryEmptiesTheSeries() async {
        let rig = ModelRig(rest: FakeRest(candles: [.candles(history(count: 10)), .candles([])]))
        await rig.model.loadHistory()
        #expect(rig.model.series.all.count == 10)

        await rig.model.loadHistory()

        #expect(rig.model.series.all.isEmpty)
        #expect(!rig.model.loadFailed)
    }

    // MARK: The live candle

    @Test func liveCandleReplacesLast() async {
        let past = history(count: 300)
        let rig = ModelRig(rest: FakeRest(candles: [.candles(past)]))
        await rig.model.loadHistory()
        let last = past[299]
        let updated = Candle(
            openTimeMs: last.openTimeMs, open: last.open, high: satang(3_999), low: last.low, close: satang(3_950),
            volume: 777
        )

        rig.market.feed(candle1m: updated)
        rig.model.refreshFromState()

        #expect(rig.model.series.all.count == 300)
        #expect(rig.model.series.all.last == updated)
        #expect(rig.model.series.all.dropLast() == past.dropLast())

        // A later candle starts a new bar, and the one before it is closed as it last was.
        let next = candle(openTimeMs: last.openTimeMs + 60_000, close: 3_960)
        rig.market.feed(candle1m: next)
        rig.model.refreshFromState()

        #expect(rig.model.series.all.count == 301)
        #expect(rig.model.series.all.suffix(2) == [updated, next])
    }

    @Test func laterCandleAppends() async {
        let past = history(count: 300)
        let rig = ModelRig(rest: FakeRest(candles: [.candles(past)]))
        await rig.model.loadHistory()
        // Three candles later than the newest one: gaps are not filled in, each one is simply the newest.
        let next = candle(openTimeMs: past[299].openTimeMs + 60_000)
        let later = candle(openTimeMs: past[299].openTimeMs + 240_000)

        rig.market.feed(candle1m: next)
        rig.model.refreshFromState()
        rig.market.feed(candle1m: later)
        rig.model.refreshFromState()

        #expect(rig.model.series.all.count == 302)
        #expect(rig.model.series.all.suffix(2) == [next, later])
        #expect(rig.model.series.all.prefix(300) == past[...])
    }

    @Test func staleSnapshotIgnored() async {
        let past = history(count: 300)
        let rig = ModelRig(rest: FakeRest(candles: [.candles(past)]))
        await rig.model.loadHistory()
        let before = rig.model.series.version

        // A late update of a candle that closed long ago changes nothing.
        rig.market.feed(candle1m: candle(openTimeMs: past[298].openTimeMs, close: 3_001))
        rig.model.refreshFromState()

        #expect(rig.model.series.all == past)
        #expect(rig.model.series.version == before)

        // The same model does take a current candle, so the test above is not an effect of refreshing doing nothing.
        rig.market.feed(candle1m: candle(openTimeMs: past[299].openTimeMs, close: 3_002))
        rig.model.refreshFromState()
        #expect(rig.model.series.all.last?.close == satang(3_002))
    }

    @Test func zeroCandleIsNotApplied() async {
        let past = history(count: 300)
        let rig = ModelRig(rest: FakeRest(candles: [.candles(past)]))

        // Before the history: a candle of all zeros is the feed saying nothing yet, not a bar at the epoch.
        rig.market.feed(last: 3_450, candle1m: noCandle)
        rig.model.refreshFromState()
        #expect(rig.model.series.all.isEmpty)
        // Nor is a candle that opens at a negative time.
        rig.market.feed(last: 3_451, candle1m: candle(openTimeMs: -60_000))
        rig.model.refreshFromState()
        #expect(rig.model.series.all.isEmpty)

        // After the history is seeded, the snapshot still holds that candle and it still adds nothing.
        await rig.model.loadHistory()
        #expect(rig.model.series.all == past)

        // A candle with an open time does go in.
        rig.market.feed(candle1m: candle(openTimeMs: past[299].openTimeMs + 60_000))
        rig.model.refreshFromState()
        #expect(rig.model.series.all.count == 301)
    }

    @Test func aSnapshotThatSaysNothingAboutACandleLeavesItAlone() async {
        let rig = ModelRig(rest: FakeRest(candles: [.candles(history(count: 10))]))
        await rig.model.loadHistory()
        // An update with no candles at all (the fields are not set): the price is taken, the candles are left alone.
        rig.market.feed(last: 3_500)
        rig.model.refreshFromState()
        #expect(rig.model.lastPrice == satang(3_500))
        #expect(rig.model.series.all == history(count: 10))
    }

    @Test func theCandleOfTheModelsOwnIntervalIsTheOneThatIsApplied() async {
        #expect(CandleInterval.allCases.count == 3)
        for interval in CandleInterval.allCases {
            let past = history(count: 30, interval: interval)
            let rig = ModelRig(interval: interval, rest: FakeRest(candles: [.candles(past)]))
            await rig.model.loadHistory()
            let next = past[29].openTimeMs + Int64(interval.seconds) * 1_000

            rig.market.feed(
                candle1s: candle(openTimeMs: next, close: 3_001), candle1m: candle(openTimeMs: next, close: 3_002),
                candle5m: candle(openTimeMs: next, close: 3_003)
            )
            rig.model.refreshFromState()

            let expected: Int64 =
                switch interval {
                case .s1: 3_001
                case .m1: 3_002
                case .m5: 3_003
                }
            #expect(rig.model.series.all.count == 31, "\(interval.label)")
            #expect(rig.model.series.all.last?.close == satang(expected), "\(interval.label)")
        }
    }

    @Test func aSnapshotOfAnotherSymbolChangesNothing() async {
        let past = history(count: 10)
        let rig = ModelRig(rest: FakeRest(candles: [.candles(past)]))
        await rig.model.loadHistory()

        let next = past[9].openTimeMs + 60_000
        rig.market.feed(symbol: 2, last: 5_900, candle1m: candle(openTimeMs: next))
        rig.model.refreshFromState()

        // The market did take the update of the other symbol, and the model took nothing of it.
        #expect(rig.market.state.snapshot(2)?.candle1m.openTimeMs == next)
        #expect(rig.model.series.all == past)
        #expect(rig.model.lastPrice == nil)
    }

    // MARK: The interval

    @Test func intervalChangeReloadsHistory() async {
        let seconds = history(count: 300, interval: .s1)
        let minutes = history(count: 300, interval: .m1)
        let rest = FakeRest(candles: [.candles(seconds), .hold])
        let rig = ModelRig(interval: .s1, rest: rest)
        await rig.model.loadHistory()
        #expect(rig.model.series.all == seconds)
        rig.model.panOffset = 40
        #expect(rig.model.panOffset == 40)

        let change = Task { @MainActor in await rig.model.select(interval: .m1) }
        await waitFor("the one-minute history is asked for") { rest.heldCandleCount == 1 }

        // The seconds are gone at once, and the pan starts again from the newest candle.
        #expect(rig.model.interval == .m1)
        #expect(rig.model.series.interval == .m1)
        #expect(rig.model.series.all.isEmpty)
        #expect(rig.model.panOffset == 0)
        #expect(rig.model.isLoading)

        rest.releaseCandles(call: 1, .success(minutes))
        await change.value

        #expect(rig.model.series.all == minutes)
        #expect(rest.candleCalls.map(\.interval) == [.s1, .m1])
        #expect(!rig.model.isLoading)
    }

    @Test func slowAnswerForOldIntervalIsDropped() async {
        let seconds = history(count: 300, interval: .s1)
        let minutes = history(count: 300, interval: .m1)
        let rest = FakeRest(candles: [.hold, .hold])
        let rig = ModelRig(interval: .s1, rest: rest)
        let first = Task { @MainActor in await rig.model.loadHistory() }
        await waitFor("the seconds are asked for") { rest.heldCandleCount == 1 }
        let second = Task { @MainActor in await rig.model.select(interval: .m1) }
        await waitFor("the minutes are asked for") { rest.heldCandleCount == 2 }

        rest.releaseCandles(call: 1, .success(minutes))
        await second.value
        #expect(rig.model.series.all == minutes)
        // The answer for the old interval comes last.
        rest.releaseCandles(call: 0, .success(seconds))
        await first.value

        #expect(rig.model.series.all == minutes)
        #expect(rig.model.series.interval == .m1)
        #expect(!rig.model.isLoading)
    }

    @Test func anOldAnswerThatComesFirstIsDroppedToo() async {
        let seconds = history(count: 300, interval: .s1)
        let minutes = history(count: 300, interval: .m1)
        let rest = FakeRest(candles: [.hold, .hold])
        let rig = ModelRig(interval: .s1, rest: rest)
        let first = Task { @MainActor in await rig.model.loadHistory() }
        await waitFor("the seconds are asked for") { rest.heldCandleCount == 1 }
        let second = Task { @MainActor in await rig.model.select(interval: .m1) }
        await waitFor("the minutes are asked for") { rest.heldCandleCount == 2 }

        rest.releaseCandles(call: 0, .success(seconds))
        await first.value
        #expect(rig.model.series.all.isEmpty)
        #expect(rig.model.isLoading)

        rest.releaseCandles(call: 1, .success(minutes))
        await second.value
        #expect(rig.model.series.all == minutes)
    }

    @Test func anAnswerForAnIntervalThatWasSetByHandIsDropped() async {
        let rest = FakeRest(candles: [.hold])
        let rig = ModelRig(interval: .s1, rest: rest)
        let load = Task { @MainActor in await rig.model.loadHistory() }
        await waitFor("the seconds are asked for") { rest.heldCandleCount == 1 }

        // The interval changes with no new request at all: the answer in flight is for the wrong one.
        rig.model.interval = .m5
        rest.releaseCandles(call: 0, .success(history(count: 300, interval: .s1)))
        await load.value

        #expect(rig.model.series.interval == .m5)
        #expect(rig.model.series.all.isEmpty)
        #expect(!rig.model.isLoading)
    }

    @Test func aNewerRequestForTheSameIntervalSupersedesAnOlderOne() async {
        let older = history(count: 20)
        let newer = history(count: 25)
        let rest = FakeRest(candles: [.hold, .hold])
        let rig = ModelRig(rest: rest)
        let first = Task { @MainActor in await rig.model.loadHistory() }
        await waitFor("the first request is held") { rest.heldCandleCount == 1 }
        let second = Task { @MainActor in await rig.model.loadHistory() }
        await waitFor("the second request is held") { rest.heldCandleCount == 2 }

        rest.releaseCandles(call: 1, .success(newer))
        await second.value
        rest.releaseCandles(call: 0, .success(older))
        await first.value

        #expect(rig.model.series.all == newer)
    }

    // MARK: Failure and cancellation

    @Test func failedLoadKeepsTheSeries() async {
        let past = history(count: 300)
        let rest = FakeRest(candles: [.candles(past), .failure(TestFailure()), .candles(past)])
        let rig = ModelRig(rest: rest)
        await rig.model.loadHistory()

        await rig.model.loadHistory()

        #expect(rig.model.series.all == past)
        #expect(rig.model.loadFailed)
        #expect(!rig.model.isLoading)
        // Nothing asked again by itself: the next trigger does.
        #expect(rest.candleCalls.count == 2)

        await rig.model.loadHistory()
        #expect(!rig.model.loadFailed)
        #expect(rest.candleCalls.count == 3)
    }

    @Test func aFirstLoadThatFailsLeavesTheSeriesEmptyAndSaysSo() async {
        let rig = ModelRig(rest: FakeRest(candles: [.failure(TestFailure())]))
        await rig.model.loadHistory()
        #expect(rig.model.series.all.isEmpty)
        #expect(rig.model.loadFailed)
    }

    @Test func cancelledLoadAppliesNothing() async {
        let rest = FakeRest(candles: [.hold, .hold, .hold])
        let rig = ModelRig(rest: rest)
        let load = Task { @MainActor in await rig.model.loadHistory() }
        await waitFor("the request is held") { rest.heldCandleCount == 1 }
        #expect(rig.model.isLoading)

        load.cancel()
        rest.releaseCandles(call: 0, .success(history(count: 300)))
        await load.value

        #expect(rig.model.series.all.isEmpty)
        #expect(!rig.model.loadFailed)
        #expect(!rig.model.isLoading)

        // A request that is cancelled and then fails is not a failed load either.
        let failing = Task { @MainActor in await rig.model.loadHistory() }
        await waitFor("the second request is held") { rest.heldCandleCount == 1 }
        failing.cancel()
        rest.releaseCandles(call: 1, .failure(TestFailure()))
        await failing.value
        #expect(!rig.model.loadFailed)
        #expect(!rig.model.isLoading)

        // Control: the same request that is not cancelled does seed the series.
        let kept = Task { @MainActor in await rig.model.loadHistory() }
        await waitFor("the third request is held") { rest.heldCandleCount == 1 }
        rest.releaseCandles(call: 2, .success(history(count: 300)))
        await kept.value
        #expect(rig.model.series.all.count == 300)
    }

    @Test func isLoadingIsTrueExactlyWhileARequestThatMayStillBeAppliedIsInFlight() async {
        let rest = FakeRest(candles: [.hold, .hold])
        let rig = ModelRig(rest: rest)
        #expect(!rig.model.isLoading)
        let first = Task { @MainActor in await rig.model.loadHistory() }
        await waitFor("the first request is held") { rest.heldCandleCount == 1 }
        #expect(rig.model.isLoading)
        let second = Task { @MainActor in await rig.model.loadHistory() }
        await waitFor("the second request is held") { rest.heldCandleCount == 2 }

        // The older request can no longer be applied but the newer one can: still loading when the older one ends.
        rest.releaseCandles(call: 0, .success(history(count: 5)))
        await first.value
        #expect(rig.model.isLoading)

        rest.releaseCandles(call: 1, .success(history(count: 7)))
        await second.value
        #expect(!rig.model.isLoading)
        #expect(rig.model.series.all.count == 7)
    }

    // MARK: Stopping

    @Test func stopDropsTheAnswerOfARequestInFlight() async {
        let rest = FakeRest(candles: [.hold])
        let rig = ModelRig(rest: rest)
        let load = Task { @MainActor in await rig.model.loadHistory() }
        await waitFor("the request is held") { rest.heldCandleCount == 1 }

        rig.model.stop()
        #expect(!rig.model.isLoading)
        rest.releaseCandles(call: 0, .success(history(count: 300)))
        await load.value

        #expect(rig.model.series.all.isEmpty)
        #expect(!rig.model.loadFailed)
    }

    @Test func aStoppedModelCanLoadAgainWhenItsScreenComesBack() async {
        let rig = ModelRig(rest: FakeRest(candles: [.candles(history(count: 12))]))
        rig.model.stop()
        await rig.model.loadHistory()
        #expect(rig.model.series.all.count == 12)
    }

    @Test func stopCancelsAGapReloadAndItsAnswerIsDropped() async {
        let past = history(count: 300)
        let rest = FakeRest(candles: [.candles(past), .hold])
        let rig = ModelRig(rest: rest)
        await rig.model.loadHistory()
        rig.market.feed()
        rig.model.refreshFromState()
        rig.market.feed(missed: 1)
        rig.model.refreshFromState()
        let reload = rig.model.reloadTask
        #expect(reload != nil)
        await waitFor("the reload is held") { rest.heldCandleCount == 1 }
        #expect(rig.model.isLoading)

        rig.model.stop()
        #expect(reload?.isCancelled == true)
        #expect(rig.model.reloadTask == nil)
        #expect(!rig.model.isLoading)
        rest.releaseCandles(call: 1, .success(history(count: 5)))
        await reload?.value

        #expect(rig.model.series.all == past)
    }

    @Test func aModelIsReleasedOnceItsLastRequestHasEnded() async {
        let rest = FakeRest(candles: [.candles(history(count: 300)), .hold])
        var rig: ModelRig? = ModelRig(rest: rest)
        weak let weakModel = rig?.model
        await rig?.model.loadHistory()
        rig?.market.feed()
        rig?.model.refreshFromState()
        rig?.market.feed(missed: 1)
        rig?.model.refreshFromState()
        let reload = rig?.model.reloadTask
        await waitFor("the reload is held") { rest.heldCandleCount == 1 }

        // The screen goes away while its reload is still in flight.
        rig?.model.stop()
        rig = nil
        rest.releaseCandles(call: 1, .success(history(count: 5)))
        await reload?.value

        #expect(reload != nil)
        #expect(weakModel == nil)
    }
}

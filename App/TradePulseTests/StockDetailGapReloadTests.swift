import Contracts
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// When a gap in the feed makes the detail screen load its history again: at once, but never more than once a second,
/// a reload that had to wait is remembered and not lost, and a count that goes down (a new connection starts it again
/// from 0) asks for nothing.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StockDetailGapReloadTests {
    /// One second, in nanoseconds: the shortest time between two reloads started by gaps.
    private static let second: Int64 = 1_000_000_000

    /// A model of PTT with one-minute candles that has loaded its history (the first candle call) and has seen the
    /// first update of the symbol, so that the next update that skips numbers is a gap. Every later history call
    /// answers with the same history.
    private func loadedRig() async -> ModelRig {
        let past = history(count: 300)
        let rig = ModelRig(rest: FakeRest(candles: [.candles(past)], candlesFallback: .candles(past)))
        await rig.model.loadHistory()
        rig.market.feed()
        rig.model.refreshFromState()
        return rig
    }

    /// Lets the model look at the market and waits until the reload it may have started has ended.
    private func look(_ rig: ModelRig) async {
        rig.model.refreshFromState()
        await rig.model.reloadTask?.value
    }

    /// Feeds one update that follows a gap, lets the model look, and says how many history calls that made.
    private func gap(_ rig: ModelRig) async -> Int {
        let before = rig.rest.candleCalls.count
        rig.market.feed(missed: 1)
        await look(rig)
        return rig.rest.candleCalls.count - before
    }

    @Test func gapReloadsHistoryOncePerSecond() async {
        let rig = await loadedRig()
        #expect(rig.rest.candleCalls.count == 1)

        let first = await gap(rig)
        rig.advance(byNs: 300_000_000)
        let second = await gap(rig)
        rig.advance(byNs: 300_000_000)
        let third = await gap(rig)

        // Three gaps within 600 ms: the first reloads at once, the others wait.
        #expect(rig.market.state.snapshot(4)?.gapCount == 3)
        #expect(first == 1)
        #expect(second == 0)
        #expect(third == 0)
        #expect(rig.rest.candleCalls.count == 2)
    }

    @Test func theReloadAsksForTheCurrentIntervalAndTheSameDepthAsALoad() async {
        let rig = await loadedRig()
        let started = await gap(rig)
        #expect(started == 1)
        #expect(rig.rest.candleCalls.last == FakeRest.CandleCall(ticker: "PTT", interval: .m1, limit: 300))
    }

    @Test func suppressedGapReloadRunsAfterOneSecond() async {
        let rig = await loadedRig()
        let first = await gap(rig)
        #expect(first == 1)
        rig.advance(byNs: 400_000_000)
        // Two gaps that have to wait: they are one reload to do, not two.
        let second = await gap(rig)
        let third = await gap(rig)
        #expect(second == 0)
        #expect(third == 0)
        #expect(rig.rest.candleCalls.count == 2)

        // One nanosecond short of a second since the reload began: nothing yet.
        rig.advance(byNs: Self.second - 400_000_001)
        await look(rig)
        #expect(rig.rest.candleCalls.count == 2)

        // A second since it began: the reload that was remembered runs, though no gap came with this look.
        rig.advance(byNs: 1)
        await look(rig)
        #expect(rig.rest.candleCalls.count == 3)

        // It was done once, and the memory of it is gone.
        rig.advance(byNs: 5 * Self.second)
        await look(rig)
        #expect(rig.rest.candleCalls.count == 3)
    }

    @Test func aReloadThatWaitedStartsTheNextSecond() async {
        let rig = await loadedRig()
        let first = await gap(rig)
        rig.advance(byNs: Self.second / 2)
        let second = await gap(rig)
        rig.advance(byNs: Self.second / 2)
        await look(rig)
        #expect(first == 1)
        #expect(second == 0)
        #expect(rig.rest.candleCalls.count == 3)

        // The second reload began a half second ago: a gap now waits for the other half.
        rig.advance(byNs: Self.second / 2)
        let third = await gap(rig)
        #expect(third == 0)
        rig.advance(byNs: Self.second / 2)
        await look(rig)
        #expect(rig.rest.candleCalls.count == 4)
    }

    @Test func gapCountDecreaseTriggersNothing() async {
        let rig = await loadedRig()
        let first = await gap(rig)
        #expect(first == 1)
        #expect(rig.market.state.snapshot(4)?.gapCount == 1)
        rig.advance(byNs: 2 * Self.second)

        // A new connection numbers the updates again: the count goes from 1 to 0, and a second has passed.
        rig.market.beginConnection()
        #expect(rig.market.state.snapshot(4)?.gapCount == 0)
        await look(rig)
        rig.market.feed()
        await look(rig)
        #expect(rig.rest.candleCalls.count == 2)

        // The model took 0 as the count to compare with: the first gap of the new connection is an increase.
        let again = await gap(rig)
        #expect(rig.market.state.snapshot(4)?.gapCount == 1)
        #expect(again == 1)
        #expect(rig.rest.candleCalls.count == 3)
    }

    @Test func noGapNoReload() async {
        let rig = await loadedRig()
        for _ in 0..<20 {
            rig.market.feed()
            rig.advance(byNs: 2 * Self.second)
            await look(rig)
        }
        #expect(rig.market.state.snapshot(4)?.gapCount == 0)
        #expect(rig.rest.candleCalls.count == 1)

        // The same model reloads as soon as a gap arrives.
        let started = await gap(rig)
        #expect(started == 1)
    }

    @Test func aClockThatWentBackDoesNotHoldAReloadBack() async {
        let rig = await loadedRig()
        let first = await gap(rig)
        #expect(first == 1)

        // The wall clock stepped back by five seconds (a time sync): a gap now is not a gap "a moment ago".
        rig.clock.set(rig.clock.read() - 5 * Self.second)
        let second = await gap(rig)
        #expect(second == 1)
    }

    @Test func aReloadThatFailsIsAFailedLoad() async {
        let past = history(count: 300)
        let rig = ModelRig(rest: FakeRest(candles: [.candles(past), .failure(TestFailure())]))
        await rig.model.loadHistory()
        rig.market.feed()
        rig.model.refreshFromState()
        #expect(!rig.model.loadFailed)

        let started = await gap(rig)

        #expect(started == 1)
        #expect(rig.model.loadFailed)
        #expect(rig.model.series.all == past)
    }

    @Test func aReloadThatIsInFlightWhenTheIntervalChangesIsDropped() async {
        let minutes = history(count: 300)
        let fiveMinutes = history(count: 40, interval: .m5)
        let rest = FakeRest(candles: [.candles(minutes), .hold, .candles(fiveMinutes)])
        let rig = ModelRig(rest: rest)
        await rig.model.loadHistory()
        rig.market.feed()
        rig.model.refreshFromState()
        rig.market.feed(missed: 1)
        rig.model.refreshFromState()
        let reload = rig.model.reloadTask
        #expect(reload != nil)
        await waitFor("the reload is held") { rest.heldCandleCount == 1 }

        await rig.model.select(interval: .m5)
        #expect(rig.model.series.all == fiveMinutes)
        rest.releaseCandles(call: 1, .success(minutes))
        await reload?.value

        #expect(rig.model.series.all == fiveMinutes)
        #expect(rig.model.series.interval == .m5)
        #expect(rest.candleCalls.map(\.interval) == [.m1, .m1, .m5])
    }

    @Test func aReloadThatStartsWhileAnotherIsStillRunningCancelsIt() async {
        let past = history(count: 300)
        let rest = FakeRest(candles: [.candles(past), .hold, .candles(past)])
        let rig = ModelRig(rest: rest)
        await rig.model.loadHistory()
        rig.market.feed()
        rig.model.refreshFromState()
        rig.market.feed(missed: 1)
        rig.model.refreshFromState()
        let first = rig.model.reloadTask
        await waitFor("the first reload is held") { rest.heldCandleCount == 1 }

        rig.advance(byNs: Self.second)
        rig.market.feed(missed: 1)
        rig.model.refreshFromState()
        let second = rig.model.reloadTask

        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
        #expect(first?.isCancelled == true)
        #expect(second?.isCancelled == false)
        rest.releaseCandles(call: 1, .success(history(count: 5)))
        await first?.value
        await second?.value
        // The answer of the first one was dropped, and the second one's was the same history that was already there.
        #expect(rig.model.series.all == past)
        #expect(rest.candleCalls.count == 3)
    }

    @Test func stopForgetsAReloadThatWasWaiting() async {
        // Two models in the same state: a reload has started and a second one is waiting for its second to pass.
        let kept = await loadedRig()
        let stopped = await loadedRig()
        for rig in [kept, stopped] {
            let first = await gap(rig)
            let second = await gap(rig)
            #expect(first == 1)
            #expect(second == 0)
        }

        stopped.model.stop()
        for rig in [kept, stopped] {
            rig.advance(byNs: 2 * Self.second)
            await look(rig)
        }

        // The model that was not stopped starts the reload it remembered; the stopped one has forgotten it.
        #expect(kept.rest.candleCalls.count == 3)
        #expect(stopped.rest.candleCalls.count == 2)
    }

    @Test func aModelThatStartsAfterGapsDoesNotReloadForTheOnesBeforeIt() async {
        // The market has had two gaps before the screen opens: the history it loads already covers them.
        let past = history(count: 300)
        let market = FakeMarketState()
        market.feed()
        market.feed(missed: 1)
        market.feed(missed: 1)
        #expect(market.state.snapshot(4)?.gapCount == 2)
        let rest = FakeRest(candles: [.candles(past)], candlesFallback: .candles(past))
        let model = StockDetailViewModel(
            symbol: sampleSymbols[0], interval: .m1, rest: rest, marketState: market.state, now: { 10_000_000_000 }
        )
        await model.loadHistory()

        model.refreshFromState()
        await model.reloadTask?.value
        #expect(rest.candleCalls.count == 1)

        market.feed(missed: 1)
        model.refreshFromState()
        await model.reloadTask?.value
        #expect(rest.candleCalls.count == 2)
    }
}

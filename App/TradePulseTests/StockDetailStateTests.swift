import Contracts
import Observation
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// What the detail screen's model holds for its views: the header, the zoom and the pan with their limits, the
/// interval, and which of these a view that reads them is told about when they change.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StockDetailStateTests {
    /// A model of PTT that has loaded 300 one-minute candles.
    private func loadedRig() async -> ModelRig {
        let rig = ModelRig(rest: FakeRest(candles: [.candles(history(count: 300))]))
        await rig.model.loadHistory()
        return rig
    }

    // MARK: A model that has just been made

    @Test func aNewModelShowsNothingYetAndAsksForNothing() {
        let rig = ModelRig(interval: .m5)

        #expect(rig.model.symbol.ticker == "PTT")
        #expect(rig.model.interval == .m5)
        #expect(rig.model.series.interval == .m5)
        #expect(rig.model.series.all.isEmpty)
        #expect(!rig.model.hasCandles)
        #expect(rig.model.style == .candle)
        #expect(rig.model.visibleCount == 60)
        #expect(rig.model.panOffset == 0)
        #expect(!rig.model.isLoading)
        #expect(!rig.model.loadFailed)
        #expect(rig.model.lastPrice == nil)
        #expect(rig.model.header == MarketRowModel(symbol: sampleSymbols[0], snapshot: nil))
        #expect(rig.model.header.lastText == "\u{2014}")
        #expect(rig.rest.candleCalls.isEmpty)
        #expect(rig.model.reloadTask == nil)
    }

    @Test func theCandlesAreThereOnceTheHistoryHasLoadedAndGoneWithTheInterval() async {
        let rig = await loadedRig()
        #expect(rig.model.hasCandles)
        rig.model.interval = .m5
        #expect(!rig.model.hasCandles)
    }

    // MARK: The header

    @Test func theHeaderFollowsTheSnapshotByTheRulesOfTheList() {
        let rig = ModelRig()
        // The reference price of PTT is 34.25.
        rig.market.feed(last: 3_450)
        rig.model.refreshFromState()

        #expect(rig.model.header == MarketRowModel(symbol: sampleSymbols[0], snapshot: rig.market.state.snapshot(4)))
        #expect(rig.model.header.lastText == "34.50")
        #expect(rig.model.header.direction == .up)
        #expect(rig.model.lastPrice == satang(3_450))

        rig.market.feed(last: 3_400)
        rig.model.refreshFromState()

        #expect(rig.model.header.lastText == "34.00")
        #expect(rig.model.header.direction == .down)
        #expect(rig.model.lastPrice == satang(3_400))
    }

    @Test func theHeaderStaysWithoutAPriceWhileOnlyOtherSymbolsMove() {
        let rig = ModelRig()
        rig.market.feed(symbol: 2, last: 5_900)
        rig.model.refreshFromState()

        #expect(rig.market.state.snapshot(2)?.last == satang(5_900))
        #expect(rig.model.header.lastText == "\u{2014}")
        #expect(rig.model.header.direction == nil)
        #expect(rig.model.lastPrice == nil)
    }

    // MARK: The zoom and the pan

    @Test func visibleCountIsHeldBetween20And300() {
        let cases: [(asked: Int, held: Int)] = [
            (Int.min, 20), (-5, 20), (0, 20), (19, 20), (20, 20), (21, 21), (100, 100), (299, 299), (300, 300),
            (301, 300), (10_000, 300), (Int.max, 300),
        ]
        #expect(cases.count == 12)
        for (asked, held) in cases {
            let rig = ModelRig()
            rig.model.visibleCount = asked
            #expect(rig.model.visibleCount == held, "asked for \(asked)")
        }
    }

    @Test func panOffsetIsHeldInsideTheCandlesThereAre() async {
        // 300 candles and 60 in view: the window can sit back by 240 candles at most.
        let cases: [(asked: Int, held: Int)] = [
            (Int.min, 0), (-1, 0), (0, 0), (1, 1), (239, 239), (240, 240), (241, 240), (10_000, 240), (Int.max, 240),
        ]
        #expect(cases.count == 9)
        let rig = await loadedRig()
        #expect(rig.model.visibleCount == 60)
        for (asked, held) in cases {
            rig.model.panOffset = asked
            #expect(rig.model.panOffset == held, "asked for \(asked)")
        }
    }

    @Test func aModelWithoutCandlesCannotBePanned() {
        let rig = ModelRig()
        rig.model.panOffset = 50
        #expect(rig.model.panOffset == 0)
    }

    @Test func aSeriesNoLongerThanTheWindowCannotBePanned() async {
        let rig = ModelRig(rest: FakeRest(candles: [.candles(history(count: 60))]))
        await rig.model.loadHistory()
        #expect(rig.model.series.all.count == 60)
        rig.model.panOffset = 5
        #expect(rig.model.panOffset == 0)
    }

    @Test func changingTheZoomHoldsThePanInsideTheNewRoom() async {
        let rig = await loadedRig()
        rig.model.panOffset = 240
        #expect(rig.model.panOffset == 240)

        rig.model.visibleCount = 100
        #expect(rig.model.panOffset == 200)

        rig.model.visibleCount = 300
        #expect(rig.model.panOffset == 0)

        // Zooming back in does not bring the old pan back: it was clamped, not remembered.
        rig.model.visibleCount = 60
        #expect(rig.model.panOffset == 0)
    }

    @Test func panStaysWhereItIsWhenTheZoomLeavesRoomForIt() async {
        let rig = await loadedRig()
        rig.model.panOffset = 100
        rig.model.visibleCount = 120
        #expect(rig.model.panOffset == 100)
    }

    // MARK: The interval and the style

    @Test func settingTheIntervalStartsAnEmptySeriesAtTheNewestCandle() async {
        let rig = await loadedRig()
        rig.model.panOffset = 100

        rig.model.interval = .m5

        #expect(rig.model.interval == .m5)
        #expect(rig.model.series.interval == .m5)
        #expect(rig.model.series.all.isEmpty)
        #expect(rig.model.panOffset == 0)
    }

    @Test func settingTheSameIntervalKeepsWhatIsShown() async {
        let rig = await loadedRig()
        let candles = rig.model.series.all
        rig.model.panOffset = 100

        rig.model.interval = .m1

        #expect(rig.model.series.all == candles)
        #expect(rig.model.panOffset == 100)
    }

    @Test func theStyleCanBeSwitched() {
        let rig = ModelRig()
        rig.model.style = .line
        #expect(rig.model.style == .line)
        rig.model.style = .candle
        #expect(rig.model.style == .candle)
        #expect(ChartStyle.allCases == [.candle, .line])
    }

    // MARK: What a view that reads the model is told about

    @Test func aLookThatFindsNothingNewTellsNoOne() async {
        let rig = await loadedRig()
        rig.market.feed(last: 3_450, candle1m: candle(openTimeMs: 18_600_000, close: 3_450))
        rig.model.refreshFromState()
        let told = Flag()
        withObservationTracking {
            let model = rig.model
            _ = (model.series.version, model.header, model.lastPrice, model.isLoading, model.loadFailed)
            _ = (model.interval, model.style, model.visibleCount, model.panOffset, model.hasCandles)
        } onChange: {
            told.set()
        }

        // The same snapshot again: no price, candle or gap that was not there before.
        rig.model.refreshFromState()
        rig.model.refreshFromState()
        #expect(!told.isSet)

        // Control: a price that is new does tell the same readers.
        rig.market.feed(last: 3_460)
        rig.model.refreshFromState()
        #expect(told.isSet)
    }

    @Test func aNewPriceTellsTheReadersOfThePriceAndNotTheReadersOfTheCandles() async {
        let rig = await loadedRig()
        rig.market.feed(last: 3_450, candle1m: candle(openTimeMs: 18_600_000, close: 3_450))
        rig.model.refreshFromState()
        let candlesTold = Flag()
        let priceTold = Flag()
        withObservationTracking {
            _ = rig.model.series.version
        } onChange: {
            candlesTold.set()
        }
        withObservationTracking {
            _ = rig.model.lastPrice
            _ = rig.model.header
        } onChange: {
            priceTold.set()
        }

        // The candle fields are left out of this update, which says nothing about them.
        rig.market.feed(last: 3_460)
        rig.model.refreshFromState()

        #expect(priceTold.isSet)
        #expect(!candlesTold.isSet)
    }

    @Test func aChangedCandleTellsTheReadersOfTheSeries() async {
        let rig = await loadedRig()
        let told = Flag()
        withObservationTracking {
            _ = rig.model.series.version
        } onChange: {
            told.set()
        }

        rig.market.feed(candle1m: candle(openTimeMs: history(count: 300)[299].openTimeMs, close: 3_999))
        rig.model.refreshFromState()

        #expect(rig.model.series.all.last?.close == satang(3_999))
        #expect(told.isSet)
    }

    @Test func aFinishedLoadTellsTheReadersOfTheSeriesAndOfTheLoadingFlag() async {
        let rig = ModelRig(rest: FakeRest(candles: [.candles(history(count: 300))]))
        let seriesTold = Flag()
        let loadingTold = Flag()
        withObservationTracking {
            _ = rig.model.series.version
        } onChange: {
            seriesTold.set()
        }
        withObservationTracking {
            _ = rig.model.isLoading
        } onChange: {
            loadingTold.set()
        }

        await rig.model.loadHistory()

        #expect(seriesTold.isSet)
        #expect(loadingTold.isSet)
    }
}

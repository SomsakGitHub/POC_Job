import Contracts
import Observation
import TradeCore
import TradeNetworking

/// How the chart draws its prices: as candlesticks, or as one line through the closing prices.
enum ChartStyle: CaseIterable, Sendable {
    case candle
    case line

    /// The name of the style on the toggle.
    var label: String {
        switch self {
        case .candle: "Candle"
        case .line: "Line"
        }
    }
}

/// What the stock detail screen shows and how it keeps it current: the candles of one symbol at one interval, loaded
/// as a history over REST and kept live from the market state, and the zoom and the pan of the window onto them.
///
/// The model has no timer. The screen calls `loadHistory()` from its `.task`, `refreshFromState()` when a frame
/// carried new prices and `stop()` when it goes away. The one task the model starts itself is the reload that a gap
/// in the feed asks for, because `refreshFromState()` is not asynchronous; that task is kept so that `stop()` can
/// cancel it.
///
/// What a view reads is observed only where it can change: the candles are not stored as observed state, a counter
/// that goes up with each real change of them is, and every setter writes only a value that differs from the stored
/// one, so that a look at an unchanged market tells no one.
@MainActor
@Observable
final class StockDetailViewModel {
    /// How many candles a request for the history asks for.
    static let historyLimit = 300
    /// The fewest and the most candles the window can hold.
    static let visibleRange = 20...300
    /// How many candles are in view until the user zooms.
    static let defaultVisibleCount = 60
    /// The shortest time between two reloads that gaps in the feed asked for, in nanoseconds.
    static let reloadSpacingNs: Int64 = 1_000_000_000

    /// The symbol shown.
    let symbol: SymbolDTO

    /// The words of the header: ticker, name, last price and its move from the reference price, by the same rules as a
    /// row of the market list (a dash and no direction until the feed has given a price).
    private(set) var header: MarketRowModel
    /// The last price, for the line across the chart; nil until the feed has given one.
    private(set) var lastPrice: Price?
    /// How the chart draws the prices.
    var style = ChartStyle.candle
    /// Whether a request for the history that may still be applied is in flight.
    private(set) var isLoading = false
    /// Whether the last request that could be applied failed. The candles stay as they were, so a failed load never
    /// empties the chart.
    private(set) var loadFailed = false

    /// Counts the changes of the candles. It is what a reader of `series` is registered on.
    private var revision = 0
    /// The width of the candles shown: the stored value behind `interval`.
    private var storedInterval: CandleInterval
    /// How many candles are in view: the stored value behind `visibleCount`.
    private var storedZoom = StockDetailViewModel.defaultVisibleCount
    /// How many candles the window sits back from the newest: the stored value behind `panOffset`.
    private var storedPan = 0

    /// The REST API the history comes from.
    private let rest: any RestAPI
    /// The market the live candle, the price and the gap count come from.
    private let marketState: MarketState
    /// The clock the gap reloads are spaced by, in nanoseconds.
    private let now: @Sendable () -> Int64
    /// The candles. Not observed: a change is announced through `revision`, and only when there is one.
    @ObservationIgnored private var candles: CandleSeries
    /// The number of the newest request for the history, so that an answer for an older one is not applied.
    @ObservationIgnored private var generation = 0
    /// The gap count of the last snapshot looked at.
    @ObservationIgnored private var lastGapCount: Int
    /// Whether a gap asked for a reload that has not started yet because the last one was less than a second ago.
    @ObservationIgnored private var gapReloadPending = false
    /// When the last reload that a gap asked for started, in nanoseconds of `now`.
    @ObservationIgnored private var lastGapReloadNs: Int64?
    /// The reload that a gap asked for, until it has ended or `stop()` cancels it. Exposed so that a test can wait for
    /// it; the model is the only one that starts it.
    @ObservationIgnored private(set) var reloadTask: Task<Void, Never>?

    /// A model of `symbol` that shows `interval` candles, loaded from `rest` and kept live from `marketState`. `now`
    /// is the clock the gap reloads are spaced by; the gaps that have happened before the model exists are not its
    /// business, because the history it loads already covers them.
    init(
        symbol: SymbolDTO, interval: CandleInterval, rest: any RestAPI, marketState: MarketState,
        now: @escaping @Sendable () -> Int64 = { WallClock.nowNs() }
    ) {
        self.symbol = symbol
        self.rest = rest
        self.marketState = marketState
        self.now = now
        storedInterval = interval
        candles = CandleSeries(interval: interval)
        header = MarketRowModel(symbol: symbol, snapshot: nil)
        lastGapCount = marketState.snapshot(symbol.id)?.gapCount ?? 0
    }

    // MARK: What the views read

    /// The candles of `interval`, the closed ones and the one in progress.
    var series: CandleSeries {
        _ = revision
        return candles
    }

    /// Whether there is any candle to draw.
    var hasCandles: Bool {
        !series.all.isEmpty
    }

    /// The width of the candles shown. Choosing another one drops the candles of the old width and the pan, because
    /// neither means anything at the new one; the history of the new width has to be loaded (see `select`).
    var interval: CandleInterval {
        get { storedInterval }
        set {
            guard newValue != storedInterval else { return }
            storedInterval = newValue
            candles = CandleSeries(interval: newValue)
            revision &+= 1
            storedPan = 0
        }
    }

    /// How many candles are in view, from 20 to 300. Zooming re-holds the pan inside the room that is left.
    var visibleCount: Int {
        get { storedZoom }
        set {
            storedZoom = min(max(newValue, Self.visibleRange.lowerBound), Self.visibleRange.upperBound)
            storedPan = heldPan(storedPan)
        }
    }

    /// How many candles the window sits back from the newest one, from 0 to the number of candles beyond the window.
    /// Holding it here means a gesture can never park the window in a dead zone past the data.
    var panOffset: Int {
        get { storedPan }
        set { storedPan = heldPan(newValue) }
    }

    // MARK: Loading

    /// Shows `interval`: drops the candles and the pan of the old one and loads the history of the new one.
    func select(interval: CandleInterval) async {
        self.interval = interval
        await loadHistory()
    }

    /// Asks the server for the history of the current interval and, when the answer may still be used, seeds the
    /// candles with it and puts the live candle on top.
    ///
    /// An answer is used only if no newer request (or `stop()`) has come since it was asked for, if the interval is
    /// still the one it was asked for and if the task has not been cancelled; otherwise it is dropped, so a slow answer
    /// for the old interval can never fill the series of the new one and a screen that has gone is not written to. A
    /// failure keeps the candles and sets `loadFailed`; nothing is thrown and nothing is retried here, because the
    /// next trigger (a reconnection, a gap, the user) asks again.
    func loadHistory() async {
        generation &+= 1
        let mine = generation
        let requested = interval
        isLoading = true
        let answer: Result<[Candle], any Error>
        do {
            let history = try await rest.candles(ticker: symbol.ticker, interval: requested, limit: Self.historyLimit)
            answer = .success(history)
        } catch {
            answer = .failure(error)
        }
        // A newer request owns the loading flag from the moment it starts, and `stop()` has cleared it.
        guard mine == generation else { return }
        isLoading = false
        guard !Task.isCancelled, requested == interval else { return }
        switch answer {
        case .success(let history):
            edit { $0.seed(history: history) }
            loadFailed = false
            apply(snapshot: marketState.snapshot(symbol.id))
            storedPan = heldPan(storedPan)
        case .failure:
            loadFailed = true
        }
    }

    /// Ends what the screen started: cancels the reload a gap asked for, forgets one that was waiting, and makes the
    /// answer of a request still in flight one that is not applied. The model can be used again afterwards.
    func stop() {
        reloadTask?.cancel()
        reloadTask = nil
        gapReloadPending = false
        generation &+= 1
        isLoading = false
    }

    // MARK: Staying live

    /// Takes what the market has now: the price for the header and the last-price line, the current candle of the
    /// interval, and the gap count, which can ask for the history again.
    func refreshFromState() {
        let snapshot = marketState.snapshot(symbol.id)
        let row = MarketRowModel(symbol: symbol, snapshot: snapshot)
        if row != header { header = row }
        if snapshot?.last != lastPrice { lastPrice = snapshot?.last }
        apply(snapshot: snapshot)
        if let snapshot { noteGapCount(snapshot.gapCount) }
        reloadIfDue()
    }

    /// Puts the current candle of the interval, from `snapshot`, on the series. A candle that opens at 0 or earlier is
    /// the feed saying that it has not sent one yet, not a bar at the start of 1970, so it is left out. The series
    /// itself replaces a candle that has the same open time, adds a later one and ignores an earlier one.
    private func apply(snapshot: SymbolSnapshot?) {
        guard let snapshot else { return }
        let current =
            switch interval {
            case .s1: snapshot.candle1s
            case .m1: snapshot.candle1m
            case .m5: snapshot.candle5m
            }
        guard current.openTimeMs > 0 else { return }
        edit { $0.apply(current: current) }
    }

    /// Remembers the gap count, and asks for a reload when it went up. The count starts again from 0 on every
    /// connection, so a lower number is a new connection and not a gap, and is remembered all the same.
    private func noteGapCount(_ count: Int) {
        if count > lastGapCount { gapReloadPending = true }
        lastGapCount = count
    }

    /// Starts the reload that a gap asked for, unless the last one began less than a second ago; then it stays
    /// remembered and the first look after that second starts it. A clock that went back (a wall clock can step) does
    /// not hold a reload back.
    private func reloadIfDue() {
        guard gapReloadPending else { return }
        let current = now()
        if let last = lastGapReloadNs, current >= last, current &- last < Self.reloadSpacingNs { return }
        gapReloadPending = false
        lastGapReloadNs = current
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in await self?.loadHistory() }
    }

    // MARK: Helpers

    /// Changes the candles with `change` and tells the readers of `series` only if they really changed.
    private func edit(_ change: (inout CandleSeries) -> Void) {
        let before = candles.version
        change(&candles)
        if candles.version != before { revision &+= 1 }
    }

    /// `offset` held between 0 and the number of candles that lie beyond the window.
    private func heldPan(_ offset: Int) -> Int {
        min(max(offset, 0), max(0, candles.all.count - storedZoom))
    }
}

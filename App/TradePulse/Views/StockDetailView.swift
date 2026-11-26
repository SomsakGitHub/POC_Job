import Contracts
import SwiftUI
import TradeCore

/// The detail screen of one symbol: its ticker, name and last price, the interval and style pickers, the latency chip,
/// the live chart, the buttons that open the order ticket and the newest fills of the symbol.
///
/// The screen is a thin wrapper around `StockDetailScreen`, which makes the screen's model in its `init` from the
/// environment's REST client and market state; a view cannot read the environment before it has a body.
struct StockDetailView: View {
    /// The symbol shown.
    let symbol: SymbolDTO
    /// The app's environment, put in place by the root view.
    @Environment(AppEnvironment.self) private var environment

    /// The screen of `symbol`.
    var body: some View {
        StockDetailScreen(symbol: symbol, environment: environment)
    }
}

/// The screen itself. It holds no task of its own besides `.task`: the history is loaded by that one task, which runs
/// again whenever what it loads for changes (a new interval, a connection that came back, a tap on Retry), and the live
/// candle is taken from the market state each time a frame carried new prices. The model is released with the screen,
/// and `stop()` cancels what the model still has in flight when the screen goes away.
///
/// The body of this view must not read anything that changes at the pace of the prices: not the pump's `tick`, and not
/// the model's header, last price or candles. A body that is evaluated at that pace updates the two segmented pickers
/// again and again, and a segmented control that is updated while a finger is on it drops that touch, so taps on the
/// pickers would be lost for as long as prices stream. What changes with the prices is read in views of their own
/// (`StockDetailHeader`, `LoadingOverlay`, `TickBridge` and the chart), each in its own body, so that only those are
/// evaluated again. The trade buttons read nothing, and the recent fills read the trading state in a body of their
/// own, so that a fill evaluates the fills and not the screen.
struct StockDetailScreen: View {
    /// The interval a screen starts with: one-minute candles are the most readable.
    private static let startInterval = CandleInterval.m1

    /// What the history is loaded for. The screen's `.task` runs again whenever it changes.
    private struct LoadTrigger: Equatable {
        /// The interval chosen on the picker.
        let interval: CandleInterval
        /// How many times the history has been asked for again, by a connection that came back or by Retry.
        let reloads: Int
    }

    /// The app's environment: the pump, the latency recorder and the market connection.
    private let environment: AppEnvironment
    /// What the screen shows, made once for the screen. It can be read from outside, so that a test can change it and
    /// see whether the body of the screen would be evaluated again.
    @State private(set) var model: StockDetailViewModel
    /// The interval the picker is on. The `.task` makes the model follow it.
    @State private var picked = StockDetailScreen.startInterval
    /// How many times the history has been asked for again.
    @State private var reloads = 0

    /// The screen of `symbol`, with a model over the environment's REST client and market state.
    init(symbol: SymbolDTO, environment: AppEnvironment) {
        self.environment = environment
        _model = State(
            initialValue: StockDetailViewModel(
                symbol: symbol, interval: Self.startInterval, rest: environment.rest,
                marketState: environment.marketState
            )
        )
    }

    /// The header, the controls and the chart in a scroll view, so that a large text size still reaches everything.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StockDetailHeader(model: model)
                LatencyChip(latency: environment.latency)
                controls
                CandleChartView(model: model, pump: environment.pump)
                    .frame(height: 320)
                    .overlay { LoadingOverlay(model: model) }
                failure
                TradeButtons(symbol: model.symbol, environment: environment)
                RecentFillsView(symbolId: model.symbol.id, environment: environment)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(model.symbol.ticker)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: LoadTrigger(interval: picked, reloads: reloads)) { await load() }
        .background { TickBridge(pump: environment.pump, model: model) }
        .onChange(of: environment.marketConnection) { old, new in
            if shouldReloadOnConnection(from: old, to: new) {
                reloads += 1
            }
        }
        .onDisappear { model.stop() }
    }

    /// Takes the market's current price at once, then loads the history for the interval on the picker: a different
    /// interval is chosen through the model, which drops the candles of the old one, and the same one is loaded again.
    private func load() async {
        model.refreshFromState()
        if picked == model.interval {
            await model.loadHistory()
        } else {
            await model.select(interval: picked)
        }
    }

    // MARK: Parts

    /// The pickers for the interval and for candles or a line.
    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Interval", selection: $picked) {
                ForEach(CandleInterval.allCases, id: \.self) { interval in
                    Text(interval.label).tag(interval)
                }
            }
            .pickerStyle(.segmented)
            Picker("Chart style", selection: $model.style) {
                ForEach(ChartStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    /// The notice that the history could not be loaded, with the button that asks again. The chart keeps what it had.
    @ViewBuilder private var failure: some View {
        if model.loadFailed {
            HStack {
                Label("The history could not be loaded.", systemImage: "exclamationmark.triangle")
                Spacer(minLength: 8)
                Button("Retry") { reloads += 1 }
            }
            .font(.footnote)
        }
    }
}

/// The ticker and the Thai name on the left, the last price and its move on the right, and the words that say the data
/// is simulated. The two halves are stacked when they do not fit side by side.
///
/// It reads the model's header in its own body, so that a new price evaluates this view and not the screen around it.
private struct StockDetailHeader: View {
    /// The model whose header is shown.
    let model: StockDetailViewModel

    /// The header as it is now.
    var body: some View {
        let row = model.header
        let style = DirectionStyle(row.direction)
        return VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    names(row)
                    Spacer(minLength: 8)
                    price(row, style: style, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 8) {
                    names(row)
                    price(row, style: style, alignment: .leading)
                }
            }
            Text(SimulatedBadge.text)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityText)
    }

    /// The ticker over the Thai name.
    private func names(_ row: MarketRowModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.ticker)
                .font(.title2.bold())
            Text(row.nameTh)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// The last price over the move, whose glyph and colour tell the direction.
    private func price(_ row: MarketRowModel, style: DirectionStyle, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(row.lastText)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            HStack(spacing: 4) {
                Image(systemName: style.symbolName)
                Text(row.changeText)
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(style.color)
        }
    }
}

/// The spinner over the chart while the history is loading and there is nothing to draw yet.
///
/// It reads the loading flag and the candles in its own body. While a load is in flight the candles can change with
/// every price, and that must not evaluate the screen.
private struct LoadingOverlay: View {
    /// The model that loads the history.
    let model: StockDetailViewModel

    /// A spinner while the history loads and the series is empty, and nothing otherwise.
    var body: some View {
        if model.isLoading && !model.hasCandles {
            ProgressView()
        }
    }
}

/// Takes the market's current state into the model each time a frame carried new prices. It draws nothing and takes no
/// room.
///
/// It is a view of its own so that the pump's `tick`, which moves at the pace of the prices, is read in this body and
/// not in the screen's.
private struct TickBridge: View {
    /// The pump whose `tick` moves when a frame carried new prices.
    let pump: FramePump
    /// The model that takes the market's state.
    let model: StockDetailViewModel

    /// A view of no size that notices each move of the tick.
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: pump.tick) { model.refreshFromState() }
    }
}

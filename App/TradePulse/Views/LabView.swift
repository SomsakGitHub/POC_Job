import SwiftUI
import TradeCore
import TradeNetworking

/// The Lab tab: the connections, the latency table, the frames, the account check and the controls that change what
/// the server does.
///
/// The tab is a thin wrapper around `LabScreen`, which takes the environment as an argument so that a test can make
/// one over fakes; a view cannot read the environment before it has a body.
struct LabView: View {
    /// The app's environment, put in place by the root view.
    @Environment(AppEnvironment.self) private var environment

    /// The screen over the app's environment.
    var body: some View {
        LabScreen(environment: environment)
    }
}

/// The Lab screen: its sections in a scroll view, so that a large text size still reaches everything.
///
/// Its body reads nothing that changes while the app runs, and so it is evaluated once. The Lab holds a slider,
/// switches and buttons, and a control whose body is evaluated again while a touch is on it loses that touch. Each part
/// that shows something live reads it in a body of its own, and the controls sit in a part that reads only what the
/// controls change. What moves with every display frame is not read by a body at all: the model samples it twice a
/// second, from the one timeline that also redraws the table, and the texts of the sample are what the views read.
struct LabScreen: View {
    /// The app's environment: the connections, the recorder and the market state.
    let environment: AppEnvironment
    /// What the screen shows and does, made once for the screen. It can be read from outside, so that a test can change
    /// it and see whether a body would be evaluated again.
    @State private(set) var model: LabViewModel

    /// The screen over `environment`, with a model over its REST client, recorder, pump and trading store. Making the
    /// model reads nothing that changes.
    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(
            initialValue: LabViewModel(
                rest: environment.rest, latency: environment.latency, pump: environment.pump,
                trading: environment.trading
            )
        )
    }

    /// The sections under the title. The loop that looks at the server, the settings included, runs for as long as the
    /// screen is on show, and it makes its first round as the screen opens.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    LabConnectionsSection(environment: environment, model: model)
                    LabMeasurementsSection(environment: environment, model: model)
                    LabAccountSection(model: model)
                    LabControlsSection(model: model)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Lab")
            .task { await model.monitor() }
        }
    }
}

/// The state of the market feed, of the order stream and of the REST API, each in words with a symbol.
///
/// It reads the two connection states and what the probe found in its own body: a connection that drops tells this
/// view and not the screen around it.
struct LabConnectionsSection: View {
    /// The app's environment, which holds the two connection states.
    let environment: AppEnvironment
    /// The model, which holds what the probe of the REST API found.
    let model: LabViewModel

    /// A line for each connection.
    var body: some View {
        LabSection("Connections") {
            StatusRow(
                text: "Market: " + ConnectionText.text(for: environment.marketConnection),
                symbol: LabSymbol.name(for: environment.marketConnection)
            )
            StatusRow(
                text: "Trading: " + ConnectionText.text(for: environment.tradingConnection),
                symbol: LabSymbol.name(for: environment.tradingConnection)
            )
            StatusRow(text: RestStatusText.text(for: model.restStatus), symbol: LabSymbol.name(for: model.restStatus))
        }
    }
}

/// The latency table and the frames, made new twice a second by one timeline.
///
/// The recorder is not observable, so the timeline is what makes the table read it again. The same timeline is what
/// asks the model for a sample of the frames: the model reads the pump's counters there, and nothing in a body does,
/// because a body that read a counter would be evaluated again with every display frame and would disturb the frames
/// it counts.
struct LabMeasurementsSection: View {
    /// The app's environment, which holds the recorder and the market state.
    let environment: AppEnvironment
    /// The model that takes the sample.
    let model: LabViewModel

    /// The table and the frames, every half second.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            content(at: context.date)
        }
    }

    /// What the timeline shows at `date`: the table as the recorder has it now, the frames, and, when the date is new,
    /// the sample of the frames that the frames' texts show.
    func content(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            LabSection("Latency") {
                LatencyHUD(rows: LatencyTableRow.rows(from: environment.latency.snapshot()))
            }
            LabFramesSection(model: model, environment: environment, updatedAt: date)
        }
        .onChange(of: date, initial: true) { model.sampleFrames() }
    }
}

/// How the display is doing: the frame rate, the hitches, what drawing the chart costs and how many gaps the market
/// feed has had.
///
/// The texts are the model's, taken at its last sample, so they change twice a second. The gaps are not observable, so
/// the timeline makes this view new twice a second (`updatedAt` is the time of that update) and they are read again
/// each time.
struct LabFramesSection: View {
    /// The model whose sample the texts are.
    let model: LabViewModel
    /// The app's environment, which holds the symbols and their market state.
    let environment: AppEnvironment
    /// When the timeline made this view new. The view does not use it; it is what makes the view differ from the one
    /// before, so that its body is evaluated again and reads the gaps again.
    let updatedAt: Date

    /// The rows of the frames.
    var body: some View {
        let gaps = GapCount.total(of: environment.symbols) { environment.marketState.snapshot($0) }
        LabSection("Frames") {
            LabValueRow(title: "Frames per second", value: model.fpsText)
            LabValueRow(title: "Hitches", value: model.hitchText)
            LabValueRow(title: "Chart draw", value: model.drawTimeText)
            Text(GapCount.text(for: gaps))
                .font(.subheadline.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHint(LabLabels.gapsRowHint)
        }
    }
}

/// The account check: what the comparison of the app's account with the server's found, and a button that makes it now.
///
/// The section reads nothing: the answer is read in a view of its own, so that a check that finds something tells that
/// view and not the button.
struct LabAccountSection: View {
    /// The model that makes the comparison.
    let model: LabViewModel

    /// The answer and the button.
    var body: some View {
        LabSection("Account check") {
            AccountCheckRow(model: model)
            Button("Check now") {
                Task { await model.refreshReconciliation() }
            }
            .buttonStyle(.bordered)
        }
    }
}

/// What the account check found, in words with a symbol. It reads the model's answer in its own body.
struct AccountCheckRow: View {
    /// The model that holds the answer.
    let model: LabViewModel

    /// The answer of the last check.
    var body: some View {
        let verdict = model.reconciliation
        let text = AccountCheckText.text(for: verdict)
        StatusRow(text: text, symbol: LabSymbol.name(for: verdict))
            .accessibilityLabel("Account check: \(text)")
    }
}

/// The symbol that goes with each state the Lab says in words, so that no state is told by a colour or a symbol alone.
enum LabSymbol {
    /// The symbol of a connection that is `state`.
    static func name(for state: ConnectionState) -> String {
        switch state {
        case .connected: "checkmark.circle"
        case .connecting: "circle.dotted"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .stopped: "stop.circle"
        }
    }

    /// The symbol of a REST API that the last probe found as `status`.
    static func name(for status: RestStatus) -> String {
        switch status {
        case .unknown: "circle.dotted"
        case .reachable: "checkmark.circle"
        case .unreachable: "xmark.circle"
        }
    }

    /// The symbol of an account check that found `reconciliation`.
    static func name(for reconciliation: Reconciliation) -> String {
        switch reconciliation {
        case .consistent: "checkmark.circle"
        case .inFlight: "hourglass"
        case .drift: "exclamationmark.triangle"
        }
    }
}

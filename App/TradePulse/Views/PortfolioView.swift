import SwiftUI
import TradeCore

/// The Portfolio tab: the cash, the equity, the positions and the transactions of the account.
///
/// The tab is a thin wrapper around `PortfolioScreen`, which takes the environment as an argument so that a test can
/// make one over fakes; a view cannot read the environment before it has a body.
struct PortfolioView: View {
    /// The app's environment, put in place by the root view.
    @Environment(AppEnvironment.self) private var environment

    /// The screen over the app's environment.
    var body: some View {
        PortfolioScreen(environment: environment)
    }
}

/// The Portfolio screen: the banner, the account and the transactions in a scroll view, so that a large text size still
/// reaches everything.
///
/// Its body reads nothing that changes while the app runs. The account is redrawn twice a second by a timeline and
/// whenever the trading state changes, each in a body of its own, and the transactions are a view of their own.
struct PortfolioScreen: View {
    /// The app's environment.
    let environment: AppEnvironment
    /// Whether the user dismissed the banner, and at which restart.
    @State private var banner = EpochBannerState()

    /// The banner, the account and the transactions, under the title.
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    EpochBannerView(trading: environment.trading, state: $banner)
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        PortfolioAccount(environment: environment, updatedAt: context.date)
                    }
                    .padding(.horizontal, 16)
                    TransactionsSection(environment: environment)
                        .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("Portfolio")
        }
    }
}

/// The cash, the equity and the positions.
///
/// The prices are not observable, so a timeline makes this view new twice a second (`updatedAt` is the time of that
/// update) and the prices are read each time. The trading state is observed: a fill that changes the cash or a position
/// is on screen at once. The body never reads the pump's tick or a connection, which move at other paces.
struct PortfolioAccount: View {
    /// The app's environment.
    let environment: AppEnvironment
    /// When the timeline made this view new. The view does not use it; it is what makes the view differ from the one
    /// before, so that its body is evaluated again and reads the prices again.
    let updatedAt: Date

    /// The cash and the equity over the positions.
    var body: some View {
        let portfolio = PortfolioViewModel(
            state: environment.trading.state, snapshots: { environment.marketState.snapshot($0) },
            symbols: environment.symbols
        )
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                figure("Cash", portfolio.cashText)
                figure("Equity", portfolio.equityText)
            }
            if let waiting = portfolio.waitingText {
                Label(waiting, systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Positions")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if portfolio.rows.isEmpty {
                Text("No positions yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(portfolio.rows) { row in
                    PositionRowView(row: row)
                    Divider()
                }
            }
        }
    }

    /// A label over a figure.
    private func figure(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}

/// One position: the ticker and the shares held on the left, the last price and the value of the shares on the right.
/// The two halves are stacked when they do not fit side by side.
struct PositionRowView: View {
    /// The position.
    let row: PositionRow

    /// The row, read by VoiceOver as one sentence.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                what
                Spacer(minLength: 8)
                worth(alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                what
                worth(alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// The last price as text, or a dash while there is none.
    private var lastText: String {
        row.last.map(\.description) ?? "\u{2014}"
    }

    /// The value of the shares as money, or a dash while there is no price.
    private var valueText: String {
        row.marketValueSatang.map { MoneyFormat.baht(satang: $0) } ?? "\u{2014}"
    }

    /// The ticker over the shares held.
    private var what: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.ticker)
                .font(.subheadline.weight(.semibold))
            Text("\(ShareFormat.grouped(row.quantity)) shares")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// The value over the last price.
    private func worth(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(valueText)
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text("last \(lastText)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// The position as one sentence for VoiceOver.
    private var spoken: String {
        let price = row.last.map { "last price \($0) baht, value \(valueText)" } ?? "no price yet"
        return "\(row.ticker), \(ShareFormat.grouped(row.quantity)) shares, \(price)"
    }
}

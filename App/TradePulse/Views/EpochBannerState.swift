import SwiftUI
import TradeNetworking

/// Whether the "server restarted" banner of one screen is showing, as a plain value.
///
/// The banner is visible exactly while the number of epoch changes the trading state counts is above the number the
/// user dismissed it at. Dismissing remembers the count at that moment and never lowers what was remembered, so the
/// next restart (a higher count) shows the banner again and a count that went back down cannot bring it back.
struct EpochBannerState: Equatable {
    /// The number of epoch changes at the time of the last dismissal; 0 until the banner has been dismissed.
    var dismissedAt = 0

    /// Whether the banner shows when the trading state has counted `epochChanges` epoch changes.
    func isVisible(epochChanges: Int) -> Bool {
        epochChanges > dismissedAt
    }

    /// Hides the banner for the restarts counted so far.
    mutating func dismiss(epochChanges: Int) {
        dismissedAt = max(dismissedAt, epochChanges)
    }
}

/// The strip that says the server started over: the orders and the balances on screen were read again from it. It
/// shows while the trading state has counted more epoch changes than the user dismissed it at, and each screen that
/// shows it keeps its own `EpochBannerState`, so dismissing it on one screen leaves the other as it was.
///
/// The button sits beside the text, except at the accessibility text sizes: there the text would be left a column too
/// narrow for its words, so the button goes under it and both take the width of the screen. The text wraps between
/// words and is never cut, and the tint stays below the title of the screen.
///
/// It reads the trading state in its own body, so that an order or a fill tells this view and not the screen around it.
/// It also reads the text size, which changes only when the user changes it.
struct EpochBannerView: View {
    /// What the banner says.
    static let text = "Server restarted \u{2014} your orders and balances were reloaded"

    /// The store whose epoch changes are counted.
    let trading: TradingStore
    /// What the user dismissed.
    @Binding var state: EpochBannerState
    /// The text size the user chose, which decides whether the button is beside the text or under it.
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The text with its button while the banner is visible, and nothing otherwise.
    var body: some View {
        if state.isVisible(epochChanges: trading.state.epochChanges) {
            content
                .font(.footnote.weight(.semibold))
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.15), ignoresSafeAreaEdges: [])
                .accessibilityElement(children: .contain)
        }
    }

    /// The text and the button, in a row or, at the accessibility text sizes, one under the other.
    @ViewBuilder private var content: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                message
                Button(action: dismiss) {
                    Text("Dismiss")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                message
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Dismiss", action: dismiss)
            }
        }
    }

    /// What the server did, on as many lines as the words need.
    private var message: some View {
        Label(Self.text, systemImage: "arrow.triangle.2.circlepath")
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Hides the banner for the restarts counted so far.
    private func dismiss() {
        state.dismiss(epochChanges: trading.state.epochChanges)
    }
}

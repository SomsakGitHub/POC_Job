import SwiftUI
import TradeNetworking

/// The strip under the badge that says when the prices on screen may be out of date, and shows the configuration
/// notice when there is one.
///
/// It is a pure view of its three inputs, so the same state always draws the same banner. It is empty when both
/// connections are up and there is no notice.
struct ConnectionBanner: View {
    /// What the banner says while either connection is not up.
    static let reconnectingText = "Reconnecting\u{2026}"

    /// The state of the market feed.
    let market: ConnectionState
    /// The state of the order stream.
    let trading: ConnectionState
    /// A line about how the app was configured (see `AppEnvironment.configNotice(for:)`), shown whether or not there is
    /// a connection problem.
    let notice: String?

    /// Whether the banner must say "Reconnecting…": true unless both connections are `.connected`. A connection that
    /// is still being made, one that is waiting to retry and one that has been stopped all count, because in none of
    /// them is the data on screen known to be live.
    nonisolated static func isProblem(market: ConnectionState, trading: ConnectionState) -> Bool {
        market != .connected || trading != .connected
    }

    /// The strip: the problem line when a connection is not up, the notice under it when there is one, and nothing
    /// when there is neither.
    var body: some View {
        let problem = Self.isProblem(market: market, trading: trading)
        if problem || notice != nil {
            VStack(alignment: .leading, spacing: 2) {
                if problem {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.exclamationmark")
                        Text(Self.reconnectingText)
                    }
                    .font(.footnote.weight(.semibold))
                }
                if let notice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.2))
            .accessibilityElement(children: .combine)
        }
    }
}

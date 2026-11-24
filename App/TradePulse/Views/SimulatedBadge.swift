import SwiftUI

/// The strip every screen carries to say that nothing on it is real: the prices, the orders and the account all come
/// from a simulated exchange.
struct SimulatedBadge: View {
    /// The words of the badge, written once so that a test can pin them.
    static let text = "SIMULATED DATA"

    /// The words in small bold type over the bar material, across the full width.
    var body: some View {
        Text(Self.text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(.bar)
    }
}

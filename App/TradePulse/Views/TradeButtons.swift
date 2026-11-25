import Contracts
import SwiftUI
import TradeCore

/// A request to open the order ticket on one side. Each tap makes a new one, so the sheet is built fresh for every
/// presentation and a ticket is never shared between two of them.
struct TicketRequest: Identifiable {
    /// A new id for every request.
    let id = UUID()
    /// The side the ticket opens on.
    let side: Side
}

/// The buy and sell buttons of one symbol, and the order ticket they open as a sheet.
///
/// Both buttons are always on: the ticket says why an order cannot be sent. The body reads nothing that changes, so the
/// buttons are not evaluated again while prices stream and every tap reaches them.
struct TradeButtons: View {
    /// The symbol traded.
    let symbol: SymbolDTO
    /// The app's environment, which the ticket is made over.
    let environment: AppEnvironment
    /// The ticket that is open, if any.
    @State private var request: TicketRequest?

    /// Two buttons side by side, each opening the ticket on its side, or one over the other when the text is too large
    /// for them to share a line.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                button(.buy)
                button(.sell)
            }
            VStack(spacing: 12) {
                button(.buy)
                button(.sell)
            }
        }
        .controlSize(.large)
        .sheet(item: $request) { request in
            OrderTicketScreen(symbol: symbol, side: request.side, environment: environment)
        }
    }

    /// The button that opens the ticket on `side`: green with a plus for a purchase, red with a minus for a sale.
    private func button(_ side: Side) -> some View {
        let word = side == .buy ? "Buy" : "Sell"
        return Button {
            request = TicketRequest(side: side)
        } label: {
            Label(word, systemImage: side == .buy ? "plus.circle.fill" : "minus.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(side == .buy ? .green : .red)
        .accessibilityLabel("\(word) \(symbol.ticker)")
    }
}

import SwiftUI

// The parts of the order ticket that read something which changes while the ticket is open. Each is a view of its own
// so that the body that reads it is the only one evaluated again when it changes: the ticket's own body holds the
// pickers and the fields, and a body that is evaluated at the pace of the prices drops the touches of its controls.

/// The last price, the bid and the ask of the symbol.
///
/// The prices are not observable, so the body reads the pump's tick, which moves when a frame carried new prices, and
/// then reads the prices. Nothing else is read.
struct TicketPriceLine: View {
    /// The ticket.
    let model: OrderTicketViewModel
    /// The app's environment, whose pump says that a frame carried prices.
    let environment: AppEnvironment

    /// One line of text.
    var body: some View {
        let _ = environment.pump.tick
        Text(model.marketLine)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the shares are worth, and the warning that the account may not cover the order.
///
/// The estimate is made from the prices, so the body reads the pump's tick; the warning is made from the cash and the
/// positions, so it reads the trading state. It does not read the age of the market data or a connection.
struct TicketEstimateSection: View {
    /// The ticket.
    let model: OrderTicketViewModel
    /// The app's environment, whose pump says that a frame carried prices.
    let environment: AppEnvironment

    /// The estimate under its label, the note that commission is not in it and the warning when there is one.
    var body: some View {
        let _ = environment.pump.tick
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    label
                    Spacer(minLength: 8)
                    figure
                }
                VStack(alignment: .leading, spacing: 4) {
                    label
                    figure
                }
            }
            Text("Before commission, which the exchange charges on each fill.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let hint = model.balanceHint {
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// "Estimated cost" for a purchase and "Estimated proceeds" for a sale.
    private var label: some View {
        Text(model.side == .buy ? "Estimated cost" : "Estimated proceeds")
            .font(.subheadline)
    }

    /// The estimate in money, on one line.
    private var figure: some View {
        Text(model.estimatedCost)
            .font(.title3.weight(.semibold).monospacedDigit())
            .amountOnOneLine()
    }
}

/// The button that sends the order and, when it is off, the reason it is off.
///
/// The body reads what decides whether the button is on: an order in flight, the age of the market data as the
/// ticket last noted it, the form and the trading connection. None of these changes at the pace of the prices.
struct TicketSubmitSection: View {
    /// The ticket.
    let model: OrderTicketViewModel
    /// The app's environment, whose trading connection decides whether an order can be sent.
    let environment: AppEnvironment

    /// The button, and the reason under it unless the form says the same under its fields.
    var body: some View {
        let reason = model.blockedReason(tradingConnected: environment.tradingConnection == .connected)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await model.submit() }
            } label: {
                Text(model.side == .buy ? "Send buy order" : "Send sell order")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.side == .buy ? .green : .red)
            .controlSize(.large)
            .disabled(reason != nil)
            if let reason, reason != model.validationMessage {
                Label(reason, systemImage: "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The order the ticket sent last, as the trading store has it now: sending, then the exchange's answer, then the fills
/// or the reason it was refused, with the buttons the order allows.
///
/// The body reads the id of the order sent, and the trading state only once there is one, and the trading connection,
/// which decides whether the order can be cancelled.
struct TicketOrderRow: View {
    /// The ticket.
    let model: OrderTicketViewModel
    /// The app's environment.
    let environment: AppEnvironment
    /// Whether a cancel of the order is out.
    @State private var cancelling = false

    /// The title over the order's row, or nothing before an order was sent.
    var body: some View {
        let connected = environment.tradingConnection == .connected
        if let order = model.lastOrder {
            let presentation = OrderRowPresentation(
                row: order, ticker: model.symbol.ticker, tradingConnected: connected
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("Your order")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                OrderRowView(
                    presentation: presentation, isCancelling: cancelling,
                    cancel: { await cancel(presentation) },
                    retry: { await environment.trading.retryUnconfirmed(clientOrderId: order.id) }
                )
            }
        }
    }

    /// Asks the exchange to cancel the order of `presentation`, and keeps the button off until the call returns.
    private func cancel(_ presentation: OrderRowPresentation) async {
        guard let orderId = presentation.orderId else { return }
        cancelling = true
        await environment.trading.cancel(orderId: orderId)
        cancelling = false
    }
}

/// Tells the ticket that the market moved, so that it can look at the age of the market data. It draws nothing and
/// takes no room.
///
/// It is a view of its own so that the pump's tick, which moves at the pace of the prices, is read in this body and not
/// in the ticket's. A change of the market connection is watched as well: a feed that went away is how the data
/// grows old.
struct TicketBridge: View {
    /// The ticket.
    let model: OrderTicketViewModel
    /// The app's environment, whose pump and market connection are watched.
    let environment: AppEnvironment

    /// A view of no size that notices each move of the tick and each change of the market connection.
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: environment.pump.tick) { model.noteMarket() }
            .onChange(of: environment.marketConnection) { model.noteMarket() }
    }
}

import Contracts
import SwiftUI
import TradeCore

/// The order ticket of one symbol, as a sheet: the side and the type, the quantity and the price, what the order is
/// worth, the button that sends it and the order it sent.
///
/// The body of this view reads only what the user changes: the side, the type and the form. It must not read anything
/// that changes at the pace of the prices (the pump's tick, a price, the age of the market data), nor the state of the
/// account or of an order. A body that is evaluated at that pace updates the two segmented pickers again and again, and
/// a control that is updated while a finger is on it drops that touch, so taps would be lost for as long as prices
/// stream. What changes with the prices, the account or the order is read in views of their own, each in its own body
/// (`TicketPriceLine`, `TicketEstimateSection`, `TicketSubmitSection`, `TicketOrderRow` and `TicketBridge`).
///
/// A sheet does not inherit the strip with the badge that the root view carries, so the ticket carries its own. It
/// is a scroll view, so that a large text size still reaches everything.
struct OrderTicketScreen: View {
    /// The two fields that take text, for the button over the keyboard that puts the keyboard away.
    private enum Field {
        /// The quantity.
        case quantity
        /// The limit price.
        case price
    }

    /// The app's environment.
    private let environment: AppEnvironment
    /// What the ticket shows, made once for the screen. It can be read from outside, so that a test can change it and
    /// see whether the body of the screen would be evaluated again.
    @State private(set) var model: OrderTicketViewModel
    /// The field the keyboard is on.
    @FocusState private var focus: Field?
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// The ticket of `symbol` that opens on `side`. `now` is the clock the age of the market data is judged by.
    init(symbol: SymbolDTO, side: Side, environment: AppEnvironment, now: @escaping () -> Int64 = WallClock.nowNs) {
        self.environment = environment
        _model = State(
            initialValue: OrderTicketViewModel(
                symbol: symbol, store: environment.trading, marketState: environment.marketState, side: side, now: now
            )
        )
    }

    /// The badge over a navigation stack with the ticket in it.
    var body: some View {
        VStack(spacing: 0) {
            SimulatedBadge()
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        controls
                        TicketPriceLine(model: model, environment: environment)
                        fields
                        problem
                        TicketEstimateSection(model: model, environment: environment)
                        TicketSubmitSection(model: model, environment: environment)
                        TicketOrderRow(model: model, environment: environment)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("\(model.side == .buy ? "Buy" : "Sell") \(model.symbol.ticker)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focus = nil }
                    }
                }
            }
            .background { TicketBridge(model: model, environment: environment) }
        }
    }

    // MARK: Parts

    /// The ticker over the Thai name.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.symbol.ticker)
                .font(.title2.bold())
            Text(model.symbol.nameTh)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// The pickers for the side and for the type of the order.
    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Side", selection: $model.side) {
                Text("Buy").tag(Side.buy)
                Text("Sell").tag(Side.sell)
            }
            .pickerStyle(.segmented)
            Picker("Order type", selection: $model.type) {
                Text("Market").tag(OrderType.market)
                Text("Limit").tag(OrderType.limit)
            }
            .pickerStyle(.segmented)
        }
    }

    /// The quantity, and the price of a limit order. A market order has no price field: it is priced by the market.
    private var fields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quantity (shares)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Quantity", text: $model.quantityText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .quantity)
                    .accessibilityLabel("Quantity in shares")
            }
            if model.type == .limit {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Limit price (baht)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Limit price", text: $model.priceText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .price)
                        .accessibilityLabel("Limit price in baht")
                }
            }
        }
    }

    /// The first thing wrong with the form, when there is one.
    @ViewBuilder private var problem: some View {
        if let message = model.validationMessage {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}

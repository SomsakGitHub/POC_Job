import SwiftUI
import TradeNetworking

/// The Orders tab: the orders of the account, newest first, with the banner that says the server started over.
///
/// The tab is a thin wrapper around `OrdersScreen`, which takes the environment as an argument so that a test can make
/// one over fakes; a view cannot read the environment before it has a body.
struct OrdersView: View {
    /// The app's environment, put in place by the root view.
    @Environment(AppEnvironment.self) private var environment

    /// The screen over the app's environment.
    var body: some View {
        OrdersScreen(environment: environment)
    }
}

/// The Orders screen: a navigation stack with the banner over the list.
///
/// Its body reads nothing that changes while the app runs: the banner and the list read what they show in bodies of
/// their own, so an order, a fill or a price does not evaluate the screen, and the buttons on the rows are not
/// evaluated again by anything they do not show.
struct OrdersScreen: View {
    /// The app's environment.
    let environment: AppEnvironment
    /// Whether the user dismissed the banner, and at which restart.
    @State private var banner = EpochBannerState()

    /// The banner over the list, under the title.
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                EpochBannerView(trading: environment.trading, state: $banner)
                OrdersList(environment: environment)
            }
            .navigationTitle("Orders")
        }
    }
}

/// The orders as a list, or a note that there are none.
///
/// The rows are the store's orders, newest first. A row's words are made from inside the row's closure, so that a list
/// of thousands of orders makes words only for the rows that are on screen. The body reads the trading state and the
/// trading connection: an order that moves, and a connection that goes, change what the buttons on the rows can do. It
/// never reads a price.
struct OrdersList: View {
    /// The app's environment.
    let environment: AppEnvironment
    /// The ids of the orders a cancel is out for.
    @State private var cancelling: Set<String> = []

    /// The list, or the note when there are no orders.
    var body: some View {
        let orders = environment.trading.state.orders
        let connected = environment.tradingConnection == .connected
        if orders.isEmpty {
            // The note is in a scroll view, so that a large text size still reaches all of it; it is at least as tall
            // as the screen, so that it stays in the middle when it fits.
            GeometryReader { screen in
                ScrollView {
                    ContentUnavailableView(
                        "No orders yet", systemImage: "list.bullet.rectangle",
                        description: Text("An order you send shows up here with its status.")
                    )
                    .frame(minHeight: screen.size.height)
                }
            }
        } else {
            List(orders) { order in
                let presentation = OrderRowPresentation(
                    row: order, ticker: environment.symbols.ticker(for: order.symbolId), tradingConnected: connected
                )
                OrderRowView(
                    presentation: presentation, isCancelling: cancelling.contains(order.id),
                    cancel: { await cancel(presentation) },
                    retry: { await environment.trading.retryUnconfirmed(clientOrderId: order.id) }
                )
            }
            .listStyle(.plain)
        }
    }

    /// Asks the exchange to cancel the order of `presentation`, and keeps its button off until the call returns.
    private func cancel(_ presentation: OrderRowPresentation) async {
        guard let orderId = presentation.orderId else { return }
        cancelling.insert(presentation.id)
        await environment.trading.cancel(orderId: orderId)
        cancelling.remove(presentation.id)
    }
}

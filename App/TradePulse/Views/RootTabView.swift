import SwiftUI

/// The tabs of the app, under a strip that carries the simulated-data badge and the connection banner.
///
/// The strip is the first child of a stack and the tab view is the second, so the tab view, and with it the navigation
/// bar of every tab, starts below the strip, and no screen has to know that the strip is there. The strip cannot be an
/// inset of the tab view's safe area instead: such an inset reaches the content of a tab but does not move the
/// navigation bars of the stacks inside it, so each bar would still start under the status bar with the strip drawn
/// over its upper half.
struct RootTabView: View {
    /// The app's environment, put in place by the app.
    @Environment(AppEnvironment.self) private var environment

    /// The strip with the four tabs under it.
    var body: some View {
        VStack(spacing: 0) {
            // The words of the strip sit below the status bar. The background of each part reaches up under it, as a
            // background does unless it is told not to.
            VStack(spacing: 0) {
                SimulatedBadge()
                ConnectionBanner(
                    market: environment.marketConnection,
                    trading: environment.tradingConnection,
                    notice: environment.configNotice
                )
            }
            TabView {
                MarketListView()
                    .tabItem { Label("Market", systemImage: "chart.line.uptrend.xyaxis") }
                OrdersView()
                    .tabItem { Label("Orders", systemImage: "list.bullet.rectangle") }
                PortfolioView()
                    .tabItem { Label("Portfolio", systemImage: "briefcase") }
                LabView()
                    .tabItem { Label("Lab", systemImage: "slider.horizontal.3") }
            }
        }
    }
}

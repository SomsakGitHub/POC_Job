import SwiftUI

/// The tabs of the app, with the simulated-data badge and the connection banner above all of them.
struct RootTabView: View {
    /// The app's environment, put in place by the app.
    @Environment(AppEnvironment.self) private var environment

    /// The four tabs under the badge and the banner.
    var body: some View {
        TabView {
            MarketListView()
                .tabItem { Label("Market", systemImage: "chart.line.uptrend.xyaxis") }
            PlaceholderTab(title: "Orders")
                .tabItem { Label("Orders", systemImage: "list.bullet.rectangle") }
            PlaceholderTab(title: "Portfolio")
                .tabItem { Label("Portfolio", systemImage: "briefcase") }
            PlaceholderTab(title: "Lab")
                .tabItem { Label("Lab", systemImage: "slider.horizontal.3") }
        }
        // One inset for the whole tab view, so that every tab shows the badge and the banner and no screen has to
        // remember to.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                SimulatedBadge()
                ConnectionBanner(
                    market: environment.marketConnection,
                    trading: environment.tradingConnection,
                    notice: environment.configNotice
                )
            }
        }
    }
}

/// A tab whose screen has not been built yet.
private struct PlaceholderTab: View {
    /// The name of the tab, which is also its navigation title.
    let title: String

    /// A navigation stack that says the tab is not available yet.
    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: "hammer", description: Text("This tab is not available yet."))
                .navigationTitle(title)
        }
    }
}

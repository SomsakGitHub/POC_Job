import SwiftUI
import Testing
import TradeNetworking
@testable import TradePulse

/// The four things a connection can be.
private let connectionStates: [ConnectionState] = [.connecting, .connected, .reconnecting(attempt: 1), .stopped]

/// Every pair of states but the one in which both connections are up.
private let problemPairs: [(ConnectionState, ConnectionState)] = connectionStates.flatMap { market in
    connectionStates.compactMap { trading in
        market == .connected && trading == .connected ? nil : (market, trading)
    }
}

/// When the banner speaks, the words of the banner and the badge, and what a banner of each kind draws.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConnectionBannerTests {
    // MARK: When there is a problem

    @Test func nothingIsWrongWhenBothConnectionsAreUp() {
        #expect(!ConnectionBanner.isProblem(market: .connected, trading: .connected))
    }

    @Test(arguments: problemPairs)
    func anythingButBothConnectionsUpIsAProblem(market: ConnectionState, trading: ConnectionState) {
        #expect(ConnectionBanner.isProblem(market: market, trading: trading))
    }

    // MARK: Words

    @Test func theBannerSaysReconnectingWithOneEllipsisCharacter() {
        #expect(ConnectionBanner.reconnectingText == "Reconnecting\u{2026}")
        #expect(ConnectionBanner.reconnectingText.last == "\u{2026}")
        #expect(!ConnectionBanner.reconnectingText.contains("..."))
    }

    @Test func theBadgeSaysThatTheDataIsSimulated() {
        #expect(SimulatedBadge.text == "SIMULATED DATA")
    }

    // MARK: What is drawn

    /// The room `content` takes in a column as wide as a phone and as tall as it needs; zero when it takes none.
    private func laidOutSize(_ content: some View) -> CGSize {
        UIHostingController(rootView: content).sizeThatFits(in: CGSize(width: 390, height: 10_000))
    }

    /// Whether `size` has no area, which is what a view that shows nothing takes.
    private func isEmpty(_ size: CGSize) -> Bool {
        size.width == 0 || size.height == 0
    }

    @Test func theBannerIsEmptyWhenBothConnectionsAreUpAndThereIsNoNotice() {
        let size = laidOutSize(ConnectionBanner(market: .connected, trading: .connected, notice: nil))
        #expect(isEmpty(size))
    }

    @Test func aProblemMakesTheBannerAppear() {
        let size = laidOutSize(ConnectionBanner(market: .reconnecting(attempt: 2), trading: .connected, notice: nil))
        #expect(!isEmpty(size))
    }

    @Test func aNoticeAloneMakesTheBannerAppear() {
        let size = laidOutSize(ConnectionBanner(market: .connected, trading: .connected, notice: "Using 127.0.0.1"))
        #expect(!isEmpty(size))
    }

    @Test func aNoticeIsAnExtraLineBelowTheProblem() {
        let problem = laidOutSize(ConnectionBanner(market: .stopped, trading: .connected, notice: nil))
        let both = laidOutSize(ConnectionBanner(market: .stopped, trading: .connected, notice: "Using 127.0.0.1"))
        #expect(!isEmpty(problem))
        #expect(both.height > problem.height)
    }
}

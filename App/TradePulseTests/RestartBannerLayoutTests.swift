import SwiftUI
import Testing
@testable import TradePulse

/// How the "server restarted" banner sits on the screen: the words are not squeezed into a narrow column at the largest
/// text size, the button stays beside the text at the regular size, and the tint stays below the title of the screen.
/// A layout is judged by the size it asks for and by a drawing of it, not by a screen that this suite does not have.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RestartBannerLayoutTests {
    /// A banner of a trading store whose server has started over once, that nobody dismissed.
    private func restartedBanner() async throws -> EpochBannerView {
        let rig = await ScreenRig.started()
        try await rig.deliverEpoch("E1")
        try await rig.deliverEpoch("E2")
        try #require(rig.env.trading.state.epochChanges == 1, "the server started over once")
        return EpochBannerView(trading: rig.env.trading, state: .constant(EpochBannerState()))
    }

    /// The banner of a server that started over once and that the user dismissed.
    private func dismissedBanner() async throws -> EpochBannerView {
        let rig = await ScreenRig.started()
        try await rig.deliverEpoch("E1")
        try await rig.deliverEpoch("E2")
        return EpochBannerView(trading: rig.env.trading, state: .constant(EpochBannerState(dismissedAt: 1)))
    }

    @Test func theBannerDoesNotTakeOverTheScreenAtTheLargestTextSize() async throws {
        let banner = try await restartedBanner()
        let dismissed = try await dismissedBanner()

        let height = LayoutRig.height(of: banner, at: .accessibility5, width: LayoutRig.screenWidth)
        let hidden = LayoutRig.height(of: dismissed, at: .accessibility5, width: LayoutRig.screenWidth)

        #expect(hidden == 0, "the control: a dismissed banner takes no room")
        #expect(height > 100, "the control: a banner that shows takes room, \(height) pt")
        #expect(height < LayoutRig.screenHeight * 0.6, "the banner is \(height) pt tall")
    }

    @Test func theButtonStaysBesideTheTextAtTheRegularTextSize() async throws {
        let banner = try await restartedBanner()

        let regular = LayoutRig.height(of: banner, at: .large, width: LayoutRig.screenWidth)
        let largest = LayoutRig.height(of: banner, at: .accessibility5, width: LayoutRig.screenWidth)

        #expect(regular > 20, "the control: the banner shows, \(regular) pt")
        #expect(regular < 80, "the text takes two lines and the button is beside it, \(regular) pt")
        #expect(largest > 3 * regular, "the control: the largest size is another layout, \(largest) pt")
    }

    @Test func theTintStopsAtTheSafeAreaAndStartsWithTheBanner() async throws {
        let banner = try await restartedBanner()
        let size = CGSize(width: LayoutRig.screenWidth, height: 400)
        let screen = VStack(spacing: 0) {
            banner
            Spacer()
        }

        let drawing = try #require(LayoutRig.draw(screen, size: size, safeAreaTop: 120), "there is a window to draw in")
        let picture = drawing.picture
        let top = drawing.safeAreaTop
        let underTheTitle = picture.color(at: CGPoint(x: 4, y: top / 2))
        let inTheBanner = picture.color(at: CGPoint(x: 4, y: top + 6))
        let below = picture.color(at: CGPoint(x: 4, y: size.height - 10))

        #expect(top > 120, "the safe area is there: \(top) pt")
        #expect(below == [255, 255, 255, 255], "the control: nothing under the banner is drawn, \(below)")
        #expect(inTheBanner != below, "the control: the banner is tinted, \(inTheBanner)")
        #expect(underTheTitle == below, "nothing under the title is tinted, \(underTheTitle)")
    }
}

import Testing
@testable import TradePulse

/// When the "server restarted" banner shows: exactly while the trading state has counted more epoch changes than the
/// count the banner was dismissed at.
@Suite(.timeLimit(.minutes(1)))
struct EpochBannerStateTests {
    @Test func theBannerIsHiddenWhenTheServerNeverRestarted() {
        let state = EpochBannerState()

        #expect(state.dismissedAt == 0)
        #expect(!state.isVisible(epochChanges: 0))
    }

    @Test func theBannerShowsOnceTheServerRestarted() {
        let state = EpochBannerState()

        #expect(state.isVisible(epochChanges: 1))
        #expect(state.isVisible(epochChanges: 5))
    }

    @Test func dismissingHidesTheBannerForTheRestartsCountedSoFar() {
        var state = EpochBannerState()

        state.dismiss(epochChanges: 1)

        #expect(state.dismissedAt == 1)
        #expect(!state.isVisible(epochChanges: 1), "at the count it was dismissed at, the banner stays hidden")
    }

    @Test func aNewRestartShowsTheBannerAgain() {
        var state = EpochBannerState()
        state.dismiss(epochChanges: 1)

        #expect(state.isVisible(epochChanges: 2))

        state.dismiss(epochChanges: 2)
        #expect(!state.isVisible(epochChanges: 2))
        #expect(state.isVisible(epochChanges: 3))
    }

    @Test func aSmallerCountAfterADismissalStaysHidden() {
        var state = EpochBannerState()
        state.dismiss(epochChanges: 3)

        for count in [2, 1, 0, -1] {
            #expect(!state.isVisible(epochChanges: count), "\(count)")
        }
        #expect(state.isVisible(epochChanges: 4), "the control: a higher count shows it")
    }

    @Test func dismissingAtASmallerCountKeepsTheLargerOne() {
        var state = EpochBannerState()
        state.dismiss(epochChanges: 3)

        state.dismiss(epochChanges: 1)

        #expect(state.dismissedAt == 3)
        #expect(!state.isVisible(epochChanges: 3))
        #expect(state.isVisible(epochChanges: 4))
    }

    @Test func dismissingBeforeAnyRestartChangesNothingButTheNextRestartStillShows() {
        var state = EpochBannerState()

        state.dismiss(epochChanges: 0)

        #expect(state == EpochBannerState())
        #expect(!state.isVisible(epochChanges: 0))
        #expect(state.isVisible(epochChanges: 1))
    }

    @Test func theLargestCountDoesNotTrap() {
        var state = EpochBannerState()

        #expect(state.isVisible(epochChanges: Int.max))
        state.dismiss(epochChanges: Int.max)

        #expect(!state.isVisible(epochChanges: Int.max))
        #expect(state.dismissedAt == Int.max)
    }

    @Test func eachScreenHasItsOwnStateAndTheSameCountShowsEachBannerUntilItIsDismissed() {
        var orders = EpochBannerState()
        let portfolio = EpochBannerState()

        orders.dismiss(epochChanges: 1)

        #expect(!orders.isVisible(epochChanges: 1))
        #expect(portfolio.isVisible(epochChanges: 1), "dismissing on one screen does not hide the other")
    }

    @MainActor
    @Test func theBannerSaysTheServerStartedOverInTheExactWords() {
        let text = EpochBannerView.text

        #expect(text == "Server restarted \u{2014} your orders and balances were reloaded")
        #expect(text.unicodeScalars.contains("\u{2014}"), "the long dash, not a hyphen")
        #expect(!text.contains(" - "))
    }
}

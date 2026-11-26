import Testing
@testable import TradePulse

/// When the rate slider asks the server for a change. A drag moves the slider many times a second, and the server must
/// hear of it once, when the finger lifts; a change that has no drag behind it (VoiceOver's adjust action moves the
/// slider one step at a time) is a request of its own.
@Suite(.timeLimit(.minutes(1)))
struct RateSliderStateTests {
    @Test func aSliderShowsTheRateItWasGiven() {
        let slider = RateSliderState(rate: 2.5)

        #expect(slider.shown == 2.5)
        #expect(!slider.isDragging)
    }

    @Test func aDragSendsOneRateWhenTheFingerLifts() {
        var slider = RateSliderState(rate: 1)

        let touchDown = slider.editing(true)
        let moves = [1.5, 2, 2.5, 3].map { slider.slide(to: $0) }
        let during = slider.shown
        let draggingNow = slider.isDragging
        let lifted = slider.editing(false)

        #expect(touchDown == nil)
        #expect(moves.count == 4)
        #expect(moves.allSatisfy { $0 == nil })
        #expect(during == 3)
        #expect(draggingNow)
        #expect(lifted == 3)
        #expect(!slider.isDragging)
        #expect(slider.shown == 3)
    }

    @Test func aDragThatEndsWhereItBeganSendsNothing() {
        var slider = RateSliderState(rate: 1)
        _ = slider.editing(true)
        _ = slider.slide(to: 2)
        _ = slider.slide(to: 1)
        let backWhereItWas = slider.editing(false)

        // The control: the next drag, which ends somewhere else, does send.
        _ = slider.editing(true)
        _ = slider.slide(to: 3)
        let somewhereElse = slider.editing(false)

        #expect(backWhereItWas == nil)
        #expect(somewhereElse == 3)
    }

    @Test func aTouchThatDoesNotMoveTheSliderSendsNothing() {
        var slider = RateSliderState(rate: 1)

        let down = slider.editing(true)
        let up = slider.editing(false)
        let upAgain = slider.editing(false)
        // The control: a move after them is still sent.
        let afterwards = slider.slide(to: 2)

        #expect(down == nil)
        #expect(up == nil)
        #expect(upAgain == nil)
        #expect(afterwards == 2)
    }

    @Test func eachStepOfTheAdjustActionIsARequestOfItsOwn() {
        var slider = RateSliderState(rate: 1)

        let first = slider.slide(to: 1.5)
        let second = slider.slide(to: 2)

        #expect(first == 1.5)
        #expect(second == 2)
        #expect(slider.shown == 2)
    }

    @Test func theServersAnswerMovesTheSliderOnlyWhileNoFingerIsOnIt() {
        var slider = RateSliderState(rate: 1)
        slider.follow(4)
        let atRest = slider.shown

        _ = slider.editing(true)
        _ = slider.slide(to: 2)
        slider.follow(1)
        let whileDragging = slider.shown
        let lifted = slider.editing(false)
        slider.follow(2.5)

        #expect(atRest == 4)
        #expect(whileDragging == 2)
        #expect(lifted == 2)
        // The server answered a request of 2 with the rate it holds, which is what the slider shows after the drag.
        #expect(slider.shown == 2.5)
    }
}

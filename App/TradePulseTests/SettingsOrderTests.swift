import Testing
@testable import TradePulse

/// Whose answer counts when requests for the settings overlap, said without a server: a read and a change, started
/// and ended in each of the orders they can come in.
@Suite(.timeLimit(.minutes(1)))
struct SettingsOrderTests {
    @Test func aReadThatNothingOverlapsCounts() {
        var order = SettingsOrder()

        let read = order.startRead()

        #expect(order.counts(read))
    }

    @Test func ofTwoReadsTheNewerOneCounts() {
        var order = SettingsOrder()

        let older = order.startRead()
        let newer = order.startRead()

        #expect(!order.counts(older))
        #expect(order.counts(newer))
    }

    @Test func ofTwoChangesTheNewerOneCountsWhateverEndsFirst() {
        var order = SettingsOrder()
        let older = order.startChange()
        let newer = order.startChange()
        let whileBothAreOnTheirWay = (order.counts(older), order.counts(newer))

        order.endChange()
        order.endChange()

        #expect(whileBothAreOnTheirWay == (false, true))
        #expect(!order.counts(older))
        #expect(order.counts(newer))
    }

    @Test func aChangeCountsWhateverReadsStartedAfterIt() {
        var order = SettingsOrder()
        let change = order.startChange()

        _ = order.startRead()
        _ = order.startRead()
        let whileItIsOnItsWay = order.counts(change)
        order.endChange()

        #expect(whileItIsOnItsWay)
        #expect(order.counts(change))
    }

    @Test func aReadThatStartedWhileAChangeWasOnItsWayNeverCounts() {
        var order = SettingsOrder()
        let change = order.startChange()
        let read = order.startRead()
        let whileTheChangeIsOnItsWay = order.counts(read)

        order.endChange()

        #expect(!whileTheChangeIsOnItsWay)
        #expect(!order.counts(read), "not even when the change has ended")
        #expect(order.counts(change))
    }

    @Test func aReadThatAChangeStartedDuringNeverCounts() {
        var order = SettingsOrder()
        let read = order.startRead()
        let beforeTheChange = order.counts(read)

        let change = order.startChange()
        let whileTheChangeIsOnItsWay = order.counts(read)
        order.endChange()

        #expect(beforeTheChange, "the control: nothing had overlapped it yet")
        #expect(!whileTheChangeIsOnItsWay)
        #expect(!order.counts(read), "not even when the change has ended")
        #expect(order.counts(change))
    }

    @Test func aReadThatStartedAfterAChangeEndedCounts() {
        var order = SettingsOrder()
        let change = order.startChange()
        order.endChange()

        let read = order.startRead()

        #expect(order.counts(read))
        #expect(order.counts(change))
    }

    @Test func aReadThatStartedWhileOneOfTwoChangesWasStillOnItsWayNeverCounts() {
        var order = SettingsOrder()
        _ = order.startChange()
        _ = order.startChange()
        order.endChange()

        let read = order.startRead()
        order.endChange()
        let afterBothEnded = order.startRead()

        #expect(!order.counts(read))
        #expect(order.counts(afterBothEnded), "the control: a read that started after both ended counts")
    }
}

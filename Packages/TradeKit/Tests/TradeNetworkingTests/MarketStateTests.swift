import Contracts
import Testing
import TradeCore
import TradeNetworking

/// What an update does to a snapshot, how sequence numbers are judged, and the counters an observer reads. The
/// latency samples are in `MarketStateLatencyTests.swift` and the many-tasks test is in
/// `MarketStateConcurrencyTests.swift`; both extend this suite.
@Suite("MarketStateTests")
struct MarketStateTests {
    // MARK: The snapshot

    @Test func applyStoresSnapshot() throws {
        let rig = StateRig()
        var update = Tp_SymbolUpdate()
        update.symbolID = 7
        update.seq = 3
        update.last = 3_450
        update.bid = 3_445
        update.ask = 3_455
        update.bidQty = 900
        update.askQty = 1_100
        update.dayVolume = 54_300
        update.candle1S = wireCandle(openTimeMs: 5_000, price: 3_450, volume: 11)
        update.candle1M = wireCandle(openTimeMs: 60_000, price: 3_451, volume: 22)
        var fiveMinutes = wireCandle(openTimeMs: 300_000, price: 3_452, volume: 33)
        fiveMinutes.open = 3_400
        fiveMinutes.high = 3_460
        fiveMinutes.low = 3_390
        update.candle5M = fiveMinutes
        update.eventNs = 99

        let gaps = rig.apply(update, receivedAtNs: 1_500)

        let expected = SymbolSnapshot(
            symbolId: 7, seq: 3, last: Price(satang: 3_450), bid: Price(satang: 3_445), ask: Price(satang: 3_455),
            bidQty: 900, askQty: 1_100, dayVolume: 54_300,
            candle1s: Candle(
                openTimeMs: 5_000, open: Price(satang: 3_450), high: Price(satang: 3_450), low: Price(satang: 3_450),
                close: Price(satang: 3_450), volume: 11
            ),
            candle1m: Candle(
                openTimeMs: 60_000, open: Price(satang: 3_451), high: Price(satang: 3_451),
                low: Price(satang: 3_451), close: Price(satang: 3_451), volume: 22
            ),
            candle5m: Candle(
                openTimeMs: 300_000, open: Price(satang: 3_400), high: Price(satang: 3_460),
                low: Price(satang: 3_390), close: Price(satang: 3_452), volume: 33
            ),
            appliedAtNs: 1_500, gapCount: 0
        )
        let snapshot = try #require(rig.state.snapshot(7))
        #expect(gaps.isEmpty)
        #expect(snapshot == expected)
        #expect(rig.state.snapshot(8) == nil)
        #expect(rig.state.version == 1)
        #expect(rig.state.lastFrameAtNs == 1_500)
    }

    /// Each symbol keeps its own snapshot, sequence and gap count; the newest update replaces the older state.
    @Test func eachSymbolKeepsItsOwnState() throws {
        let rig = StateRig()
        rig.apply(symbolUpdate(symbol: 1, seq: 1, last: 3_000), symbolUpdate(symbol: 2, seq: 1, last: 5_000))
        rig.apply(symbolUpdate(symbol: 1, seq: 2, last: 3_100))
        let first = try #require(rig.state.snapshot(1))
        let second = try #require(rig.state.snapshot(2))
        #expect(first.last == Price(satang: 3_100))
        #expect(first.seq == 2)
        #expect(second.last == Price(satang: 5_000))
        #expect(second.seq == 1)
    }

    /// Values are taken as they come: a bid, an ask or a quantity of 0 stays 0, and nothing is rounded or filled in
    /// from the update before.
    @Test func pricesAreTakenAsTheyCome() throws {
        let rig = StateRig()
        var update = symbolUpdate(seq: 1, last: 3_427)
        update.bid = 0
        update.ask = 0
        update.bidQty = 0
        update.askQty = 0
        rig.apply(update)
        let snapshot = try #require(rig.state.snapshot(1))
        #expect(snapshot.last == Price(satang: 3_427))
        #expect(snapshot.bid == Price(satang: 0))
        #expect(snapshot.ask == Price(satang: 0))
        #expect(snapshot.bidQty == 0)
        #expect(snapshot.askQty == 0)
    }

    /// `appliedAtNs` is when the frame was received, whatever the frame says about its own send time.
    @Test func appliedAtIsTheReceiveTimeOfTheFrame() throws {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: 1), sendNs: 800, receivedAtNs: 4_321)
        #expect(rig.state.snapshot(1)?.appliedAtNs == 4_321)
        rig.apply(symbolUpdate(seq: 2), sendNs: 900, receivedAtNs: 9_876)
        #expect(rig.state.snapshot(1)?.appliedAtNs == 9_876)
    }

    /// An update that carries no candle for an interval leaves that interval's candle as it was; before there is
    /// one, the candle is all zeros. A candle that is present replaces the old one.
    @Test func updateWithoutCandleKeepsThePreviousCandle() throws {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: 1, last: 3_400, candles: false))
        let empty = Candle(
            openTimeMs: 0, open: Price(satang: 0), high: Price(satang: 0), low: Price(satang: 0),
            close: Price(satang: 0), volume: 0
        )
        let first = try #require(rig.state.snapshot(1))
        #expect(first.candle1s == empty)
        #expect(first.candle1m == empty)
        #expect(first.candle5m == empty)

        rig.apply(symbolUpdate(seq: 2, last: 3_410, candles: true))
        let withCandles = try #require(rig.state.snapshot(1))
        #expect(withCandles.candle1s.close == Price(satang: 3_410))
        #expect(withCandles.candle1m.close == Price(satang: 3_410))
        #expect(withCandles.candle5m.close == Price(satang: 3_410))

        // Only the 1-minute candle is present: the other two keep what they had.
        var partial = symbolUpdate(seq: 3, last: 3_420, candles: false)
        partial.candle1M = wireCandle(openTimeMs: 120_000, price: 3_420, volume: 9)
        rig.apply(partial)
        let kept = try #require(rig.state.snapshot(1))
        #expect(kept.last == Price(satang: 3_420))
        #expect(kept.candle1s == withCandles.candle1s)
        #expect(kept.candle5m == withCandles.candle5m)
        #expect(kept.candle1m.openTimeMs == 120_000)
        #expect(kept.candle1m.close == Price(satang: 3_420))

        // A later update with no candle at all keeps the new 1-minute candle too.
        rig.apply(symbolUpdate(seq: 4, last: 3_430, candles: false))
        let latest = try #require(rig.state.snapshot(1))
        #expect(latest.last == Price(satang: 3_430))
        #expect(latest.candle1m == kept.candle1m)
        #expect(latest.candle1s == kept.candle1s)
        #expect(latest.candle5m == kept.candle5m)
    }

    // MARK: Sequence numbers

    @Test func gapIsReported() throws {
        let rig = StateRig()
        let first = rig.apply(symbolUpdate(seq: 3, last: 3_400))
        let jumped = rig.apply(symbolUpdate(seq: 5, last: 3_500))
        let snapshot = try #require(rig.state.snapshot(1))
        #expect(first == [])
        #expect(jumped == [1])
        #expect(snapshot.gapCount == 1)
        // The update that jumped is applied, not dropped, and its number is the new baseline.
        #expect(snapshot.seq == 5)
        #expect(snapshot.last == Price(satang: 3_500))
    }

    /// A gap of exactly one missing number is a gap; the next number in line is not one.
    @Test func gapIsReportedOnceAndTheNextSeqIsNotAGap() throws {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: 1))
        let jumped = rig.apply(symbolUpdate(seq: 3))
        #expect(jumped == [1])
        // A resync answer carries the next number: not a second report of the same gap.
        let next = rig.apply(symbolUpdate(seq: 4))
        let afterNext = rig.apply(symbolUpdate(seq: 5))
        #expect(next == [])
        #expect(afterNext == [])
        #expect(rig.state.snapshot(1)?.gapCount == 1)
        // Another jump later is a gap of its own.
        let jumpedAgain = rig.apply(symbolUpdate(seq: 9))
        #expect(jumpedAgain == [1])
        #expect(rig.state.snapshot(1)?.gapCount == 2)
        let calm = rig.apply(symbolUpdate(seq: 10))
        #expect(calm == [])
        #expect(rig.state.snapshot(1)?.gapCount == 2)
    }

    @Test func staleSeqIgnored() throws {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: 5, last: 3_500), sendNs: 1_000, receivedAtNs: 1_500)
        let before = try #require(rig.state.snapshot(1))
        let version = rig.state.version
        let toApp = rig.count(.tickToApp)
        let toApplied = rig.count(.tickToApplied)
        #expect(version == 1)
        #expect(toApp == 1)

        let older = rig.apply(symbolUpdate(seq: 4, last: 9_999), sendNs: 2_000, receivedAtNs: 2_500)
        let repeated = rig.apply(symbolUpdate(seq: 5, last: 8_888), sendNs: 3_000, receivedAtNs: 3_500)
        let far = rig.apply(symbolUpdate(seq: 1, last: 7_777), sendNs: 4_000, receivedAtNs: 4_500)

        // Nothing was reported, nothing changed, nothing was recorded.
        #expect(older == [])
        #expect(repeated == [])
        #expect(far == [])
        #expect(rig.state.snapshot(1) == before)
        #expect(rig.state.version == version)
        #expect(rig.count(.tickToApp) == toApp)
        #expect(rig.count(.tickToApplied) == toApplied)
        // The frames still arrived, which is what the feed's liveness is read from.
        #expect(rig.state.lastFrameAtNs == 4_500)

        // Positive control: the next number in line is applied as usual.
        let next = rig.apply(symbolUpdate(seq: 6, last: 3_600), sendNs: 5_000, receivedAtNs: 5_500)
        #expect(next == [])
        let after = try #require(rig.state.snapshot(1))
        #expect(after.seq == 6)
        #expect(after.last == Price(satang: 3_600))
        #expect(after.gapCount == 0)
        #expect(rig.state.version == version + 1)
        #expect(rig.count(.tickToApp) == toApp + 1)
        #expect(rig.count(.tickToApplied) == toApplied + 1)
    }

    /// The server numbers a connection from 1 and a reopened connection starts over: the first update of a symbol
    /// after `beginConnection()` is a baseline, never stale and never a gap, and the last prices stay readable until
    /// it replaces them.
    @Test func beginConnectionResetsSeq() throws {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: 3, last: 3_400))
        let jumped = rig.apply(symbolUpdate(seq: 5, last: 3_500))
        #expect(jumped == [1])
        #expect(rig.state.snapshot(1)?.gapCount == 1)
        let version = rig.state.version

        rig.state.beginConnection()

        // The snapshot survives, and its gap count starts over with the connection.
        let kept = try #require(rig.state.snapshot(1))
        #expect(kept.last == Price(satang: 3_500))
        #expect(kept.seq == 5)
        #expect(kept.gapCount == 0)
        #expect(rig.state.version == version)

        // Seq 1 is lower than 5, yet it is the first of the new connection: applied, no gap.
        let first = rig.apply(symbolUpdate(seq: 1, last: 3_300))
        let afterFirst = try #require(rig.state.snapshot(1))
        #expect(first == [])
        #expect(afterFirst.seq == 1)
        #expect(afterFirst.last == Price(satang: 3_300))
        #expect(afterFirst.gapCount == 0)
        #expect(rig.state.version == version + 1)

        // From there the usual rules apply on the new connection.
        let jumpedAgain = rig.apply(symbolUpdate(seq: 3, last: 3_350))
        #expect(jumpedAgain == [1])
        #expect(rig.state.snapshot(1)?.gapCount == 1)
        let stale = rig.apply(symbolUpdate(seq: 2, last: 1))
        #expect(stale == [])
        #expect(rig.state.snapshot(1)?.last == Price(satang: 3_350))
    }

    /// The first update after a new connection is a baseline even when it is far from the old numbers, and a
    /// connection can begin again and again.
    @Test func firstUpdateOfAConnectionIsAlwaysABaseline() throws {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: 1))
        rig.state.beginConnection()
        let far = rig.apply(symbolUpdate(seq: 900))
        #expect(far == [])
        #expect(rig.state.snapshot(1)?.gapCount == 0)
        rig.state.beginConnection()
        rig.state.beginConnection()
        let again = rig.apply(symbolUpdate(seq: 2))
        #expect(again == [])
        #expect(rig.state.snapshot(1)?.seq == 2)
        // A symbol that has not been seen on this connection yet is a baseline of its own.
        let other = rig.apply(symbolUpdate(symbol: 2, seq: 40))
        #expect(other == [])
        #expect(rig.state.snapshot(2)?.gapCount == 0)
    }

    /// The numbering is per symbol: a jump on one symbol says nothing about the others.
    @Test func eachSymbolIsNumberedOnItsOwn() throws {
        let rig = StateRig()
        rig.apply(symbolUpdate(symbol: 1, seq: 1), symbolUpdate(symbol: 2, seq: 1))
        let gaps = rig.apply(symbolUpdate(symbol: 1, seq: 2), symbolUpdate(symbol: 2, seq: 3))
        #expect(gaps == [2])
        #expect(rig.state.snapshot(1)?.gapCount == 0)
        #expect(rig.state.snapshot(2)?.gapCount == 1)
    }

    /// Every symbol that jumped in a frame is reported once, in the order of the frame (not sorted by symbol).
    @Test func gapsAreReportedOncePerCallInFrameOrder() {
        let rig = StateRig()
        rig.apply(
            symbolUpdate(symbol: 3, seq: 1), symbolUpdate(symbol: 1, seq: 1), symbolUpdate(symbol: 5, seq: 1),
            symbolUpdate(symbol: 2, seq: 1)
        )
        let gaps = rig.apply(
            symbolUpdate(symbol: 3, seq: 5), symbolUpdate(symbol: 1, seq: 9), symbolUpdate(symbol: 5, seq: 2),
            symbolUpdate(symbol: 2, seq: 4)
        )
        #expect(gaps == [3, 1, 2])

        // The same symbol jumping twice inside one frame is still reported once, though both jumps are counted.
        rig.apply(symbolUpdate(symbol: 4, seq: 1))
        let twice = rig.apply(symbolUpdate(symbol: 4, seq: 5), symbolUpdate(symbol: 4, seq: 9))
        #expect(twice == [4])
        #expect(rig.state.snapshot(4)?.gapCount == 2)
        #expect(rig.state.snapshot(4)?.seq == 9)
    }

    /// A sequence number can be any `UInt64`: nothing overflows on the way to the gap test, and the largest number
    /// is a baseline like any other.
    @Test func extremeSequenceNumbersNeverTrap() throws {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: .max - 1))
        let first = rig.apply(symbolUpdate(seq: .max))
        let repeated = rig.apply(symbolUpdate(seq: .max))
        #expect(first == [])
        #expect(repeated == [])
        #expect(rig.state.snapshot(1)?.seq == .max)
        rig.state.beginConnection()
        let zero = rig.apply(symbolUpdate(seq: 0))
        let jumped = rig.apply(symbolUpdate(seq: .max))
        #expect(zero == [])
        #expect(jumped == [1])
    }

    // MARK: Version and the last frame

    /// The version goes up once per call that applied something, however many updates it carried.
    @Test func versionGoesUpOncePerAppliedFrame() {
        let rig = StateRig()
        #expect(rig.state.version == 0)
        rig.apply(symbolUpdate(symbol: 1, seq: 1), symbolUpdate(symbol: 2, seq: 1), symbolUpdate(symbol: 3, seq: 1))
        #expect(rig.state.version == 1)
        rig.apply(symbolUpdate(symbol: 1, seq: 2))
        #expect(rig.state.version == 2)
        // A frame of stale updates only applies nothing and leaves the version alone.
        rig.apply(symbolUpdate(symbol: 1, seq: 2), symbolUpdate(symbol: 2, seq: 1))
        #expect(rig.state.version == 2)
        // A frame with one stale and one new update applies something.
        rig.apply(symbolUpdate(symbol: 1, seq: 2), symbolUpdate(symbol: 2, seq: 2))
        #expect(rig.state.version == 3)
    }

    @Test func emptyFrameDoesNotBumpVersionButUpdatesLastFrameAt() throws {
        let rig = StateRig()
        #expect(rig.state.lastFrameAtNs == 0)
        rig.apply(symbolUpdate(seq: 1), sendNs: 1_000, receivedAtNs: 1_500)
        let snapshot = try #require(rig.state.snapshot(1))
        #expect(rig.state.version == 1)
        #expect(rig.state.lastFrameAtNs == 1_500)
        #expect(rig.count(.tickToApp) == 1)
        #expect(rig.count(.tickToApplied) == 1)

        // A heartbeat, stamped like any frame: it proves the feed is alive and nothing else.
        let gaps = rig.apply(sendNs: 2_000, receivedAtNs: 9_000)
        #expect(gaps == [])
        #expect(rig.state.version == 1)
        #expect(rig.state.lastFrameAtNs == 9_000)
        #expect(rig.state.snapshot(1) == snapshot)
        #expect(rig.count(.tickToApp) == 1)
        #expect(rig.count(.tickToApplied) == 1)

        // Positive control: a frame with an update still counts after a heartbeat.
        rig.apply(symbolUpdate(seq: 2), sendNs: 3_000, receivedAtNs: 9_500)
        #expect(rig.state.version == 2)
        #expect(rig.state.lastFrameAtNs == 9_500)
        #expect(rig.count(.tickToApp) == 2)
    }

    @Test func isFreshHonoursMaxAge() {
        let rig = StateRig()
        // No frame yet: not fresh, however generous the limit.
        #expect(!rig.state.isFresh(nowNs: 0, maxAgeNs: .max))
        #expect(!rig.state.isFresh(nowNs: 10_000, maxAgeNs: 500))

        rig.apply(symbolUpdate(seq: 1), receivedAtNs: 10_000)
        #expect(rig.state.isFresh(nowNs: 10_000, maxAgeNs: 500))
        #expect(rig.state.isFresh(nowNs: 10_499, maxAgeNs: 500))
        // The limit itself is still fresh; one nanosecond more is not.
        #expect(rig.state.isFresh(nowNs: 10_500, maxAgeNs: 500))
        #expect(!rig.state.isFresh(nowNs: 10_501, maxAgeNs: 500))
        #expect(!rig.state.isFresh(nowNs: 20_000, maxAgeNs: 500))
        // A clock that went backwards reads as an age of 0.
        #expect(rig.state.isFresh(nowNs: 9_000, maxAgeNs: 0))
        #expect(rig.state.isFresh(nowNs: 10_000, maxAgeNs: 0))
        #expect(!rig.state.isFresh(nowNs: 10_001, maxAgeNs: 0))
        // No age fits under a negative limit, not even the age 0 that a clock gone backwards reads as.
        #expect(!rig.state.isFresh(nowNs: 10_000, maxAgeNs: -1))
        #expect(!rig.state.isFresh(nowNs: 9_000, maxAgeNs: -1))

        // A heartbeat renews it.
        #expect(!rig.state.isFresh(nowNs: 30_000, maxAgeNs: 500))
        rig.apply(sendNs: 2_000, receivedAtNs: 29_900)
        #expect(rig.state.isFresh(nowNs: 30_000, maxAgeNs: 500))
    }

    /// "No frame yet" and "a frame received at time 0" are different things: a client whose clock reads 0 is not told
    /// that its feed is dead.
    @Test func aFrameReceivedAtTimeZeroIsStillAFrame() {
        let rig = StateRig()
        #expect(!rig.state.isFresh(nowNs: 0, maxAgeNs: 100))
        rig.apply(sendNs: 1_000, receivedAtNs: 0)
        #expect(rig.state.isFresh(nowNs: 0, maxAgeNs: 100))
        #expect(rig.state.isFresh(nowNs: 100, maxAgeNs: 100))
        #expect(!rig.state.isFresh(nowNs: 101, maxAgeNs: 100))
    }

    /// The age is worked out without overflow, whatever the times are.
    @Test func freshnessArithmeticNeverTraps() {
        let rig = StateRig()
        rig.apply(symbolUpdate(seq: 1), receivedAtNs: .min)
        #expect(!rig.state.isFresh(nowNs: .max, maxAgeNs: .max))
        #expect(rig.state.isFresh(nowNs: .min, maxAgeNs: 0))
        rig.apply(symbolUpdate(seq: 2), receivedAtNs: .max)
        #expect(rig.state.isFresh(nowNs: .min, maxAgeNs: 0))
        #expect(rig.state.isFresh(nowNs: .max, maxAgeNs: 0))
    }

    // MARK: Reset

    @Test func resetClearsSnapshotsAndBumpsVersion() throws {
        let rig = StateRig()
        rig.apply(symbolUpdate(symbol: 1, seq: 3), symbolUpdate(symbol: 2, seq: 7), receivedAtNs: 5_000)
        rig.apply(symbolUpdate(symbol: 1, seq: 9))
        let version = rig.state.version
        #expect(version == 2)
        #expect(rig.state.snapshot(1)?.gapCount == 1)
        #expect(rig.state.isFresh(nowNs: 1_500, maxAgeNs: 1_000))
        let toApp = rig.count(.tickToApp)

        rig.state.reset()

        #expect(rig.state.snapshot(1) == nil)
        #expect(rig.state.snapshot(2) == nil)
        #expect(rig.state.version == version + 1)
        #expect(rig.state.lastFrameAtNs == 0)
        #expect(!rig.state.isFresh(nowNs: 1_500, maxAgeNs: .max))
        // The recorder belongs to the caller: a reset of the market does not touch it.
        #expect(rig.count(.tickToApp) == toApp)

        // The numbering is forgotten too: seq 1 is lower than the 9 seen before the reset, yet it is a baseline.
        let gaps = rig.apply(symbolUpdate(seq: 1, last: 3_300))
        let fresh = try #require(rig.state.snapshot(1))
        #expect(gaps == [])
        #expect(fresh.seq == 1)
        #expect(fresh.gapCount == 0)
        #expect(rig.state.version == version + 2)
        // The version never goes back, so a second reset is one more step.
        rig.state.reset()
        #expect(rig.state.version == version + 3)
    }

    /// A reset forgets a frame that was waiting to be rendered, and keeps the clock offset, which belongs to the
    /// connection's clocks and not to the market data.
    @Test func resetForgetsThePendingRenderStampButKeepsTheOffset() {
        let rig = StateRig()
        rig.state.setClockOffset(10)
        rig.apply(symbolUpdate(seq: 1), sendNs: 100, receivedAtNs: 120)
        rig.state.reset()
        rig.state.markRendered(atNs: 150)
        #expect(rig.count(.tickToRender) == 0)

        rig.apply(symbolUpdate(seq: 1), sendNs: 100, receivedAtNs: 120)
        rig.state.markRendered(atNs: 150)
        #expect(rig.latency.summary(.tickToRender) == summary(of: [60], metric: .tickToRender))
        #expect(rig.latency.summary(.tickToApp) == summary(of: [30, 30]))
    }
}

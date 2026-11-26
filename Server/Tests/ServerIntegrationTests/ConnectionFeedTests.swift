import Contracts
import ExchangeCore
import Testing
import TradeCore
@testable import ExchangeServerKit

/// The per-connection state on its own, without tasks or clocks: conflation, ordering, numbering and withholding.
@Suite("ConnectionFeedTests")
struct ConnectionFeedTests {
    private func take(_ feed: inout ConnectionFeed, drop: Bool = false, heartbeat: Bool = false) -> Tp_MarketFrame? {
        feed.takeFrame(serverSendNs: 42, dropUpdates: drop, heartbeatDue: heartbeat)
    }

    @Test func aFrameCarriesTheLatestQuoteOfEachSymbolInAscendingSymbolOrder() throws {
        var feed = ConnectionFeed()
        for symbolId: UInt32 in [5, 1, 3] { feed.subscribe(symbolId, current: nil) }
        for round: Int64 in 1...3 {
            for symbolId: UInt32 in [3, 5, 1] { _ = feed.offer(makeQuote(symbolId, last: 100 * Int64(symbolId) + round)) }
        }
        #expect(feed.pendingCount == 3)

        let frame = try #require(take(&feed))
        #expect(frame.updates.map(\.symbolID) == [1, 3, 5])
        #expect(frame.updates.map(\.last) == [103, 303, 503])
        #expect(frame.serverSendNs == 42)
        #expect(frame.frameSeq == 1)
        #expect(!feed.hasPending)
    }

    @Test func nothingIsSentWithoutAQuoteOrADueHeartbeat() throws {
        var feed = ConnectionFeed()
        #expect(take(&feed) == nil)
        let heartbeat = try #require(take(&feed, heartbeat: true))
        #expect(heartbeat.updates.isEmpty)
        #expect(heartbeat.frameSeq == 1)
    }

    @Test func anUnsubscribedSymbolIsNotQueued() {
        var feed = ConnectionFeed()
        let queued = feed.offer(makeQuote(1, last: 100))
        #expect(!queued)
        #expect(feed.pendingCount == 0)
    }

    @Test func seqSurvivesUnsubscribeAndResubscribe() throws {
        var feed = ConnectionFeed()
        feed.subscribe(1, current: makeQuote(1, last: 100))
        _ = take(&feed)
        feed.unsubscribe(1)
        feed.subscribe(1, current: makeQuote(1, last: 101))
        let again = try #require(take(&feed))
        #expect(again.updates.map(\.seq) == [2])
        feed.resync(makeQuote(1, last: 102))
        let resynced = try #require(take(&feed))
        #expect(resynced.updates.map(\.seq) == [3])
        #expect(resynced.frameSeq == 3)
    }

    /// Across symbols, every second published update is withheld while the setting is on; the frame of a withheld
    /// update alone is not handed out at all, unless a heartbeat is due.
    @Test func dropUpdatesWithholdsEverySecondUpdateAcrossSymbols() throws {
        var feed = ConnectionFeed()
        feed.subscribe(1, current: nil)
        feed.subscribe(2, current: nil)
        _ = feed.offer(makeQuote(1, last: 100))
        _ = feed.offer(makeQuote(2, last: 200))
        let both = try #require(take(&feed, drop: true))
        #expect(both.updates.map(\.symbolID) == [1])  // counter 1 sent, counter 2 withheld

        _ = feed.offer(makeQuote(2, last: 201))
        let third = try #require(take(&feed, drop: true))
        #expect(third.updates.map(\.seq) == [2])  // counter 3 sent

        _ = feed.offer(makeQuote(1, last: 101))
        #expect(take(&feed, drop: true) == nil)  // counter 4 withheld: no frame
        _ = feed.offer(makeQuote(1, last: 102))
        let afterGap = try #require(take(&feed, drop: true))
        #expect(afterGap.updates.map(\.seq) == [3])
        #expect(afterGap.frameSeq == 3)

        _ = feed.offer(makeQuote(1, last: 103))
        let heartbeat = try #require(take(&feed, drop: true, heartbeat: true))  // counter 6 withheld
        #expect(heartbeat.updates.isEmpty)
    }

    /// A state queued by subscribe or resync is sent even with `dropUpdates` on, also when a newer quote replaced it
    /// before it went out, and it does not move the alternation.
    @Test func subscribeAndResyncStatesAreNeverWithheld() throws {
        var feed = ConnectionFeed()
        feed.subscribe(1, current: makeQuote(1, last: 100))
        feed.subscribe(2, current: makeQuote(2, last: 200))
        _ = feed.offer(makeQuote(2, last: 201))
        let states = try #require(take(&feed, drop: true))
        #expect(states.updates.map(\.last) == [100, 201])

        feed.resync(makeQuote(1, last: 101))
        _ = feed.offer(makeQuote(2, last: 202))  // counter 1: sent
        let mixed = try #require(take(&feed, drop: true))
        #expect(mixed.updates.map(\.symbolID) == [1, 2])
        _ = feed.offer(makeQuote(2, last: 203))  // counter 2: withheld
        #expect(take(&feed, drop: true) == nil)
    }

    @Test func theMappingCarriesEveryFieldOfTheQuote() {
        let quote = makeQuote(7, last: 2_040, eventNs: 1_732_000_000_123_456_789)
        let update = MarketFrameMapping.update(quote, seq: 9)
        #expect(update.symbolID == 7)
        #expect(update.seq == 9)
        #expect([update.last, update.bid, update.ask] == [2_040, 2_015, 2_065])
        #expect([update.bidQty, update.askQty, update.dayVolume] == [1_007, 2_007, 52_040])
        #expect(update.eventNs == 1_732_000_000_123_456_789)
        for (wire, candle) in [(update.candle1S, quote.candle1s), (update.candle1M, quote.candle1m),
                               (update.candle5M, quote.candle5m)] {
            #expect(wire.openTimeMs == candle.openTimeMs)
            #expect([wire.open, wire.high, wire.low, wire.close] == [candle.open, candle.high, candle.low,
                                                                       candle.close].map(\.satang))
            #expect(wire.volume == candle.volume)
        }
        #expect(update.candle1S.openTimeMs != update.candle1M.openTimeMs)
    }
}

import Contracts
import Foundation
import Synchronization
import Testing
import TradeCore
import TradeNetworking
@testable import ExchangeServerKit

/// The client library's WebSocket market-data client against a real server on ephemeral ports.
///
/// Times the client is designed for (connected and fed within a second, a reconnect within a few) are not asserted as
/// such: every wait fails only after `clientPatience`, and a test that tells "at once" from "only after a delay" makes
/// the two differ by seconds. The suite runs its tests one at a time, because several of them watch for a second or
/// more of silence and a machine busy with other servers would blur it.
@Suite("MarketDataClientTests", .serialized, .timeLimit(.minutes(2)))
struct MarketDataClientTests {
    // MARK: Live updates

    /// Every subscribed symbol gets a snapshot, the first pong marks the client connected, and the steady stream of
    /// binary frames keeps a 2 s watchdog from ever tripping: the client stays connected for 4 s (with nothing but
    /// the first pings' answers, the watchdog would trip about 2.4 s in). No update is missing, so no resync is sent.
    @Test func receivesLiveUpdatesForSubscribedSymbols() async throws {
        try await withFeedClient(watchdog: .seconds(2)) { _, rig in
            rig.client.start()
            await rig.client.subscribe(rig.tickers)
            let connected = await rig.log.wait { $0 == .connected }
            let fed = await eventually(within: clientPatience) { rig.allSymbolsUpdated() }
            #expect(connected != nil)
            #expect(fed)
            #expect(rig.symbols.count == 12)

            let before = rig.state.version
            try await Task.sleep(for: .seconds(4))
            let after = rig.state.version
            let states = rig.log.states
            #expect(states == [.connecting, .connected])
            #expect(after > before)
            #expect(rig.client.resyncCount == 0)
        }
    }

    /// Tickers subscribed before `start` are only stored, and are sent once the connection is up.
    @Test func subscribeBeforeStartIsSentOnConnect() async throws {
        try await withFeedClient { _, rig in
            await rig.client.subscribe(["PTT", "AOT"])
            #expect(rig.state.snapshot(1) == nil)
            rig.client.start()
            let fed = await eventually(within: clientPatience) {
                rig.state.snapshot(1) != nil && rig.state.snapshot(2) != nil
            }
            #expect(fed)
            // Unsubscribed symbols are not sent.
            #expect(rig.state.snapshot(3) == nil)
        }
    }

    /// On an open connection `subscribe` and `unsubscribe` reach the server at once, and an unsubscribed ticker stays
    /// unsubscribed after a reconnect: AOT, added while connected, is fed; once removed it gets nothing more, not
    /// even after the server drops the connection, while PTT, still subscribed, is fed again (the positive control).
    @Test func subscriptionChangesWhileConnectedLastAcrossReconnects() async throws {
        try await withFeedClient { _, rig in
            rig.client.start()
            await rig.client.subscribe(["PTT"])
            let up = await rig.log.wait { $0 == .connected }
            let pttFed = await eventually(within: clientPatience) { rig.state.snapshot(1) != nil }
            await rig.client.subscribe(["AOT"])
            let aotFed = await eventually(within: clientPatience) { rig.state.snapshot(2) != nil }
            #expect(up != nil)
            #expect(pttFed)
            #expect(aotFed)

            await rig.client.unsubscribe(["AOT"])
            // Updates already on their way may still arrive; then nothing more does.
            try await Task.sleep(for: .milliseconds(300))
            let aotLast = rig.state.snapshot(2)?.appliedAtNs
            try await Task.sleep(for: .seconds(1))
            #expect(rig.state.snapshot(2)?.appliedAtNs == aotLast)

            let mark = rig.log.count
            let droppedAtNs = WallClock.nowNs()
            try await rig.rest.dropConnections()
            let reconnected = await rig.log.wait(after: mark) { $0 == .connected }
            let pttRefed = await eventually(within: clientPatience) {
                (rig.state.snapshot(1)?.appliedAtNs ?? 0) > droppedAtNs
            }
            try await Task.sleep(for: .milliseconds(500))
            #expect(reconnected != nil)
            #expect(pttRefed)
            #expect((rig.state.snapshot(2)?.appliedAtNs ?? 0) < droppedAtNs)
        }
    }

    // MARK: Reconnecting

    /// When the server drops every connection the client reconnects by itself, sends its subscriptions again (one
    /// added while it was down too) and its state goes on: every symbol is updated by the new connection and the
    /// version keeps rising. The new connection numbers each symbol's updates from 1 again, and its first updates are
    /// applied at once even though their numbers are far below the old connection's (which has run for 2 s, some 40
    /// updates a symbol): a state that took them for stale would show nothing new until the numbers caught up.
    @Test func reconnectsAfterServerDropsConnections() async throws {
        try await withFeedClient { _, rig in
            rig.client.start()
            await rig.client.subscribe(Array(rig.tickers.dropLast()))
            let fed = await eventually(within: clientPatience) {
                rig.symbols.dropLast().allSatisfy { rig.state.snapshot($0.id) != nil }
            }
            #expect(fed)
            try await Task.sleep(for: .seconds(2))
            let oldSeqs = rig.symbols.dropLast().compactMap { rig.state.snapshot($0.id).map { ($0.symbolId, $0.seq) } }
            #expect(oldSeqs.count == 11)

            let mark = rig.log.count
            let droppedAtNs = WallClock.nowNs()
            try await rig.rest.dropConnections()
            let reconnecting = await rig.log.wait(after: mark) { $0.isReconnecting }
            await rig.client.subscribe([rig.tickers.last ?? ""])
            let connected = await rig.log.wait(after: mark) { $0 == .connected }
            let renumbered = await eventually(within: clientPatience, every: .milliseconds(5)) {
                oldSeqs.allSatisfy { id, seq in (rig.state.snapshot(id)?.seq ?? .max) < seq }
            }
            #expect(renumbered)
            let versionAfterReconnect = rig.state.version
            let refed = await eventually(within: clientPatience) { rig.allSymbolsUpdated(sinceNs: droppedAtNs) }
            let rising = await eventually(within: clientPatience) { rig.state.version > versionAfterReconnect + 10 }

            #expect(reconnecting != nil)
            #expect(connected != nil)
            #expect(refed)
            #expect(rising)
        }
    }

    /// With every frame held back for 5 s by the lab, a client with a 1 s watchdog gives the silent connection up and
    /// reconnects.
    @Test func watchdogReconnectsWhenFeedGoesSilent() async throws {
        try await withFeedClient(watchdog: .seconds(1)) { _, rig in
            rig.client.start()
            await rig.client.subscribe(rig.tickers)
            let up = await rig.log.wait { $0 == .connected }
            #expect(up != nil)
            let mark = rig.log.count
            try await rig.lab(LabPatch(extraLatencyMs: 10_000))
            let reconnecting = await rig.log.wait(after: mark) { $0 == .reconnecting(attempt: 1) }
            #expect(reconnecting != nil)
        }
    }

    /// A silent connection the watchdog would hold on to for 30 s ends at once when the client is nudged: well within
    /// 2 s of the nudge.
    @Test func nudgeAfterSilentDeathReconnectsImmediately() async throws {
        try await withFeedClient(watchdog: .seconds(30)) { _, rig in
            rig.client.start()
            await rig.client.subscribe(rig.tickers)
            let up = await rig.log.wait { $0 == .connected }
            #expect(up != nil)
            try await rig.lab(LabPatch(extraLatencyMs: 10_000))
            try await Task.sleep(for: .seconds(1))
            let mark = rig.log.count
            let nudgedAt = ContinuousClock.now
            rig.client.nudge()
            let reconnecting = await rig.log.wait(after: mark) { $0.isReconnecting }
            #expect(reconnecting.map { $0 - nudgedAt < .seconds(2) } == true)
            #expect(rig.log.states.prefix(mark) == [.connecting, .connected])
        }
    }

    /// Answers to the client's own messages count as activity: with every binary frame held back for 5 s, error
    /// answers to a subscription of an unknown ticker, five a second, keep a 2 s watchdog quiet for 5 s. Once they
    /// stop, the watchdog trips (the positive control).
    @Test func textMessagesKeepTheWatchdogQuiet() async throws {
        try await withFeedClient(watchdog: .seconds(2)) { _, rig in
            rig.client.start()
            let up = await rig.log.wait { $0 == .connected }
            #expect(up != nil)
            try await rig.lab(LabPatch(extraLatencyMs: 5_000))
            let quietUntil = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < quietUntil {
                await rig.client.subscribe(["NOPE"])
                try await Task.sleep(for: .milliseconds(200))
            }
            let mark = rig.log.count
            #expect(rig.log.states == [.connecting, .connected])
            let reconnecting = await rig.log.wait(after: mark) { $0.isReconnecting }
            #expect(reconnecting != nil)
        }
    }

    /// `start` after `stop` connects again with the stored subscriptions, and the new connection's updates are
    /// applied.
    @Test func startAfterStopConnectsAgain() async throws {
        try await withFeedClient { _, rig in
            rig.client.start()
            await rig.client.subscribe(rig.tickers)
            let up = await rig.log.wait { $0 == .connected }
            #expect(up != nil)
            let fed = await eventually(within: clientPatience) { rig.allSymbolsUpdated() }
            #expect(fed)
            await rig.client.stop()
            await rig.log.finished()

            let restartedAtNs = WallClock.nowNs()
            // A stream asked for before the new `start` would only replay `.stopped`.
            rig.client.start()
            let log = StateLog(rig.client.connection)
            let connected = await log.wait { $0 == .connected }
            let version = rig.state.version
            let refed = await eventually(within: clientPatience) { rig.allSymbolsUpdated(sinceNs: restartedAtNs) }
            let rising = await eventually(within: clientPatience) { rig.state.version > version + 10 }
            await rig.client.stop()
            await log.finished()
            #expect(log.states.first == .connecting)
            #expect(connected != nil)
            #expect(refed)
            #expect(rising)
        }
    }
}

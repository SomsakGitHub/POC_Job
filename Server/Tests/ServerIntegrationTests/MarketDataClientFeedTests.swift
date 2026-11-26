import Contracts
import Foundation
import Synchronization
import Testing
import TradeCore
import TradeNetworking
@testable import ExchangeServerKit

/// The market-data client's clock offset, its answers to gaps, and how it treats a server that never answers.
extension MarketDataClientTests {
    // MARK: Clock offset

    /// On loopback the two clocks are one, so the offset the pings measure is close to 0.
    @Test func clockOffsetNearZeroOnLoopback() async throws {
        try await withFeedClient { _, rig in
            rig.client.start()
            let up = await rig.log.wait { $0 == .connected }
            #expect(up != nil)
            // Long enough for all the first rounds of pings.
            try await Task.sleep(for: .seconds(1))
            let offset = rig.client.clockOffsetNs
            #expect(abs(offset) < 5_000_000, "offset \(offset) ns")
        }
    }

    /// A server clock 2 s ahead is measured as an offset of 2 s, with the sign and unit right. When the server clock
    /// steps on between connections (to 3, 4, 5 and 6 s ahead), each new connection measures the new offset from its
    /// own pings. A client that kept its best sample across connections would hold on to an old offset whenever no
    /// ping of the new connection had a shorter round trip than every earlier one, which over four steps is all but
    /// certain to happen.
    @Test func clockOffsetTracksASkewedServerClock() async throws {
        let second: Int64 = 1_000_000_000
        let skew = Mutex<Int64>(2 * second)
        let serverNow: @Sendable () -> Int64 = { WallClock.nowNs() + skew.withLock { $0 } }
        try await withFeedClient(serverNowNs: serverNow) { _, rig in
            rig.client.start()
            let tolerance: Int64 = 50_000_000
            let measured = await eventually(within: clientPatience) {
                abs(rig.client.clockOffsetNs - 2 * second) < tolerance
            }
            #expect(measured, "offset \(rig.client.clockOffsetNs) ns")

            for seconds: Int64 in [3, 4, 5, 6] {
                skew.withLock { $0 = seconds * second }
                let mark = rig.log.count
                try await rig.rest.dropConnections()
                let reconnected = await rig.log.wait(after: mark) { $0 == .connected }
                let remeasured = await eventually(within: clientPatience) {
                    abs(rig.client.clockOffsetNs - seconds * second) < tolerance
                }
                #expect(reconnected != nil, "\(seconds) s")
                #expect(remeasured, "\(seconds) s: offset \(rig.client.clockOffsetNs) ns")
            }
        }
    }

    /// Each connection measures the offset from its own pings only. The first connection's pongs come back at once
    /// with a clock 2 s ahead; the second's come back 20 ms late with a clock 5 s ahead. A client that kept the first
    /// connection's samples would keep its offset of 2 s, because each of them had a far shorter round trip than any
    /// of the second's. With a symmetric 20 ms delay the second offset comes out about 10 ms high, well inside the
    /// tolerance.
    @Test func eachConnectionMeasuresTheOffsetFromItsOwnPings() async throws {
        let second: Int64 = 1_000_000_000
        let feed = PongOnlyFeed(
            offsetNs: { $0 == 1 ? 2 * second : 5 * second },
            delay: { $0 == 1 ? .zero : .milliseconds(20) }
        )
        try await feed.run { port in
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let client = WebSocketMarketDataClient(
                config: ClientConfig(host: "127.0.0.1", restPort: port), symbols: [],
                state: MarketState(latency: LatencyRecorder()), latency: LatencyRecorder(), session: session
            )
            let log = StateLog(client.connection)
            client.start()
            let tolerance: Int64 = 50_000_000
            let first = await eventually(within: clientPatience) { abs(client.clockOffsetNs - 2 * second) < tolerance }
            // Long enough for all of the first connection's rounds.
            try await Task.sleep(for: .seconds(1))
            let mark = log.count
            client.nudge()
            let reconnected = await log.wait(after: mark) { $0 == .connected }
            let then = await eventually(within: clientPatience) { abs(client.clockOffsetNs - 5 * second) < tolerance }
            await client.stop()
            await log.finished()
            #expect(first)
            #expect(reconnected != nil)
            #expect(then, "offset \(client.clockOffsetNs) ns")
        }
    }

    // MARK: Gaps

    /// With the lab withholding every other update, a gap in PTT's numbering is answered with a resync, and the
    /// server's full state follows: an update one above the one before it, which with only PTT subscribed no ordinary
    /// update can be (each of those follows a withheld one).
    @Test func gapTriggersResync() async throws {
        let applied = AppliedLog(symbolId: 1)
        try await withFeedClient(applied: applied) { _, rig in
            rig.client.start()
            await rig.client.subscribe(["PTT"])
            let fed = await eventually(within: clientPatience) { rig.state.snapshot(1) != nil }
            #expect(fed)
            try await rig.lab(LabPatch(dropUpdates: true))

            var gapAt: Int?
            _ = await eventually(within: clientPatience) {
                let log = applied.snapshots
                gapAt = log.indices.dropFirst().first { log[$0].gapCount > log[$0 - 1].gapCount }
                return gapAt != nil
            }
            let gapIndex = try #require(gapAt)
            let wholeStateFollowed = await eventually(within: clientPatience) {
                let log = applied.snapshots
                return log.indices.dropFirst(gapIndex + 1).contains {
                    log[$0].seq == log[$0 - 1].seq + 1 && log[$0].gapCount == log[$0 - 1].gapCount
                }
            }
            #expect(wholeStateFollowed)
            #expect(rig.client.resyncCount >= 1)
        }
    }

    /// With all twelve symbols subscribed and every other update withheld for 3 s, almost every update is a gap,
    /// hundreds of them, but each symbol is resynced at most once a second: at most 12 × (whole seconds + 1).
    @Test func resyncIsRateLimited() async throws {
        try await withFeedClient { _, rig in
            rig.client.start()
            await rig.client.subscribe(rig.tickers)
            let fed = await eventually(within: clientPatience) { rig.allSymbolsUpdated() }
            #expect(fed)
            let mark = rig.log.count

            let droppingSince = ContinuousClock.now
            try await rig.lab(LabPatch(dropUpdates: true))
            try await Task.sleep(for: .seconds(3))
            try await rig.lab(LabPatch(dropUpdates: false))
            let count = rig.client.resyncCount
            let elapsed = ContinuousClock.now - droppingSince

            let wholeSeconds = Int(elapsed.components.seconds)
            #expect(count > 0)
            #expect(count <= 12 * (wholeSeconds + 1), "\(count) resyncs in \(elapsed)")
            // One connection throughout: a new one would start its own limits.
            #expect(rig.log.count == mark)
        }
    }

    // MARK: A server that never answers

    /// A server that accepts the connection and never completes the WebSocket handshake: the watchdog gives it up
    /// after its 1 s (the request's own 10 s timeout would take far longer), and since no pong ever came, the client
    /// was never connected.
    @Test func watchdogCoversAHandshakeThatNeverCompletes() async throws {
        try await withSilentFeedClient(watchdog: .seconds(1)) { client, log in
            let startedAt = ContinuousClock.now
            client.start()
            let reconnecting = await log.wait { $0 == .reconnecting(attempt: 1) }
            #expect(reconnecting.map { $0 - startedAt < .seconds(5) } == true)
            #expect(!log.states.contains(.connected))
        }
    }

    /// While the server says nothing, a nudge ends the connection at once (not at the 30 s watchdog or the 10 s
    /// request timeout), and so does `stop()`.
    @Test func stopAndNudgeEndASilentConnectionPromptly() async throws {
        try await withSilentFeedClient(watchdog: .seconds(30)) { client, log in
            client.start()
            try await Task.sleep(for: .milliseconds(300))
            let nudgedAt = ContinuousClock.now
            client.nudge()
            let reconnecting = await log.wait { $0.isReconnecting }
            #expect(reconnecting.map { $0 - nudgedAt < .seconds(3) } == true)

            // The next connection is just as silent.
            try await Task.sleep(for: .milliseconds(800))
            let stopped = await finishes(within: .seconds(3)) { await client.stop() }
            #expect(stopped)
            await log.finished()
            #expect(log.states.last == .stopped)
            #expect(!log.states.contains(.connected))
        }
    }
}

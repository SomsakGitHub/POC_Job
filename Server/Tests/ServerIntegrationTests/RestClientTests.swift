import Contracts
import ExchangeCore
import Foundation
import Synchronization
import Testing
import TradeCore
import TradeNetworking
@testable import ExchangeServerKit

/// The client library's REST client against a real server on ephemeral ports: what it decodes is what the server
/// wrote. The market runner moves the market during every test, so a test never asserts a price that depends on it.
/// `ExchangeServerKit` has an internal `RestError` of its own, so the client's is written `TradeNetworking.RestError`.
@Suite("RestClientTests")
struct RestClientTests {
    @Test func symbolsDecode() async throws {
        try await withClient { _, client in
            let symbols = try await client.symbols()
            let catalog = SymbolCatalog.defaultSymbols
            #expect(symbols.count == 12)
            #expect(symbols.map(\.id) == catalog.map(\.id))
            #expect(symbols.map(\.ticker) == catalog.map(\.ticker))
            // The Thai text arrives byte for byte.
            #expect(symbols.map(\.nameTh) == catalog.map(\.nameTh))
            #expect(symbols.map(\.nameEn) == catalog.map(\.nameEn))
            #expect(symbols.map(\.reference) == catalog.map(\.reference.satang))
            #expect(symbols.allSatisfy { $0.lot == 100 })
        }
    }

    /// The client's candles are the engine's, in ascending order and one interval apart. The last candle of the
    /// answer was still open when the client read it and has moved on since, so it is the only one left out of the
    /// comparison: every other candle has closed and cannot change.
    @Test func candlesDecodeToDomainCandles() async throws {
        try await withClient { app, client in
            var compared = 0
            for interval in CandleInterval.allCases {
                let candles = try await client.candles(ticker: "PTT", interval: interval, limit: 20)
                let engine = await app.engine.candles(symbolId: 1, interval: interval, limit: 1_001)
                let engineByOpenTime = Dictionary(
                    engine.map { ($0.openTimeMs, $0) }, uniquingKeysWith: { first, _ in first }
                )
                #expect(candles.count == 20, "\(interval.label)")

                let steps = zip(candles, candles.dropFirst()).map { $1.openTimeMs - $0.openTimeMs }
                #expect(steps == Array(repeating: Int64(interval.seconds) * 1_000, count: 19), "\(interval.label)")

                for candle in candles.dropLast() {
                    guard let expected = engineByOpenTime[candle.openTimeMs] else {
                        Issue.record("the engine has no \(interval.label) candle opened at \(candle.openTimeMs)")
                        continue
                    }
                    #expect(candle.open == expected.open, "\(interval.label) \(candle.openTimeMs) open")
                    #expect(candle.high == expected.high, "\(interval.label) \(candle.openTimeMs) high")
                    #expect(candle.low == expected.low, "\(interval.label) \(candle.openTimeMs) low")
                    #expect(candle.close == expected.close, "\(interval.label) \(candle.openTimeMs) close")
                    #expect(candle.volume == expected.volume, "\(interval.label) \(candle.openTimeMs) volume")
                    compared += 1
                }
            }
            // 19 closed candles of each of the three intervals.
            #expect(compared == 3 * 19)
        }
    }

    @Test func accountDecode() async throws {
        try await withClient { app, client in
            let empty = try await client.account()
            #expect(empty.cash == 100_000_000)
            #expect(empty.positions.isEmpty)

            try await submitMarket(app.engine, "client-buy", .buy)
            let account = try await client.account()
            let engine = await app.engine.account()
            let positions = Dictionary(uniqueKeysWithValues: account.positions.map { ($0.symbolId, $0.quantity) })
            #expect(account.epoch == engine.epoch)
            #expect(account.cash == engine.cash)
            #expect(account.cash < 100_000_000)
            #expect(positions == engine.positions)
            #expect(positions == [1: 100])
            #expect(account.lastEventSeq == engine.lastEventSeq)
            #expect(account.lastLedgerSeq == engine.lastLedgerSeq)
            #expect(account.lastLedgerSeq == 1)
        }
    }

    @Test func labPatchRoundTrip() async throws {
        try await withClient { _, client in
            let initial = try await client.lab()
            #expect(initial == LabSettings())

            let patch = LabPatch(rateMultiplier: 2.5, extraLatencyMs: 40, jitterMs: 7, dropUpdates: true)
            let patched = try await client.setLab(patch)
            let expected = LabSettings(
                rateMultiplier: 2.5, stress: false, extraLatencyMs: 40, jitterMs: 7, dropUpdates: true
            )
            #expect(patched == expected)
            let read = try await client.lab()
            #expect(read == expected)

            // Only the fields present change; a value out of range comes back as the server clamped it.
            let clamped = try await client.setLab(LabPatch(rateMultiplier: 99, stress: true, extraLatencyMs: 99_999))
            #expect(clamped.rateMultiplier == 10)
            #expect(clamped.stress)
            #expect(clamped.extraLatencyMs == 5_000)
            #expect(clamped.jitterMs == 7)
            #expect(clamped.dropUpdates)

            let reset = try await client.setLab(
                LabPatch(rateMultiplier: 1, stress: false, extraLatencyMs: 0, jitterMs: 0, dropUpdates: false)
            )
            #expect(reset == LabSettings())
        }
    }

    @Test func non200ThrowsHttpError() async throws {
        try await withClient { _, client in
            // Positive control: a known ticker is answered.
            let known = try await client.candles(ticker: "PTT", interval: .m1, limit: 3)
            #expect(known.count == 3)

            // The typed API cannot send a bad interval, so the 400 comes from a ticker the server does not know.
            await #expect(throws: TradeNetworking.RestError.http(status: 400)) {
                try await client.candles(ticker: "NOPE", interval: .m1, limit: 3)
            }
            // A cursor that is not a number is refused the same way.
            await #expect(throws: TradeNetworking.RestError.http(status: 400)) {
                try await client.transactions(cursor: "not-a-number", limit: 5)
            }
            // A ticker with characters that need percent-encoding reaches the server intact and is just unknown.
            await #expect(throws: TradeNetworking.RestError.http(status: 400)) {
                try await client.candles(ticker: "A&B=C D", interval: .m1, limit: 3)
            }
        }
    }

    /// Pages of the ledger, newest first, followed with the cursor the server gives; an empty cursor is the first page.
    @Test func transactionsPageThroughTheCursor() async throws {
        try await withClient { app, client in
            try await makeLedgerEntries(app.engine, count: 3)
            let first = try await client.transactions(cursor: nil, limit: 2)
            let cursor = try #require(first.next)
            #expect(first.items.map(\.ledgerSeq) == [3, 2])
            #expect(cursor == "2")

            let second = try await client.transactions(cursor: cursor, limit: 2)
            #expect(second.items.map(\.ledgerSeq) == [1])
            #expect(second.next == nil)

            let again = try await client.transactions(cursor: "", limit: 2)
            #expect(again == first)
        }
    }

    @Test func timeResetAndDropAreAnswered() async throws {
        try await withClient { app, client in
            let before = WallClock.nowNs()
            let serverNs = try await client.serverTimeNs()
            let after = WallClock.nowNs()
            #expect(serverNs >= before)
            #expect(serverNs <= after)

            // There is no connection to drop, and the answer is still a success.
            try await client.dropConnections()

            let old = try await client.account().epoch
            let epoch = try await client.resetServer()
            let engineEpoch = await app.engine.epoch
            let account = try await client.account()
            #expect(epoch == engineEpoch)
            #expect(epoch != old)
            #expect(account.epoch == epoch)
        }
    }

    // MARK: The symbol list and the session's cache

    /// The client keeps no validator of its own: the session sends the one it holds, the server answers 304, and the
    /// caller is handed the cached body as an ordinary answer. Every other call goes to the server (see the request
    /// tests of the client library).
    @Test func symbolsAreRevalidatedAndTheCachedBodyIsHandedBack() async throws {
        try await withRunningServer { _, ports in
            let collector = StatusCollector()
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 0)
            configuration.requestCachePolicy = .useProtocolCachePolicy
            let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let config = ClientConfig(host: ServerConfig.ephemeral.host, restPort: ports.rest, grpcPort: ports.grpc)
            let client = URLSessionRestClient(config: config, session: session)

            let first = try await client.symbols()
            let second = try await client.symbols()
            #expect(first.count == 12)
            #expect(second == first)

            // The metrics of a task arrive a moment after the task ends.
            let seen = await eventually { collector.networkStatuses.count == 2 }
            #expect(seen)
            #expect(collector.networkStatuses == [[200], [304]])
        }
    }

    // MARK: Helpers

    /// Starts a server, hands `body` the app and a client built from a `ClientConfig` that points at the bound REST
    /// port, then shuts the server down.
    private func withClient(_ body: (ExchangeServerApp, URLSessionRestClient) async throws -> Void) async throws {
        try await withRunningServer { app, ports in
            let config = ClientConfig(host: ServerConfig.ephemeral.host, restPort: ports.rest, grpcPort: ports.grpc)
            try await body(app, URLSessionRestClient(config: config))
        }
    }
}

/// Notes, for every task of a session, the status of each answer that came off the network (an answer served from
/// the cache is not one), to tell a revalidation from a plain load.
private final class StatusCollector: NSObject, URLSessionTaskDelegate, Sendable {
    private let statuses = Mutex<[[Int]]>([])

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let network = metrics.transactionMetrics
            .filter { $0.resourceFetchType == .networkLoad }
            .compactMap { ($0.response as? HTTPURLResponse)?.statusCode }
        statuses.withLock { $0.append(network) }
    }

    var networkStatuses: [[Int]] {
        statuses.withLock { $0 }
    }
}

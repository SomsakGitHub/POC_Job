import Contracts
import ExchangeCore
import Foundation
import Testing
import TradeCore
@testable import ExchangeServerKit

/// The REST routes against a real server on an ephemeral port, reached with a real `URLSession`.
///
/// The market runner moves the market during every test, so no test asserts a price or any other value that depends
/// on the market: only structure, status codes, headers and the ledger's own arithmetic.
@Suite("RestTests")
struct RestTests {
    @Test func healthzReportsEpoch() async throws {
        try await withRestServer { app, client in
            let response = try await client.get("/healthz")
            let health = try response.decode(HealthBody.self)
            let epoch = await app.engine.epoch
            #expect(response.status == 200)
            #expect(health.status == "ok")
            #expect(health.epoch == epoch)
        }
    }

    @Test func symbolsListTwelveWithThaiNames() async throws {
        try await withRestServer { _, client in
            let response = try await client.get("/v1/symbols")
            let symbols = try response.decode([SymbolDTO].self)
            let catalog = SymbolCatalog.defaultSymbols
            #expect(response.status == 200)
            #expect(symbols.count == 12)
            #expect(symbols.contains { $0.ticker == "PTT" })
            #expect(symbols.allSatisfy { !$0.nameTh.isEmpty })
            #expect(symbols.allSatisfy { $0.lot == 100 })
            // Catalog order, and the Thai text arrives byte for byte.
            #expect(symbols.map(\.id) == catalog.map(\.id))
            #expect(symbols.map(\.ticker) == catalog.map(\.ticker))
            #expect(symbols.map(\.nameTh) == catalog.map(\.nameTh))
            #expect(symbols.map(\.nameEn) == catalog.map(\.nameEn))
            #expect(symbols.map(\.reference) == catalog.map(\.reference.satang))
        }
    }

    @Test func symbolsSupportsETag() async throws {
        try await withRestServer { _, client in
            let first = try await client.get("/v1/symbols")
            let etag = try #require(first.header("ETag"))
            #expect(first.status == 200)
            #expect(!first.body.isEmpty)

            let second = try await client.get("/v1/symbols", headers: ["If-None-Match": etag])
            #expect(second.status == 304)
            #expect(second.body.isEmpty)
            #expect(second.header("ETag") == etag)
        }
    }

    @Test func candlesAscendingContiguous() async throws {
        try await withRestServer { _, client in
            let response = try await client.get("/v1/candles?symbol=PTT&interval=1m&limit=50")
            let candles = try response.decode(CandlesResponseDTO.self)
            let steps = zip(candles.candles, candles.candles.dropFirst()).map { $1.t - $0.t }
            #expect(response.status == 200)
            #expect(candles.symbol == "PTT")
            #expect(candles.interval == "1m")
            #expect(candles.candles.count == 50)
            #expect(steps == Array(repeating: 60_000, count: 49))
        }
    }

    @Test func candlesLimitClamped() async throws {
        try await withRestServer { _, client in
            let response = try await client.get("/v1/candles?symbol=PTT&interval=1s&limit=5000")
            let candles = try response.decode(CandlesResponseDTO.self)
            #expect(response.status == 200)
            #expect(candles.candles.count == 1000)
        }
    }

    @Test func candlesBadIntervalIs400() async throws {
        try await withRestServer { _, client in
            let good = try await client.get("/v1/candles?symbol=PTT&interval=1m")
            #expect(good.status == 200)

            let bad = try await client.get("/v1/candles?symbol=PTT&interval=2m")
            let error = try bad.decode(ErrorBody.self)
            #expect(bad.status == 400)
            #expect(!error.error.isEmpty)
        }
    }

    @Test func accountInitial() async throws {
        try await withRestServer { app, client in
            let response = try await client.get("/v1/account")
            let account = try response.decode(AccountDTO.self)
            let epoch = await app.engine.epoch
            #expect(response.status == 200)
            #expect(account.cash == 100_000_000)
            #expect(account.positions.isEmpty)
            #expect(account.lastEventSeq == 0)
            #expect(account.lastLedgerSeq == 0)
            #expect(account.epoch == epoch)
        }
    }

    @Test func accountMatchesTransactionsAfterFills() async throws {
        try await withRestServer { app, client in
            try await submitMarket(app.engine, "fill-1", .buy)
            try await submitMarket(app.engine, "fill-2", .buy)
            try await submitMarket(app.engine, "fill-3", .sell)

            let account = try await client.get("/v1/account").decode(AccountDTO.self)
            let transactions = try await client.get("/v1/transactions?limit=200").decode(TransactionPageDTO.self)

            #expect(transactions.items.count == 3)
            let cashChange = transactions.items.map(\.cashDelta).reduce(0, +)
            #expect(account.cash == 100_000_000 + cashChange)
            var shares: [UInt32: Int64] = [:]
            for entry in transactions.items {
                shares[entry.symbolId, default: 0] += entry.side == "buy" ? entry.quantity : -entry.quantity
            }
            let expected = shares.filter { $0.value != 0 }
            let actual = Dictionary(uniqueKeysWithValues: account.positions.map { ($0.symbolId, $0.quantity) })
            #expect(actual == expected)
            #expect(actual == [1: 100])
            #expect(account.lastLedgerSeq == 3)
            // An order makes more events than the one ledger entry it ends in, so the two numbers are not the same.
            let events = await app.engine.account().lastEventSeq
            #expect(account.lastEventSeq == events)
            #expect(account.lastEventSeq > account.lastLedgerSeq)
        }
    }

    @Test func transactionsPaginate() async throws {
        try await withRestServer { app, client in
            try await submitMarket(app.engine, "fill-1", .buy)
            try await submitMarket(app.engine, "fill-2", .buy)
            try await submitMarket(app.engine, "fill-3", .buy)

            let first = try await client.get("/v1/transactions?limit=2").decode(TransactionPageDTO.self)
            let cursor = try #require(first.next)
            #expect(first.items.map(\.ledgerSeq) == [3, 2])
            #expect(cursor == "2")

            let second = try await client.get("/v1/transactions?limit=2&cursor=\(cursor)")
                .decode(TransactionPageDTO.self)
            #expect(second.items.map(\.ledgerSeq) == [1])
            #expect(second.next == nil)
        }
    }

    @Test func labPatchIsPartial() async throws {
        try await withRestServer { _, client in
            let patched = try await client.post("/v1/admin/lab", json: #"{"stress":true}"#)
            let settings = try patched.decode(LabSettings.self)
            #expect(patched.status == 200)
            #expect(settings.stress == true)
            #expect(settings.rateMultiplier == 1)
            #expect(settings.extraLatencyMs == 0)
            #expect(settings.jitterMs == 0)
            #expect(settings.dropUpdates == false)

            // A second patch leaves what the first one set.
            let second = try await client.post("/v1/admin/lab", json: #"{"jitterMs":30}"#).decode(LabSettings.self)
            #expect(second.stress == true)
            #expect(second.jitterMs == 30)
            #expect(second.rateMultiplier == 1)
            let stored = try await client.get("/v1/admin/lab").decode(LabSettings.self)
            #expect(stored == second)
        }
    }

    @Test func resetChangesEpoch() async throws {
        try await withRestServer { app, client in
            let before = try await client.get("/healthz").decode(HealthBody.self).epoch
            try await submitMarket(app.engine, "before-reset", .buy)

            let reset = try await client.post("/v1/admin/reset")
            let after = try reset.decode(EpochBody.self).epoch
            #expect(reset.status == 200)
            #expect(after != before)

            let health = try await client.get("/healthz").decode(HealthBody.self)
            let account = try await client.get("/v1/account").decode(AccountDTO.self)
            #expect(health.epoch == after)
            #expect(account.epoch == after)
            // The reset started the account over.
            #expect(account.cash == 100_000_000)
            #expect(account.lastLedgerSeq == 0)
            #expect(account.positions.isEmpty)
        }
    }

    @Test func timeIsCloseToNow() async throws {
        try await withRestServer { _, client in
            let before = WallClock.nowNs()
            let response = try await client.get("/v1/time")
            let after = WallClock.nowNs()
            let time = try response.decode(TimeBody.self)
            #expect(response.status == 200)
            #expect(time.serverNs >= before - 1_000_000_000)
            #expect(time.serverNs <= after + 1_000_000_000)
        }
    }

    @Test(arguments: ["/v1/nope", "/", "/v1", "/healthz/extra", "/v1/admin"])
    func unknownRouteIs404(path: String) async throws {
        try await withRestServer { _, client in
            let known = try await client.get("/v1/time")
            #expect(known.status == 200)

            let unknown = try await client.get(path)
            #expect(unknown.status == 404)
        }
    }
}

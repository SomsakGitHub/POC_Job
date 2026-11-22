import Contracts
import CryptoKit
import ExchangeCore
import Foundation
import Testing
import TradeCore
@testable import ExchangeServerKit

/// What the routes answer: JSON bytes and headers, the validator of the symbol list, the shape and order of the
/// account and transaction data, and the admin actions.
extension RestTests {
    // MARK: JSON bytes and headers

    @Test func everyJsonGetRouteDeclaresUtf8Json() async throws {
        let targets = [
            "/healthz", "/v1/time", "/v1/symbols", "/v1/candles?symbol=PTT&interval=1m", "/v1/account",
            "/v1/transactions", "/v1/admin/lab",
        ]
        try await withRestServer { _, client in
            for target in targets {
                let response = try await client.get(target)
                #expect(response.status == 200, "\(target)")
                #expect(response.header("Content-Type") == "application/json; charset=utf-8", "\(target)")
            }
        }
    }

    @Test func everyJsonPostRouteDeclaresUtf8Json() async throws {
        try await withRestServer { _, client in
            let lab = try await client.post("/v1/admin/lab", json: "{}")
            let reset = try await client.post("/v1/admin/reset")
            for (route, response) in [("lab", lab), ("reset", reset)] {
                #expect(response.status == 200, "\(route)")
                #expect(response.header("Content-Type") == "application/json; charset=utf-8", "\(route)")
            }
        }
    }

    /// One encoder with sorted keys writes every body, so the same value always gives the same bytes.
    @Test func bodiesAreWrittenWithSortedKeys() async throws {
        try await withRestServer { app, client in
            let epoch = await app.engine.epoch
            let health = try await client.get("/healthz")
            let account = try await client.get("/v1/account")
            let settings = try await client.get("/v1/admin/lab")
            #expect(health.text == #"{"epoch":"\#(epoch)","status":"ok"}"#)
            let accountText = #"{"cash":100000000,"epoch":"\#(epoch)","#
                + #""lastEventSeq":0,"lastLedgerSeq":0,"positions":[]}"#
            #expect(account.text == accountText)
            let settingsText = #"{"dropUpdates":false,"extraLatencyMs":0,"jitterMs":0,"#
                + #""rateMultiplier":1,"stress":false}"#
            #expect(settings.text == settingsText)
        }
    }

    @Test func resetAnswersTheNewEpochAsAnObject() async throws {
        try await withRestServer { app, client in
            let response = try await client.post("/v1/admin/reset")
            let epoch = await app.engine.epoch
            #expect(response.text == #"{"epoch":"\#(epoch)"}"#)
        }
    }

    /// The body of an error is built by the encoder, so quotes, backslashes and line breaks in a message are escaped.
    @Test func errorBodiesEscapeWhatTheyCarry() throws {
        let message = "say \"hi\" \\ \n and \u{1F600}"
        let data = try RestError(status: .badRequest, message: message).jsonBody()
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        #expect(decoded == ["error": message])
        #expect(String(decoding: data, as: UTF8.self).hasPrefix(#"{"error":"say \"hi\" \\ \n"#))
    }

    // MARK: Validator of the symbol list

    @Test func etagIsAQuotedHashOfTheExactBody() async throws {
        try await withRestServer { _, client in
            let response = try await client.get("/v1/symbols")
            let hash = SHA256.hash(data: response.body).prefix(16).map { String(format: "%02x", $0) }.joined()
            #expect(response.header("ETag") == "\"\(hash)\"")
        }
    }

    @Test func sameBytesGiveTheSameEtagAcrossRequestsAndServers() async throws {
        var etags: [String] = []
        var bodies: [Data] = []
        for _ in 1...2 {
            try await withRestServer { _, client in
                for _ in 1...2 {
                    let response = try await client.get("/v1/symbols")
                    etags.append(try #require(response.header("ETag")))
                    bodies.append(response.body)
                }
            }
        }
        #expect(Set(etags).count == 1)
        #expect(Set(bodies).count == 1)
    }

    @Test func symbolsAreRevalidatedNotCached() async throws {
        try await withRestServer { _, client in
            let response = try await client.get("/v1/symbols")
            #expect(response.header("Cache-Control") == "no-cache")
        }
    }

    /// One value, a list with odd spacing, a weak tag and `*` all match. `{etag}` stands for the current validator.
    @Test func matchingValidatorsGetNotModified() async throws {
        let headers = [
            "{etag}", "W/{etag}", "\"nope\", {etag}", "\"nope\" ,   {etag}  , \"other\"", "W/\"nope\", W/{etag}", "*",
            "  {etag}  ",
        ]
        try await withRestServer { _, client in
            let first = try await client.get("/v1/symbols")
            let etag = try #require(first.header("ETag"))

            for header in headers {
                let value = header.replacing("{etag}", with: etag)
                let response = try await client.get("/v1/symbols", headers: ["If-None-Match": value])
                #expect(response.status == 304, "If-None-Match: \(header)")
                #expect(response.body.isEmpty, "If-None-Match: \(header)")
                #expect(response.header("ETag") == etag, "If-None-Match: \(header)")
                #expect(response.header("Cache-Control") == "no-cache", "If-None-Match: \(header)")
                #expect(response.header("Content-Length") != "\(first.body.count)", "If-None-Match: \(header)")
            }
        }
    }

    /// Anything that is not the current validator answers the full list, a validator that merely contains it included.
    /// `{etag}` stands for the current validator and `{bare}` for the same without its quotes.
    @Test func otherValidatorsGetTheFullList() async throws {
        let headers = ["\"nope\"", "W/\"nope\"", "{etag}x", "x{etag}", "nope", "{bare}", ""]
        try await withRestServer { _, client in
            let first = try await client.get("/v1/symbols")
            let etag = try #require(first.header("ETag"))
            let bare = etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            for header in headers {
                let value = header.replacing("{etag}", with: etag).replacing("{bare}", with: bare)
                let response = try await client.get("/v1/symbols", headers: ["If-None-Match": value])
                #expect(response.status == 200, "If-None-Match: \(header)")
                #expect(response.body == first.body, "If-None-Match: \(header)")
                #expect(response.header("ETag") == etag, "If-None-Match: \(header)")
            }
        }
    }

    // MARK: Candles

    /// A candle of the answer carries the engine's own figures: its open time in milliseconds, its prices in satang and
    /// its volume, with the high and the low bracketing the open and the close. The newest candle is still moving, so
    /// it is left out of the comparison.
    @Test func candlesCarryTheEnginesOwnFigures() async throws {
        try await withRestServer { app, client in
            let target = "/v1/candles?symbol=PTT&interval=1m&limit=30"
            let served = try await client.get(target).decode(CandlesResponseDTO.self)
            let engine = await app.engine.candles(symbolId: 1, interval: .m1, limit: 30)
            let closed = Dictionary(uniqueKeysWithValues: engine.dropLast().map { ($0.openTimeMs, $0) })

            var compared = 0
            for candle in served.candles.dropLast() {
                #expect(candle.l <= min(candle.o, candle.c), "the low of the candle at \(candle.t)")
                #expect(candle.h >= max(candle.o, candle.c), "the high of the candle at \(candle.t)")
                guard let own = closed[candle.t] else { continue }
                compared += 1
                #expect(candle.o == own.open.satang, "the open of the candle at \(candle.t)")
                #expect(candle.h == own.high.satang, "the high of the candle at \(candle.t)")
                #expect(candle.l == own.low.satang, "the low of the candle at \(candle.t)")
                #expect(candle.c == own.close.satang, "the close of the candle at \(candle.t)")
                #expect(candle.v == own.volume, "the volume of the candle at \(candle.t)")
            }
            #expect(compared >= 20, "only \(compared) candles were compared")
        }
    }

    // MARK: Account and transactions

    @Test func accountPositionsAreSortedBySymbolId() async throws {
        try await withRestServer { app, client in
            for symbol in UInt32(1)...12 {
                try await submitMarket(app.engine, "buy-\(symbol)", .buy, symbol: 13 - symbol)
            }
            let account = try await client.get("/v1/account").decode(AccountDTO.self)
            #expect(account.positions.map(\.symbolId) == Array(1...12))
            #expect(account.positions.allSatisfy { $0.quantity == 100 })
            #expect(account.lastLedgerSeq == 12)

            // The last order was for symbol 1, and the page lists the newest entry first.
            let page = try await client.get("/v1/transactions?limit=200").decode(TransactionPageDTO.self)
            #expect(page.items.map(\.symbolId) == Array(1...12))
        }
    }

    @Test func aClosedPositionIsNotListed() async throws {
        try await withRestServer { app, client in
            try await submitMarket(app.engine, "buy", .buy)
            try await submitMarket(app.engine, "sell", .sell)
            let account = try await client.get("/v1/account").decode(AccountDTO.self)
            #expect(account.positions.isEmpty)
            #expect(account.lastLedgerSeq == 2)
        }
    }

    @Test func transactionsReportSidesAndSatangFigures() async throws {
        try await withRestServer { app, client in
            let before = WallClock.nowNs()
            let buyId = try await submitMarket(app.engine, "buy", .buy)
            let sellId = try await submitMarket(app.engine, "sell", .sell)
            let after = WallClock.nowNs()

            let page = try await client.get("/v1/transactions").decode(TransactionPageDTO.self)
            try #require(page.items.count == 2)
            let sell = page.items[0]
            let buy = page.items[1]
            #expect([sell.ledgerSeq, buy.ledgerSeq] == [2, 1])
            #expect([sell.side, buy.side] == ["sell", "buy"])
            #expect([sell.orderId, buy.orderId] == [sellId, buyId])
            #expect([sell.symbolId, buy.symbolId] == [1, 1])
            #expect([sell.quantity, buy.quantity] == [100, 100])
            let sellValue = sell.price * sell.quantity
            let buyValue = buy.price * buy.quantity
            #expect(sell.commission == Commission.compute(notional: sellValue, bps: 15))
            #expect(buy.commission == Commission.compute(notional: buyValue, bps: 15))
            #expect(sell.cashDelta == sellValue - sell.commission)
            #expect(buy.cashDelta == -(buyValue + buy.commission))
            #expect(buy.tsNs >= before && buy.tsNs <= sell.tsNs && sell.tsNs <= after)
        }
    }

    /// Whatever the page size, the pages together hold every entry once, newest first, and the last page says so: a
    /// page that ends exactly at the oldest entry has no `next`, so there is never an empty page to fetch.
    @Test func paginationWalksEveryEntryExactlyOnce() async throws {
        try await withRestServer { app, client in
            try await makeLedgerEntries(app.engine, count: 6)
            for limit in [1, 2, 3, 6, 7, 50] {
                var seen: [UInt64] = []
                var pages = 0
                var cursor: String?
                repeat {
                    let query = "limit=\(limit)" + (cursor.map { "&cursor=\($0)" } ?? "")
                    let page = try await client.get("/v1/transactions?\(query)").decode(TransactionPageDTO.self)
                    #expect(!page.items.isEmpty, "limit \(limit), page \(pages + 1) is empty")
                    seen += page.items.map(\.ledgerSeq)
                    cursor = page.next
                    pages += 1
                } while cursor != nil && pages < 10
                #expect(seen == [6, 5, 4, 3, 2, 1], "limit \(limit)")
                #expect(pages == (6 + limit - 1) / limit, "limit \(limit)")
            }
        }
    }

    @Test func cursorsAtTheEdgesAreAnswered() async throws {
        try await withRestServer { app, client in
            try await makeLedgerEntries(app.engine, count: 6)
            let newest = try await client.get("/v1/transactions?limit=3").decode(TransactionPageDTO.self)
            let beyond = try await client.get("/v1/transactions?limit=3&cursor=1000000").decode(TransactionPageDTO.self)
            let blank = try await client.get("/v1/transactions?limit=3&cursor=").decode(TransactionPageDTO.self)
            let zero = try await client.get("/v1/transactions?limit=3&cursor=0").decode(TransactionPageDTO.self)
            #expect(newest.items.map(\.ledgerSeq) == [6, 5, 4])
            #expect(beyond == newest)
            #expect(blank == newest)
            #expect(zero.items.isEmpty)
            #expect(zero.next == nil)
        }
    }

    // MARK: Admin actions

    @Test func dropConnectionsAnswers204AndEndsEngineStreams() async throws {
        try await withRestServer { app, client in
            let stream = try await app.engine.eventStream(after: 0, clientEpoch: nil)
            let received = Counter()
            let consumer = Task {
                for await _ in stream { received.increment() }
            }
            try await submitMarket(app.engine, "order", .buy)
            let live = await eventually { received.value >= 3 }
            #expect(live, "the stream did not deliver while it was open")

            let response = try await client.post("/v1/admin/drop-connections")
            #expect(response.status == 204)
            #expect(response.body.isEmpty)
            let ended = await finishes(within: patience) { await consumer.value }
            #expect(ended, "the stream stayed open after the connections were dropped")
        }
    }

    @Test func adminActionsDoNotRunOnGet() async throws {
        try await withRestServer { app, client in
            let epoch = await app.engine.epoch
            let stream = try await app.engine.eventStream(after: 0, clientEpoch: nil)
            let ended = Counter()
            let consumer = Task {
                for await _ in stream {}
                ended.increment()
            }

            let reset = try await client.get("/v1/admin/reset")
            let drop = try await client.get("/v1/admin/drop-connections")
            let epochAfterGets = await app.engine.epoch
            #expect(reset.status == 404)
            #expect(drop.status == 404)
            #expect(epochAfterGets == epoch)
            try await Task.sleep(for: .milliseconds(100))
            #expect(ended.value == 0, "a GET ended the engine's streams")

            // The same actions do run on a POST.
            let post = try await client.post("/v1/admin/reset")
            let replaced = try post.decode(EpochBody.self).epoch
            #expect(replaced != epoch)
            let streamEnded = await finishes(within: patience) { await consumer.value }
            #expect(streamEnded)
        }
    }
}

import Contracts
import Foundation
import Testing
import TradeCore
import TradeNetworking

private final class RequestStub: StubProtocol {
    static let shared = StubLedger()

    override class var ledger: StubLedger { shared }
}

/// The request each call makes: where it goes, what it asks, how it may be cached and how long it may take.
///
/// Serialized because every test of the suite answers through the one stub class `RequestStub`, whose script and
/// ledger are shared: two tests at once would overwrite each other's answer and requests.
@Suite("RestRequestTests", .serialized)
struct RestRequestTests {
    private static let candles = #"{"symbol":"PTT","interval":"1m","candles":[]}"#
    private static let transactions = #"{"items":[]}"#
    private static let lab = #"{"rateMultiplier":1,"stress":false,"extraLatencyMs":0,"jitterMs":0,"dropUpdates":false}"#

    /// Every call makes exactly one request, with its method, path and query, to the server the config names, with
    /// the cache policy it needs (only the symbol list keeps the default, so that its validator is used) and a
    /// timeout of 10 s, so that an unreachable server is reported in seconds and not after the default minute.
    @Test(arguments: EndpointCase.all)
    func everyCallMakesItsOneRequest(endpoint: EndpointCase) async throws {
        let config = ClientConfig(host: "10.0.0.5", restPort: 9000)
        let rig = StubRig(RequestStub.self, answer: endpoint.answer, config: config)
        defer { rig.finish() }
        try await endpoint.call(rig.client)

        let seen = try #require(rig.requests.first)
        #expect(rig.requests.count == 1)
        #expect(seen.method == endpoint.method)
        #expect(seen.path == endpoint.path)
        #expect(seen.query == endpoint.query)
        // No name is sent twice, and a request with no query has no "?" at all.
        #expect(seen.queryItems.count == endpoint.query.count)
        #expect((seen.rawQuery == nil) == endpoint.query.isEmpty)
        #expect(seen.request.cachePolicy == endpoint.cachePolicy)
        #expect(seen.request.timeoutInterval == 10)
        #expect(seen.request.url?.scheme == "http")
        #expect(seen.request.url?.host == "10.0.0.5")
        #expect(seen.request.url?.port == 9000)
        #expect(seen.request.url?.fragment == nil)
        // Only the lab patch has a body.
        #expect(seen.body.isEmpty == (endpoint.name != "setLab"))
    }

    // MARK: Query strings

    @Test(arguments: zip([CandleInterval.s1, .m1, .m5], ["1s", "1m", "5m"]))
    func candlesCarrySymbolIntervalAndLimit(interval: CandleInterval, wire: String) async throws {
        let rig = StubRig(RequestStub.self, answer: .json(Self.candles))
        defer { rig.finish() }
        _ = try await rig.client.candles(ticker: "PTT", interval: interval, limit: 300)
        let seen = try #require(rig.requests.first)
        #expect(seen.path == "/v1/candles")
        #expect(seen.rawQuery == "symbol=PTT&interval=\(wire)&limit=300")
        #expect(seen.query == ["symbol": "PTT", "interval": wire, "limit": "300"])
    }

    @Test func transactionsOmitTheCursorWhenItIsNilOrEmpty() async throws {
        let rig = StubRig(RequestStub.self, answer: .json(Self.transactions))
        defer { rig.finish() }
        _ = try await rig.client.transactions(cursor: nil, limit: 25)
        _ = try await rig.client.transactions(cursor: "", limit: 25)
        // Positive control: a cursor that is there is sent.
        _ = try await rig.client.transactions(cursor: "7", limit: 25)

        let requests = rig.requests
        #expect(requests.count == 3)
        let queries = requests.map(\.query)
        #expect(queries == [["limit": "25"], ["limit": "25"], ["limit": "25", "cursor": "7"]])
        #expect(requests.map(\.queryItems.count) == [1, 1, 2])
        #expect(requests.map(\.rawQuery) == ["limit=25", "limit=25", "limit=25&cursor=7"])
    }

    /// A value with characters that mean something in a URL is percent-encoded into one query item, not pasted into
    /// the string where it would split the query or end it.
    @Test func aTickerWithSpecialCharactersIsPercentEncoded() async throws {
        let ticker = "A&B=C D#E%F"
        let rig = StubRig(RequestStub.self, answer: .json(Self.candles))
        defer { rig.finish() }
        _ = try await rig.client.candles(ticker: ticker, interval: .m1, limit: 5)
        let seen = try #require(rig.requests.first)
        #expect(seen.path == "/v1/candles")
        #expect(seen.rawQuery == "symbol=A%26B%3DC%20D%23E%25F&interval=1m&limit=5")
        #expect(seen.queryItems.map(\.name) == ["symbol", "interval", "limit"])
        #expect(seen.query["symbol"] == ticker)
        #expect(seen.request.url?.fragment == nil)
    }

    @Test func aCursorWithSpecialCharactersIsPercentEncoded() async throws {
        let cursor = "1&limit=999 #x"
        let rig = StubRig(RequestStub.self, answer: .json(Self.transactions))
        defer { rig.finish() }
        _ = try await rig.client.transactions(cursor: cursor, limit: 25)
        let seen = try #require(rig.requests.first)
        #expect(seen.rawQuery == "limit=25&cursor=1%26limit%3D999%20%23x")
        #expect(seen.queryItems.count == 2)
        #expect(seen.query == ["limit": "25", "cursor": cursor])
        #expect(seen.request.url?.fragment == nil)
    }

    @Test func nonAsciiTextIsPercentEncodedAsUTF8() async throws {
        let rig = StubRig(RequestStub.self, answer: .json(Self.candles))
        defer { rig.finish() }
        _ = try await rig.client.candles(ticker: "กข", interval: .s1, limit: 1)
        let seen = try #require(rig.requests.first)
        #expect(seen.rawQuery == "symbol=%E0%B8%81%E0%B8%82&interval=1s&limit=1")
        #expect(seen.query["symbol"] == "กข")
    }

    /// The limit is passed on as given: it is the server's to clamp, and negative or huge values do not trap.
    @Test(arguments: [0, -1, 5_000, Int.max, Int.min])
    func theLimitIsSentAsGiven(limit: Int) async throws {
        let rig = StubRig(RequestStub.self, answer: .json(Self.candles))
        defer { rig.finish() }
        _ = try await rig.client.candles(ticker: "PTT", interval: .m1, limit: limit)
        #expect(rig.requests.first?.query["limit"] == String(limit))
    }

    // MARK: The lab patch

    @Test func setLabPostsThePatchAsJSON() async throws {
        let rig = StubRig(RequestStub.self, answer: .json(Self.lab))
        defer { rig.finish() }
        let patch = LabPatch(rateMultiplier: 2.5, stress: true, extraLatencyMs: 40, jitterMs: 7, dropUpdates: false)
        _ = try await rig.client.setLab(patch)
        let seen = try #require(rig.requests.first)
        #expect(seen.method == "POST")
        #expect(seen.path == "/v1/admin/lab")
        #expect(seen.header("Content-Type") == "application/json")
        let sent = try JSONDecoder().decode(LabPatch.self, from: seen.body)
        #expect(sent == patch)
    }

    /// A field that is nil is not in the body, so the server leaves that setting alone.
    @Test func setLabLeavesAbsentFieldsOutOfTheBody() async throws {
        let rig = StubRig(RequestStub.self, answer: .json(Self.lab))
        defer { rig.finish() }
        _ = try await rig.client.setLab(LabPatch(stress: true))
        _ = try await rig.client.setLab(LabPatch())
        let requests = rig.requests
        #expect(requests.count == 2)
        #expect(requests.map { String(decoding: $0.body, as: UTF8.self) } == [#"{"stress":true}"#, "{}"])
    }

    /// A patch that cannot be written as JSON (a rate that is not a number) fails before anything is sent.
    @Test func aPatchThatCannotBeEncodedSendsNothing() async throws {
        let rig = StubRig(RequestStub.self, answer: .json(Self.lab))
        defer { rig.finish() }
        await #expect(throws: EncodingError.self) { try await rig.client.setLab(LabPatch(rateMultiplier: .nan)) }
        await #expect(throws: EncodingError.self) { try await rig.client.setLab(LabPatch(rateMultiplier: .infinity)) }
        #expect(rig.requests.isEmpty)

        // Positive control: the same call with a finite rate goes out.
        _ = try await rig.client.setLab(LabPatch(rateMultiplier: 2))
        #expect(rig.requests.count == 1)
    }

    // MARK: The configuration

    /// A config whose host or port makes no URL still makes requests, to the default server: it does not trap.
    @Test func aConfigThatMakesNoUrlRequestsTheDefaultServer() async throws {
        let config = ClientConfig(host: "bad host", restPort: -1)
        let rig = StubRig(RequestStub.self, answer: .json(Self.lab), config: config)
        defer { rig.finish() }
        _ = try await rig.client.lab()
        let seen = try #require(rig.requests.first)
        #expect(seen.request.url?.absoluteString == "http://127.0.0.1:18080/v1/admin/lab")
    }

    /// The client can be used from many tasks at once; each call is its own request.
    @Test func concurrentCallsAreIndependent() async throws {
        let rig = StubRig(RequestStub.self, answer: .json(Self.transactions))
        defer { rig.finish() }
        let client = rig.client
        let limits = Array(1...8)
        let pages = try await withThrowingTaskGroup(of: Int.self) { group in
            for limit in limits {
                group.addTask {
                    _ = try await client.transactions(cursor: nil, limit: limit)
                    return limit
                }
            }
            var done: [Int] = []
            for try await limit in group {
                done.append(limit)
            }
            return done
        }
        #expect(pages.sorted() == limits)
        #expect(rig.requests.map { $0.query["limit"] ?? "" }.sorted() == limits.map(String.init).sorted())
    }
}

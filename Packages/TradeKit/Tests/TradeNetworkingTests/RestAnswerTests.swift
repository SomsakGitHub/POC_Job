import Contracts
import Foundation
import Testing
import TradeCore
import TradeNetworking

private final class AnswerStub: StubProtocol {
    static let shared = StubLedger()

    override class var ledger: StubLedger { shared }
}

/// What the client makes of an answer: a 2xx body is decoded, any other status is an error of its own, a body that
/// does not decode is another, and a failure of the transport is passed on untouched.
///
/// Serialized because every test of the suite answers through the one stub class `AnswerStub`, whose script and
/// ledger are shared: two tests at once would overwrite each other's answer and requests.
@Suite("RestAnswerTests", .serialized)
struct RestAnswerTests {
    private static let account = #"{"epoch":"E1","cash":99,"positions":[],"lastEventSeq":4,"lastLedgerSeq":2}"#
    private static let accountValue = AccountDTO(
        epoch: "E1", cash: 99, positions: [], lastEventSeq: 4, lastLedgerSeq: 2
    )

    // MARK: Status

    @Test(arguments: [200, 201, 202, 250, 299])
    func aSuccessStatusIsDecoded(status: Int) async throws {
        let rig = StubRig(AnswerStub.self, answer: .json(Self.account, status: status))
        defer { rig.finish() }
        let account = try await rig.client.account()
        #expect(account == Self.accountValue)
    }

    /// The status decides, not the body: each of these carries a perfectly good body and is an error all the same.
    @Test(arguments: [199, 300, 301, 304, 399, 400, 401, 404, 429, 500, 503, 599])
    func anyOtherStatusThrowsAnHttpError(status: Int) async throws {
        let rig = StubRig(AnswerStub.self, answer: .json(Self.account, status: status))
        defer { rig.finish() }
        await #expect(throws: RestError.http(status: status)) { try await rig.client.account() }
        // Whatever the body is, the error is the same.
        let garbage = StubRig(AnswerStub.self, answer: .json("not json at all", status: status))
        defer { garbage.finish() }
        await #expect(throws: RestError.http(status: status)) { try await garbage.client.account() }
    }

    /// Every call maps the status the same way, the ones that read no body included.
    @Test(arguments: EndpointCase.all)
    func everyCallThrowsAnHttpErrorForANonSuccessStatus(endpoint: EndpointCase) async throws {
        let rig = StubRig(AnswerStub.self, answer: .json(#"{"error":"nope"}"#, status: 400))
        defer { rig.finish() }
        await #expect(throws: RestError.http(status: 400)) { try await endpoint.call(rig.client) }
        // Positive control: the same call is fine with its own answer.
        let good = StubRig(AnswerStub.self, answer: endpoint.answer)
        defer { good.finish() }
        try await endpoint.call(good.client)
        #expect(good.requests.count == 1)
    }

    @Test(arguments: [200, 201, 204, 299])
    func dropConnectionsAcceptsAnySuccessStatus(status: Int) async throws {
        let rig = StubRig(AnswerStub.self, answer: .http(status: status))
        defer { rig.finish() }
        try await rig.client.dropConnections()
        #expect(rig.requests.count == 1)
    }

    @Test(arguments: [199, 300, 404, 500])
    func dropConnectionsThrowsForAnyOtherStatus(status: Int) async throws {
        let rig = StubRig(AnswerStub.self, answer: .http(status: status))
        defer { rig.finish() }
        await #expect(throws: RestError.http(status: status)) { try await rig.client.dropConnections() }
    }

    // MARK: Bodies that do not decode

    @Test(arguments: ["", "not json", "{}", "[]", "null", #"{"epoch":5,"cash":1}"#, #"{"epoch":"E","cash":"1"}"#])
    func aBodyThatDoesNotDecodeThrowsDecoding(body: String) async throws {
        let rig = StubRig(AnswerStub.self, answer: .json(body))
        defer { rig.finish() }
        await #expect(throws: RestError.decoding) { try await rig.client.account() }
    }

    /// Each call that reads a body maps a bad one to the same error; the one that reads none does not care.
    @Test(arguments: EndpointCase.all)
    func everyCallThatReadsABodyThrowsDecodingForABadOne(endpoint: EndpointCase) async throws {
        let rig = StubRig(AnswerStub.self, answer: .json("oops"))
        defer { rig.finish() }
        if endpoint.readsBody {
            await #expect(throws: RestError.decoding) { try await endpoint.call(rig.client) }
        } else {
            try await endpoint.call(rig.client)
        }
        #expect(rig.requests.count == 1)
    }

    /// The keys are the property names and a key the client does not know is ignored.
    @Test func unknownKeysAreIgnored() async throws {
        let body = #"{"epoch":"E1","cash":99,"positions":[],"lastEventSeq":4,"lastLedgerSeq":2,"extra":{"a":[1]}}"#
        let rig = StubRig(AnswerStub.self, answer: .json(body))
        defer { rig.finish() }
        let account = try await rig.client.account()
        #expect(account == Self.accountValue)
    }

    // MARK: The transport

    /// A failure of the transport is the caller's to see as it came: not wrapped, not replaced.
    @Test(arguments: [
        URLError.Code.timedOut, .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost, .cancelled,
    ])
    func aTransportFailurePropagatesUnchanged(code: URLError.Code) async throws {
        let rig = StubRig(AnswerStub.self, answer: .failure(code))
        defer { rig.finish() }
        let error = await #expect(throws: URLError.self) { try await rig.client.account() }
        #expect(error?.code == code)
        #expect(rig.requests.count == 1)
    }

    @Test(arguments: EndpointCase.all)
    func everyCallPassesATransportFailureOn(endpoint: EndpointCase) async throws {
        let rig = StubRig(AnswerStub.self, answer: .failure(.cannotConnectToHost))
        defer { rig.finish() }
        let error = await #expect(throws: URLError.self) { try await endpoint.call(rig.client) }
        #expect(error?.code == .cannotConnectToHost)
    }

    /// An answer that is not an HTTP one has no status to read.
    @Test func anAnswerThatIsNotHTTPIsABadServerResponse() async throws {
        let rig = StubRig(AnswerStub.self, answer: .notHTTP)
        defer { rig.finish() }
        let error = await #expect(throws: URLError.self) { try await rig.client.account() }
        #expect(error?.code == .badServerResponse)
        let dropped = await #expect(throws: URLError.self) { try await rig.client.dropConnections() }
        #expect(dropped?.code == .badServerResponse)
    }

    // MARK: Decoded values

    @Test func symbolsDecode() async throws {
        let body = #"[{"id":1,"ticker":"PTT","nameTh":"ปตท","nameEn":"PTT Public","reference":3425,"lot":100},"#
            + #"{"id":2,"ticker":"AOT","nameTh":"ท่าอากาศยาน","nameEn":"Airports","reference":6500,"lot":100}]"#
        let rig = StubRig(AnswerStub.self, answer: .json(body))
        defer { rig.finish() }
        let symbols = try await rig.client.symbols()
        #expect(symbols == [
            SymbolDTO(id: 1, ticker: "PTT", nameTh: "ปตท", nameEn: "PTT Public", reference: 3425, lot: 100),
            SymbolDTO(id: 2, ticker: "AOT", nameTh: "ท่าอากาศยาน", nameEn: "Airports", reference: 6500, lot: 100),
        ])
    }

    /// Candles come back as domain candles in the order the server sent them, the open one last; each field of the
    /// wire candle lands in its own field of the domain candle.
    @Test func candlesKeepTheOrderOfTheAnswerAndMapEveryField() async throws {
        let body = #"{"symbol":"PTT","interval":"1m","candles":["#
            + #"{"t":120000,"o":3410,"h":3420,"l":3405,"c":3415,"v":700},"#
            + #"{"t":60000,"o":3400,"h":3412,"l":3395,"c":3410,"v":500},"#
            + #"{"t":180000,"o":3415,"h":3430,"l":3411,"c":3425,"v":90}]}"#
        let rig = StubRig(AnswerStub.self, answer: .json(body))
        defer { rig.finish() }
        let candles = try await rig.client.candles(ticker: "PTT", interval: .m1, limit: 3)
        #expect(candles == [
            Candle(
                openTimeMs: 120_000, open: Price(satang: 3410), high: Price(satang: 3420), low: Price(satang: 3405),
                close: Price(satang: 3415), volume: 700
            ),
            Candle(
                openTimeMs: 60_000, open: Price(satang: 3400), high: Price(satang: 3412), low: Price(satang: 3395),
                close: Price(satang: 3410), volume: 500
            ),
            Candle(
                openTimeMs: 180_000, open: Price(satang: 3415), high: Price(satang: 3430), low: Price(satang: 3411),
                close: Price(satang: 3425), volume: 90
            ),
        ])
    }

    @Test func aPageOfTransactionsDecodesWithAndWithoutTheNextCursor() async throws {
        let entry = #"{"ledgerSeq":3,"orderId":"o-1","symbolId":1,"side":"buy","quantity":100,"price":3425,"#
            + #""commission":51,"cashDelta":-342551,"tsNs":1700000000000000000}"#
        let expected = TransactionDTO(
            ledgerSeq: 3, orderId: "o-1", symbolId: 1, side: "buy", quantity: 100, price: 3425, commission: 51,
            cashDelta: -342_551, tsNs: 1_700_000_000_000_000_000
        )
        let more = StubRig(AnswerStub.self, answer: .json(#"{"items":["# + entry + #"],"next":"3"}"#))
        defer { more.finish() }
        let first = try await more.client.transactions(cursor: nil, limit: 1)
        #expect(first == TransactionPageDTO(items: [expected], next: "3"))

        let last = StubRig(AnswerStub.self, answer: .json(#"{"items":["# + entry + "]}"))
        defer { last.finish() }
        let second = try await last.client.transactions(cursor: "3", limit: 1)
        #expect(second == TransactionPageDTO(items: [expected], next: nil))
    }

    @Test func labSettingsDecodeForBothLabCalls() async throws {
        let body = #"{"rateMultiplier":2.5,"stress":true,"extraLatencyMs":40,"jitterMs":7,"dropUpdates":true}"#
        let expected = LabSettings(
            rateMultiplier: 2.5, stress: true, extraLatencyMs: 40, jitterMs: 7, dropUpdates: true
        )
        let rig = StubRig(AnswerStub.self, answer: .json(body))
        defer { rig.finish() }
        let read = try await rig.client.lab()
        let written = try await rig.client.setLab(LabPatch(stress: true))
        #expect(read == expected)
        #expect(written == expected)
    }

    @Test func theTinyBodiesDecode() async throws {
        let time = StubRig(AnswerStub.self, answer: .json(#"{"serverNs":1700000000123456789}"#))
        defer { time.finish() }
        let serverNs = try await time.client.serverTimeNs()
        #expect(serverNs == 1_700_000_000_123_456_789)

        let reset = StubRig(AnswerStub.self, answer: .json(#"{"epoch":"6C2A5B66"}"#))
        defer { reset.finish() }
        let epoch = try await reset.client.resetServer()
        #expect(epoch == "6C2A5B66")
    }
}

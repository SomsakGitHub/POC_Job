import Contracts
import Foundation
import Testing
@testable import ExchangeServerKit

/// Query parameters and request bodies: what each route requires, how a limit is clamped, and what is refused with a
/// 400 and a `{"error":"…"}` body.
extension RestTests {
    private static let malformedQueries = [
        "/v1/candles",
        "/v1/candles?interval=1m",
        "/v1/candles?symbol=PTT",
        "/v1/candles?symbol=&interval=1m",
        "/v1/candles?symbol=PTT&interval=",
        "/v1/candles?symbol=ptt&interval=1m",
        "/v1/candles?symbol=NOPE&interval=1m",
        "/v1/candles?symbol=PTT&interval=1h",
        "/v1/candles?symbol=PTT&interval=1M",
        "/v1/candles?symbol=PTT&interval=60",
        "/v1/candles?symbol=%22%5C&interval=1m",
        "/v1/candles?symbol=PTT&interval=1m&limit=abc",
        "/v1/candles?symbol=PTT&interval=1m&limit=1.5",
        "/v1/candles?symbol=PTT&interval=1m&limit=",
        "/v1/candles?symbol=PTT&interval=1m&limit=%201",
        "/v1/candles?symbol=PTT&interval=1m&limit=1e3",
        "/v1/candles?symbol=PTT&interval=1m&limit=0x10",
        "/v1/candles?symbol=PTT&interval=1m&limit=-",
        "/v1/transactions?cursor=abc",
        "/v1/transactions?cursor=-1",
        "/v1/transactions?cursor=%2B5",
        "/v1/transactions?cursor=0x10",
        "/v1/transactions?cursor=%205",
        "/v1/transactions?cursor=5%20",
        "/v1/transactions?cursor=1.5",
        "/v1/transactions?cursor=18446744073709551616",
        "/v1/transactions?limit=abc",
        "/v1/transactions?limit=",
        "/v1/transactions?limit=2.5",
    ]

    /// Every one of these is refused with a 400. A valid request to each route answers 200 first, so a route that
    /// refused everything would fail here. One server answers them all: a refusal changes nothing.
    @Test func malformedQueriesAreRefusedWithAJsonError() async throws {
        try await withRestServer { _, client in
            for route in ["/v1/candles?symbol=PTT&interval=1m", "/v1/transactions"] {
                let valid = try await client.get(route)
                #expect(valid.status == 200, "\(route)")
            }
            for target in Self.malformedQueries {
                let response = try await client.get(target)
                let body = try? response.decode([String: String].self)
                let message = body?["error"] ?? ""
                #expect(response.status == 400, "\(target)")
                #expect(response.header("Content-Type") == "application/json; charset=utf-8", "\(target)")
                #expect(body?.keys.sorted() == ["error"], "\(target)")
                #expect(!message.isEmpty, "\(target)")
            }
        }
    }

    /// A refusal names the parameter at fault, and a parameter that is missing or empty is said to be required. It
    /// never repeats what the client sent, so nothing a client writes comes back to it in an error.
    @Test func refusalsNameTheParameterAtFaultAndNeverEchoTheInput() async throws {
        let cases: [(target: String, mentions: String)] = [
            ("/v1/candles", "symbol is required"),
            ("/v1/candles?symbol=&interval=1m", "symbol is required"),
            ("/v1/candles?symbol=PTT", "interval is required"),
            ("/v1/candles?symbol=PTT&interval=", "interval is required"),
            ("/v1/candles?symbol=ECHO9&interval=1m", "symbol"),
            ("/v1/candles?symbol=PTT&interval=ECHO9", "interval"),
            ("/v1/candles?symbol=PTT&interval=1m&limit=ECHO9", "limit"),
            ("/v1/transactions?cursor=ECHO9", "cursor"),
            ("/v1/transactions?limit=ECHO9", "limit"),
        ]
        try await withRestServer { _, client in
            for (target, mentions) in cases {
                let message = try? await client.get(target).decode(ErrorBody.self).error
                #expect(message?.contains(mentions) == true, "\(target) was answered \(message ?? "(no message)")")
                #expect(message?.contains("ECHO9") == false, "\(target) was answered \(message ?? "(no message)")")
            }
            let patch = try await client.post("/v1/admin/lab", json: #"{"stress":"ECHO9"}"#)
            let patchMessage = try? patch.decode(ErrorBody.self).error
            #expect(patchMessage?.contains("lab patch") == true, "the lab was answered \(patchMessage ?? "(none)")")
            #expect(patchMessage?.contains("ECHO9") == false, "the lab was answered \(patchMessage ?? "(none)")")
        }
    }

    @Test func candlesLimitStaysInsideItsRange() async throws {
        let cases: [(limit: String, count: Int)] = [
            ("1", 1), ("0", 1), ("-5", 1), ("-99999999999999999999", 1), ("1000", 1000), ("1001", 1000),
            ("5000", 1000), ("99999999999999999999", 1000),
        ]
        try await withRestServer { _, client in
            for (limit, count) in cases {
                let response = try await client.get("/v1/candles?symbol=PTT&interval=1s&limit=\(limit)")
                let candles = try? response.decode(CandlesResponseDTO.self)
                #expect(response.status == 200, "limit \(limit)")
                #expect(candles?.candles.count == count, "limit \(limit)")
            }
        }
    }

    @Test func candlesLimitDefaultsToOneHundred() async throws {
        try await withRestServer { _, client in
            let candles = try await client.get("/v1/candles?symbol=PTT&interval=5m").decode(CandlesResponseDTO.self)
            #expect(candles.candles.count == 100)
        }
    }

    /// A step between neighbours of exactly one interval also proves that each label picks its own interval.
    @Test func candlesAreAlignedToTheirInterval() async throws {
        try await withRestServer { _, client in
            for (label, stepMs) in [("1s", Int64(1000)), ("1m", 60_000), ("5m", 300_000)] {
                let response = try await client.get("/v1/candles?symbol=AOT&interval=\(label)&limit=20")
                let candles = try response.decode(CandlesResponseDTO.self)
                let steps = zip(candles.candles, candles.candles.dropFirst()).map { $1.t - $0.t }
                #expect(candles.symbol == "AOT", "\(label)")
                #expect(candles.interval == label)
                #expect(candles.candles.count == 20, "\(label)")
                #expect(candles.candles.allSatisfy { $0.t % stepMs == 0 }, "\(label)")
                #expect(steps == Array(repeating: stepMs, count: 19), "\(label)")
            }
        }
    }

    @Test func transactionsLimitDefaultsAndStaysInsideItsRange() async throws {
        try await withRestServer { app, client in
            try await makeLedgerEntries(app.engine, count: 205)
            let cases: [(limit: String?, count: Int)] = [
                (nil, 50), ("1", 1), ("0", 1), ("-3", 1), ("-99999999999999999999", 1), ("200", 200), ("201", 200),
                ("1000", 200), ("99999999999999999999", 200),
            ]
            for (limit, count) in cases {
                let query = limit.map { "?limit=\($0)" } ?? ""
                let page = try await client.get("/v1/transactions\(query)").decode(TransactionPageDTO.self)
                #expect(page.items.count == count, "limit \(limit ?? "(none)")")
            }
        }
    }

    /// Both a percent-encoded value and a parameter given twice are handled without a crash: the value is decoded and
    /// the first of two is used.
    @Test func percentEncodingAndRepeatedParametersAreHandled() async throws {
        try await withRestServer { _, client in
            let encoded = try await client.get("/v1/candles?symbol=%50TT&interval=%31m&limit=3")
            let encodedBody = try encoded.decode(CandlesResponseDTO.self)
            #expect(encoded.status == 200)
            #expect(encodedBody.symbol == "PTT")
            #expect(encodedBody.interval == "1m")

            let twice = "symbol=PTT&symbol=AOT&interval=1s&interval=1m&limit=3&limit=7"
            let repeated = try await client.get("/v1/candles?\(twice)")
            let repeatedBody = try repeated.decode(CandlesResponseDTO.self)
            #expect(repeated.status == 200)
            #expect(repeatedBody.symbol == "PTT")
            #expect(repeatedBody.interval == "1s")
            #expect(repeatedBody.candles.count == 3)
        }
    }

    // MARK: Lab bodies

    /// A body that is not a lab patch is a 400 with a JSON error, and the lab keeps its settings. The route takes a
    /// valid patch once the refusals are over.
    @Test func labBodiesThatAreNotPatchesAreRefusedWithAJsonError() async throws {
        let bodies = [
            "", "{", "[]", "null", "not json", #"{"stress":"yes"}"#, #"{"stress":1}"#, #"{"rateMultiplier":"fast"}"#,
            #"{"extraLatencyMs":1.5}"#, #"{"jitterMs":1e30}"#, #"{"extraLatencyMs":99999999999999999999}"#,
        ]
        try await withRestServer { _, client in
            for body in bodies {
                let response = try await client.post("/v1/admin/lab", json: body)
                let error = try? response.decode([String: String].self)
                #expect(response.status == 400, "body \(body)")
                #expect(response.header("Content-Type") == "application/json; charset=utf-8", "body \(body)")
                #expect(error?.keys.sorted() == ["error"], "body \(body)")

                let stored = try await client.get("/v1/admin/lab").decode(LabSettings.self)
                #expect(stored == LabSettings(), "body \(body)")
            }
            let valid = try await client.post("/v1/admin/lab", json: #"{"stress":true}"#)
            #expect(valid.status == 200)
        }
    }

    /// An empty object, a field this server does not know and a null all leave the settings as they are; they are
    /// valid patches that happen to change nothing.
    @Test func labPatchesThatChangeNothingAreAccepted() async throws {
        let bodies = ["{}", #"{"unknown":1}"#, #"{"stress":null}"#, #"  {"rateMultiplier":null, "other":[1,2]}  "#]
        try await withRestServer { _, client in
            for body in bodies {
                let response = try await client.post("/v1/admin/lab", json: body)
                let settings = try? response.decode(LabSettings.self)
                #expect(response.status == 200, "body \(body)")
                #expect(settings == LabSettings(), "body \(body)")
            }
        }
    }

    @Test func labPatchAnswersTheEffectiveClampedSettings() async throws {
        try await withRestServer { _, client in
            let body = #"{"rateMultiplier":100,"extraLatencyMs":999999,"jitterMs":-5,"dropUpdates":true}"#
            let response = try await client.post("/v1/admin/lab", json: body)
            let settings = try response.decode(LabSettings.self)
            #expect(response.status == 200)
            #expect(settings.rateMultiplier == 10)
            #expect(settings.extraLatencyMs == 5000)
            #expect(settings.jitterMs == 0)
            #expect(settings.dropUpdates == true)
            let stored = try await client.get("/v1/admin/lab").decode(LabSettings.self)
            #expect(stored == settings)
        }
    }
}

import Contracts
import Foundation
import Testing
import TradeCore
import TradeNetworking

/// One call of the REST API with the request it has to make and an answer that lets it succeed.
struct EndpointCase: Sendable, CustomTestStringConvertible {
    let name: String
    let answer: StubAnswer
    let call: @Sendable (URLSessionRestClient) async throws -> Void
    /// Whether the call decodes the body of the answer (`dropConnections` reads none).
    let readsBody: Bool
    let method: String
    let path: String
    /// The query as name-value pairs; empty when the request has no query at all.
    let query: [String: String]
    let cachePolicy: URLRequest.CachePolicy

    var testDescription: String { name }
}

extension EndpointCase {
    private static let account = #"{"epoch":"E1","cash":1,"positions":[],"lastEventSeq":0,"lastLedgerSeq":0}"#
    private static let lab = #"{"rateMultiplier":1,"stress":false,"extraLatencyMs":0,"jitterMs":0,"dropUpdates":false}"#

    /// A call that reads GET `path`'s answer with a cache policy that always goes to the server.
    private static func get(
        _ name: String, _ path: String, query: [String: String] = [:], answer: StubAnswer,
        cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData,
        call: @escaping @Sendable (URLSessionRestClient) async throws -> Void
    ) -> EndpointCase {
        EndpointCase(
            name: name, answer: answer, call: call, readsBody: true, method: "GET", path: path, query: query,
            cachePolicy: cachePolicy
        )
    }

    private static func post(
        _ name: String, _ path: String, answer: StubAnswer, readsBody: Bool = true,
        call: @escaping @Sendable (URLSessionRestClient) async throws -> Void
    ) -> EndpointCase {
        EndpointCase(
            name: name, answer: answer, call: call, readsBody: readsBody, method: "POST", path: path, query: [:],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    /// Every method of `RestAPI`; `transactions` appears with and without a cursor.
    static let all: [EndpointCase] = [
        // Only the symbol list keeps the default policy, so that the server's validator is used.
        get("symbols", "/v1/symbols", answer: .json("[]"), cachePolicy: .useProtocolCachePolicy) {
            _ = try await $0.symbols()
        },
        get(
            "candles", "/v1/candles", query: ["symbol": "PTT", "interval": "5m", "limit": "7"],
            answer: .json(#"{"symbol":"PTT","interval":"5m","candles":[]}"#)
        ) {
            _ = try await $0.candles(ticker: "PTT", interval: .m5, limit: 7)
        },
        get("account", "/v1/account", answer: .json(account)) {
            _ = try await $0.account()
        },
        get(
            "transactions without a cursor", "/v1/transactions", query: ["limit": "25"],
            answer: .json(#"{"items":[]}"#)
        ) {
            _ = try await $0.transactions(cursor: nil, limit: 25)
        },
        get(
            "transactions with a cursor", "/v1/transactions", query: ["limit": "25", "cursor": "42"],
            answer: .json(#"{"items":[]}"#)
        ) {
            _ = try await $0.transactions(cursor: "42", limit: 25)
        },
        get("serverTimeNs", "/v1/time", answer: .json(#"{"serverNs":5}"#)) {
            _ = try await $0.serverTimeNs()
        },
        get("lab", "/v1/admin/lab", answer: .json(lab)) {
            _ = try await $0.lab()
        },
        post("setLab", "/v1/admin/lab", answer: .json(lab)) {
            _ = try await $0.setLab(LabPatch(stress: true))
        },
        post("dropConnections", "/v1/admin/drop-connections", answer: .http(status: 204), readsBody: false) {
            try await $0.dropConnections()
        },
        post("resetServer", "/v1/admin/reset", answer: .json(#"{"epoch":"E2"}"#)) {
            _ = try await $0.resetServer()
        },
    ]
}

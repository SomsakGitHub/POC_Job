import Contracts
import ExchangeCore
import Foundation
import Hummingbird
import HummingbirdWebSocket
import TradeCore

/// The REST routes of the exchange server: reference data, the account and its history, and the lab and admin controls.
///
/// Every route is a thin read of the engine or the lab, written as JSON by `RestJSON`. A request that cannot be
/// answered is refused with a 400 and `{"error":"<message>"}`; a path or method that has no route is Hummingbird's own
/// 404.
struct RestRoutes: Sendable {
    let engine: ExchangeEngine
    let lab: LabControls
    /// The clock the engine reads, so that `GET /v1/time` and the engine's own timestamps agree.
    let nowNs: @Sendable () -> Int64
    /// What `POST /v1/admin/drop-connections` does: close every live connection a client holds to the exchange.
    let dropConnections: @Sendable () async -> Void

    func add(to router: Router<BasicWebSocketRequestContext>) {
        router.get("/healthz") { _, _ in try await health() }
        router.get("/v1/time") { _, _ in try RestJSON.response(TimeBody(serverNs: nowNs())) }
        router.get("/v1/symbols") { request, _ in try await symbols(request) }
        router.get("/v1/candles") { request, _ in try await candles(request) }
        router.get("/v1/account") { _, _ in try await RestJSON.response(AccountDTO(engine.account())) }
        router.get("/v1/transactions") { request, _ in try await transactions(request) }
        router.get("/v1/admin/lab") { _, _ in try await RestJSON.response(lab.settings()) }
        router.post("/v1/admin/lab") { request, context in try await patchLab(request, context) }
        router.post("/v1/admin/drop-connections") { _, _ in await drop() }
        router.post("/v1/admin/reset") { _, _ in try await reset() }
    }

    private func health() async throws -> Response {
        try await RestJSON.response(HealthBody(status: "ok", epoch: engine.epoch))
    }

    /// The symbol list with a validator. A client that holds the current one is answered 304 and no body.
    private func symbols(_ request: Request) async throws -> Response {
        let body = try await RestJSON.encoder.encode(engine.symbols().map(SymbolDTO.init))
        let validator = RestETag.validator(for: body)
        var headers = HTTPFields()
        headers[.eTag] = validator
        headers[.cacheControl] = "no-cache"
        if RestETag.matches(request.headers[values: .ifNoneMatch], validator: validator) {
            return Response(status: .notModified, headers: headers)
        }
        return RestJSON.response(data: body, headers: headers)
    }

    private func candles(_ request: Request) async throws -> Response {
        let ticker = try request.requiredQuery("symbol")
        let label = try request.requiredQuery("interval")
        let limit = try request.queryLimit(default: 100, in: 1...1000)
        guard let interval = CandleInterval.allCases.first(where: { $0.label == label }) else {
            throw RestError.badRequest("interval must be 1s, 1m or 5m")
        }
        guard let symbol = await engine.symbols().first(where: { $0.ticker == ticker }) else {
            throw RestError.badRequest("unknown symbol")
        }
        let candles = await engine.candles(symbolId: symbol.id, interval: interval, limit: limit)
        return try RestJSON.response(
            CandlesResponseDTO(symbol: symbol.ticker, interval: interval.label, candles: candles.map(CandleDTO.init))
        )
    }

    /// A page of the ledger, newest first. Ledger numbers run from 1 with no gap, so there are older entries exactly
    /// when the last one returned is above 1, and the page can say so without asking the engine again.
    private func transactions(_ request: Request) async throws -> Response {
        let cursor = try request.queryCursor()
        let limit = try request.queryLimit(default: 50, in: 1...200)
        let entries = await engine.transactions(before: cursor, limit: limit)
        let next = entries.last.flatMap { $0.ledgerSeq > 1 ? String($0.ledgerSeq) : nil }
        return try RestJSON.response(TransactionPageDTO(items: entries.map(TransactionDTO.init), next: next))
    }

    private func patchLab(_ request: Request, _ context: some RequestContext) async throws -> Response {
        let body = try await request.body.collect(upTo: context.maxUploadSize)
        let patch: LabPatch
        do {
            patch = try JSONDecoder().decode(LabPatch.self, from: Data(body.readableBytesView))
        } catch {
            throw RestError.badRequest("the body is not a lab patch")
        }
        return try await RestJSON.response(lab.apply(patch))
    }

    private func drop() async -> Response {
        await dropConnections()
        return Response(status: .noContent)
    }

    /// Starts a new epoch and answers it. The epoch is read after the reset, so it is the new one.
    private func reset() async throws -> Response {
        await engine.reset()
        return try await RestJSON.response(EpochBody(epoch: engine.epoch))
    }
}

private struct HealthBody: Encodable {
    let status: String
    let epoch: String
}

private struct TimeBody: Encodable {
    let serverNs: Int64
}

private struct EpochBody: Encodable {
    let epoch: String
}

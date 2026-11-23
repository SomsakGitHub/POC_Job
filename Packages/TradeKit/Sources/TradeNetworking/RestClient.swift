import Contracts
import Foundation
import TradeCore

/// Why a REST call failed after the server had answered it. A server that cannot be reached at all is not one of
/// these: that reaches the caller as the `URLError` the URL loading system threw, because "the network is down" and
/// "the server refused" are different things to a user.
public enum RestError: Error, Equatable {
    /// The server answered with a status outside 200...299. The status is the whole story: the body is not read.
    case http(status: Int)
    /// The answer was a success but its body is not what the API promises.
    case decoding
}

/// The exchange server's REST API as the clients use it. It is a protocol so that a screen's model can be run against
/// a fake in a test or a preview, without a server.
public protocol RestAPI: Sendable {
    /// Every tradable symbol, from `GET /v1/symbols`.
    func symbols() async throws -> [SymbolDTO]

    /// The candle history of one symbol and interval, from `GET /v1/candles`: ascending in time, with the candle still
    /// open last. `ticker` is the symbol's ticker ("PTT"), not its id; `limit` is how many candles to ask for, and it
    /// is sent as given: the server clamps it into its own range.
    func candles(ticker: String, interval: CandleInterval, limit: Int) async throws -> [Candle]

    /// The demo account (cash, positions and the newest sequence numbers), from `GET /v1/account`.
    func account() async throws -> AccountDTO

    /// One page of the ledger, newest first, from `GET /v1/transactions`. `cursor` is the `next` of the previous page,
    /// and nil or empty for the first page; `limit` is the page size.
    func transactions(cursor: String?, limit: Int) async throws -> TransactionPageDTO

    /// The server's clock in nanoseconds since the Unix epoch, from `GET /v1/time`: what the client's clock offset is
    /// measured against.
    func serverTimeNs() async throws -> Int64

    /// The lab's settings in force, from `GET /v1/admin/lab`.
    func lab() async throws -> LabSettings

    /// Changes the lab's settings with `POST /v1/admin/lab` and returns the settings now in force, which can differ
    /// from the patch because the server clamps a value into its range.
    func setLab(_ patch: LabPatch) async throws -> LabSettings

    /// Asks the server to close the live connections it holds to its clients, the market feed and the order event
    /// streams (`POST /v1/admin/drop-connections`), which a client must answer by reconnecting. Any success status is
    /// accepted: there is nothing in the answer to read.
    func dropConnections() async throws

    /// Starts a new epoch on the server (`POST /v1/admin/reset`): the account goes back to its starting cash and the
    /// orders and events are forgotten; the simulated market carries on. Returns the new epoch, which tells a client
    /// that the order sequence numbers it holds are no longer any good.
    func resetServer() async throws -> String
}

/// A `RestAPI` over `URLSession`, for the server that `ClientConfig` points at.
///
/// Every call is one request, built with `URLComponents` so that no value (a ticker, a cursor) can break out of its
/// place in the URL, and it never logs or prints. A status outside 200...299 is a `RestError.http`, a body that does
/// not decode is a `RestError.decoding`, and a failure of the transport is thrown as it came. The client keeps no
/// state: it can be shared between any number of tasks.
public final class URLSessionRestClient: RestAPI {
    /// How long one request may take before it fails with `URLError.timedOut`. The URL loading system's own limit is a
    /// minute, which is too long to wait to learn that the server is not there.
    private static let requestTimeout: TimeInterval = 10

    /// The cache policy of every call but the symbol list. Live data, history, the account and the admin calls must
    /// never be answered from a cache, whatever headers the server sends.
    private static let alwaysLoad = URLRequest.CachePolicy.reloadIgnoringLocalCacheData

    private let config: ClientConfig
    private let session: URLSession

    /// A client for the server `config` names. `session` is how the requests are sent; the default is the shared
    /// session, and a test passes one of its own to see or answer the requests.
    public init(config: ClientConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// `GET /v1/symbols`: the one call that is left to the session's own cache policy.
    ///
    /// The server answers the list with an ETag and `Cache-Control: no-cache`, so the session asks whether its copy is
    /// still good and, when the server says it is (a 304), hands the caller the cached body as an ordinary answer. The
    /// client keeps no ETag of its own.
    public func symbols() async throws -> [SymbolDTO] {
        let request = try makeRequest(path: "/v1/symbols", cachePolicy: .useProtocolCachePolicy)
        let body = try await send(request)
        return try decode([SymbolDTO].self, from: body)
    }

    /// `GET /v1/candles?symbol=<ticker>&interval=<1s|1m|5m>&limit=<n>`, with the wire candles turned into domain
    /// candles in the order the server sent them (ascending, the open candle last). The limit goes out as given: it is
    /// the server's to clamp.
    public func candles(ticker: String, interval: CandleInterval, limit: Int) async throws -> [Candle] {
        let query = [
            URLQueryItem(name: "symbol", value: ticker),
            URLQueryItem(name: "interval", value: interval.label),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let request = try makeRequest(path: "/v1/candles", query: query)
        let body = try await send(request)
        let answer = try decode(CandlesResponseDTO.self, from: body)
        return answer.candles.map { candle in
            Candle(
                openTimeMs: candle.t, open: Price(satang: candle.o), high: Price(satang: candle.h),
                low: Price(satang: candle.l), close: Price(satang: candle.c), volume: candle.v
            )
        }
    }

    /// `GET /v1/account`.
    public func account() async throws -> AccountDTO {
        let request = try makeRequest(path: "/v1/account")
        let body = try await send(request)
        return try decode(AccountDTO.self, from: body)
    }

    /// `GET /v1/transactions?limit=<n>`, plus `&cursor=<cursor>` when there is one. No cursor and an empty one both
    /// mean the first page, so neither sends the parameter and the server is not asked to tell them apart.
    public func transactions(cursor: String?, limit: Int) async throws -> TransactionPageDTO {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let request = try makeRequest(path: "/v1/transactions", query: query)
        let body = try await send(request)
        return try decode(TransactionPageDTO.self, from: body)
    }

    /// `GET /v1/time`: the `serverNs` of the answer.
    public func serverTimeNs() async throws -> Int64 {
        let request = try makeRequest(path: "/v1/time")
        let body = try await send(request)
        return try decode(ServerTime.self, from: body).serverNs
    }

    /// `GET /v1/admin/lab`.
    public func lab() async throws -> LabSettings {
        let request = try makeRequest(path: "/v1/admin/lab")
        let body = try await send(request)
        return try decode(LabSettings.self, from: body)
    }

    /// `POST /v1/admin/lab` with the patch as a JSON body.
    ///
    /// A field that is nil is left out of the JSON, which is how the server knows to keep that setting. A patch that
    /// cannot be written as JSON (a rate that is not a number) throws the `EncodingError` before anything is sent.
    public func setLab(_ patch: LabPatch) async throws -> LabSettings {
        var request = try makeRequest(path: "/v1/admin/lab", method: "POST")
        request.httpBody = try JSONEncoder().encode(patch)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try await send(request)
        return try decode(LabSettings.self, from: body)
    }

    /// `POST /v1/admin/drop-connections`. The server answers 204; any success status passes, and the body is not read.
    public func dropConnections() async throws {
        let request = try makeRequest(path: "/v1/admin/drop-connections", method: "POST")
        _ = try await send(request)
    }

    /// `POST /v1/admin/reset`: the `epoch` of the answer.
    public func resetServer() async throws -> String {
        let request = try makeRequest(path: "/v1/admin/reset", method: "POST")
        let body = try await send(request)
        return try decode(ResetAnswer.self, from: body).epoch
    }

    /// The request for `path` on the server: its URL with `query` (none at all when it is empty, so there is no bare
    /// "?"), its method, its timeout, its cache policy and the token header if there is a token.
    ///
    /// Values go in as `URLQueryItem`s, which percent-encode them, and never into a string. The token is a header and
    /// never a part of the URL, so it cannot end up in a log of URLs.
    private func makeRequest(
        path: String, query: [URLQueryItem] = [], method: String = "GET",
        cachePolicy: URLRequest.CachePolicy = URLSessionRestClient.alwaysLoad
    ) throws -> URLRequest {
        guard var components = URLComponents(url: config.restBase, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: Self.requestTimeout)
        request.httpMethod = method
        // An empty token is no token: a header of a bare "Bearer " would be a malformed one.
        if let token = config.authToken, !token.isEmpty {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Sends `request` and returns the body of a success. A status outside 200...299 is a `RestError.http`; an answer
    /// that is not HTTP at all has no status to read and is a bad server response. A failure of the transport is not
    /// caught: it is the caller's to see as it came.
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw RestError.http(status: http.statusCode)
        }
        return data
    }

    /// Reads `data` as a `Value`. Whatever is wrong with it, the caller is told the same thing: the body is not what
    /// the API promises, and how it is wrong is not something a caller can act on.
    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RestError.decoding
        }
    }
}

/// The body of `GET /v1/time`.
private struct ServerTime: Decodable {
    let serverNs: Int64
}

/// The body of `POST /v1/admin/reset`.
private struct ResetAnswer: Decodable {
    let epoch: String
}

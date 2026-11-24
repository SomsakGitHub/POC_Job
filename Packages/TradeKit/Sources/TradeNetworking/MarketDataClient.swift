import Contracts
import Foundation
import TradeCore

/// A live connection to the exchange's market feed that keeps a `MarketState` up to date.
///
/// The client reconnects by itself whenever the connection is lost and says how it is doing on `connection`; the
/// screen reads the market from the `MarketState` it was given, not from the client.
public protocol MarketDataClient: Sendable {
    /// A new stream of the connection's states on every access (see `ConnectionSupervisor.states`).
    var connection: AsyncStream<ConnectionState> { get }
    /// Starts connecting, and keeps a connection up until `stop()`. A `start` while running is ignored; a `start`
    /// after `stop()` connects again, with the subscriptions kept.
    func start()
    /// Closes the connection and returns once nothing of it runs any more.
    func stop() async
    /// Adds tickers to the subscriptions; they are kept across reconnects.
    func subscribe(_ tickers: [String]) async
    /// Removes tickers from the subscriptions.
    func unsubscribe(_ tickers: [String]) async
    /// Asks for a new connection now: ends a wait before the next attempt, or replaces the current connection (one
    /// that has gone quiet, say, when the app comes back to the foreground).
    func nudge()
    /// The server's clock minus this client's, in nanoseconds, as the latest pings measured it; 0 before the first.
    var clockOffsetNs: Int64 { get }
}

/// A `MarketDataClient` over a `URLSessionWebSocketTask` to the server's `/ws/market`, kept alive by a
/// `ConnectionSupervisor`.
///
/// Each connection: opens the socket (with the config's token as `Authorization: Bearer`, if there is one), starts a
/// new numbering in the `MarketState`, sends the stored subscriptions again, and measures the clock offset with 8
/// pings 50 ms apart (then one every 30 s). It is `.connected` from the first pong. Every binary frame is applied to
/// the state; each gap the state reports is answered with a resync of that symbol, at most once per symbol per
/// second. Any message counts as a sign of life, and a connection that shows none for `watchdog` is given up and
/// replaced, as is one the server closes.
public final class WebSocketMarketDataClient: MarketDataClient {
    private let feed: MarketFeed
    private let supervisor = ConnectionSupervisor(name: "market-data")

    /// A client of the server `config` names, for `symbols` (the list the server gave, used to turn the symbol ids of
    /// a gap into tickers) and feeding `state`.
    ///
    /// `latency` is the app's latency recorder. The client records nothing into it: `state` already records a sample
    /// for every frame it applies, and a second recording here would count each frame twice. It is taken so that the
    /// app hands the client and the state the same recorder in one place. `watchdog` is how long the connection may
    /// stay silent before it is replaced; the server sends a heartbeat after a second without frames. `session` makes
    /// the WebSocket tasks; a test passes one it invalidates when it is done.
    public init(
        config: ClientConfig, symbols: [SymbolDTO], state: MarketState, latency: LatencyRecorder,
        watchdog: Duration = .seconds(5), session: URLSession = .shared
    ) {
        feed = MarketFeed(config: config, symbols: symbols, state: state, watchdog: watchdog, session: session)
    }

    public var connection: AsyncStream<ConnectionState> {
        supervisor.states
    }

    public func start() {
        supervisor.start { [feed] markConnected in
            try await feed.run(markConnected: markConnected)
        }
    }

    public func stop() async {
        await supervisor.stop()
    }

    /// Adds `tickers` to the stored subscriptions, then, if a connection is open, sends them on it. With no
    /// connection open it only stores them: the next connection sends every stored ticker.
    public func subscribe(_ tickers: [String]) async {
        await feed.subscribe(tickers)
    }

    /// Removes `tickers` from the stored subscriptions, then, if a connection is open, tells the server.
    public func unsubscribe(_ tickers: [String]) async {
        await feed.unsubscribe(tickers)
    }

    public func nudge() {
        supervisor.nudge()
    }

    public var clockOffsetNs: Int64 {
        feed.clockOffsetNs
    }

    /// How many resync messages the client has sent, over all its connections (for tests).
    public var resyncCount: Int {
        feed.resyncCount
    }

    /// How long opening a connection may take before the URL loading system gives up on it.
    static let connectTimeout: TimeInterval = 10

    /// The request that opens a feed connection: `config.webSocketURL`, a 10 s timeout, and
    /// `Authorization: Bearer <token>` exactly when the config has a token that is not empty.
    static func makeRequest(config: ClientConfig) -> URLRequest {
        var request = URLRequest(url: config.webSocketURL, timeoutInterval: connectTimeout)
        if let token = config.authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

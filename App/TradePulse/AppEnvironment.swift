import Contracts
import Foundation
import Observation
import TradeCore
import TradeNetworking

/// The app's long-lived objects and the life cycle that starts and stops them.
///
/// It owns the one latency recorder, the market state, the REST API, the trading store and the frame pump, and it
/// builds the two network clients. Building an environment starts nothing: no task, no connection, no display link and
/// no wait, so it does no harm to build one more than once, and a unit-test host that builds one stays quiet.
/// Everything starts in `bootstrap()`, once the server has given its symbol list.
@MainActor @Observable
final class AppEnvironment {
    /// Makes the market client for the symbols the server listed. The arguments are the config, the symbols, the market
    /// state the client feeds and the latency recorder the whole app shares.
    typealias MarketClientFactory = (ClientConfig, [SymbolDTO], MarketState, LatencyRecorder) -> any MarketDataClient
    /// Makes the trading client. The arguments are the config and the latency recorder the whole app shares.
    typealias TradingClientFactory = (ClientConfig, LatencyRecorder) -> any TradingClient

    /// Where the environment is in its life.
    private enum Phase {
        /// Not started, or a start that was cancelled before anything was built.
        case idle
        /// Waiting for the symbol list.
        case loading
        /// The clients are started or being started.
        case running
        /// Over for good: the clients were stopped and nothing starts again.
        case shutDown
    }

    /// Where the server is and how to identify the app to it.
    let config: ClientConfig
    /// The one latency recorder of the app: the market state, the clients and the store all record into it.
    let latency: LatencyRecorder
    /// The prices, as the market feed last gave them.
    let marketState: MarketState
    /// The server's REST API.
    let rest: any RestAPI
    /// The orders, the ledger and the positions.
    let trading: TradingStore
    /// The frame clock that tells the views when the market has something new to show.
    let pump: FramePump
    /// A line about a configured server address that could not be used, shown for the whole run; nil when the address
    /// in use is the configured one.
    let configNotice: String?

    /// The symbols the server lists, in its order; empty until the first list has loaded.
    private(set) var symbols: [SymbolDTO] = []
    /// The state of the market feed. While the symbol list cannot be loaded it counts the failed attempts, and from the
    /// moment the market client exists it is whatever that client reports.
    private(set) var marketConnection: ConnectionState = .connecting
    /// The state of the order stream, kept like `marketConnection` until the trading client has started.
    private(set) var tradingConnection: ConnectionState = .connecting

    /// The order service client. The store uses it too, but only its owner starts, nudges and stops it.
    @ObservationIgnored private let tradingClient: any TradingClient
    /// Builds the market client once the symbols are known.
    @ObservationIgnored private let makeMarketClient: MarketClientFactory
    /// How the environment waits between two attempts to load the symbols.
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// A random number in 0...1 that spreads out the waits between attempts.
    @ObservationIgnored private let jitter: @Sendable () -> Double
    /// Where the environment is in its life.
    @ObservationIgnored private var phase = Phase.idle
    /// The market client; nil until the symbols are known.
    @ObservationIgnored private var marketClient: (any MarketDataClient)?
    /// The task that builds and starts the clients, which no cancellation of a caller may interrupt.
    @ObservationIgnored private var startUp: Task<Void, Never>?
    /// The tasks that copy the connection states of the clients into the properties above.
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    /// Whether the app has been in the background since it was last active.
    @ObservationIgnored private var wasInBackground = false

    /// An environment for the server `config` names. `rest` stands in for the real REST API, `makeMarketClient` and
    /// `makeTradingClient` for the real clients, and `sleep` and `jitter` for the wait between two attempts to load the
    /// symbols, so that a test can run without a network and without waiting.
    init(
        config: ClientConfig = .fromEnvironment(),
        rest: (any RestAPI)? = nil,
        makeMarketClient: @escaping MarketClientFactory = {
            WebSocketMarketDataClient(config: $0, symbols: $1, state: $2, latency: $3)
        },
        makeTradingClient: @escaping TradingClientFactory = { GRPCTradingClient(config: $0, latency: $1) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        jitter: @escaping @Sendable () -> Double = { .random(in: 0...1) }
    ) {
        let latency = LatencyRecorder()
        let marketState = MarketState(latency: latency)
        let rest = rest ?? URLSessionRestClient(config: config)
        let tradingClient = makeTradingClient(config, latency)
        self.config = config
        self.latency = latency
        self.marketState = marketState
        self.rest = rest
        self.tradingClient = tradingClient
        trading = TradingStore(client: tradingClient, rest: rest, latency: latency)
        pump = FramePump(marketState: marketState)
        configNotice = Self.configNotice(for: config)
        self.makeMarketClient = makeMarketClient
        self.sleep = sleep
        self.jitter = jitter
    }

    // MARK: Starting

    /// Loads the symbol list, asking again after every failure until the server gives a list that is not empty, then
    /// starts the market feed for all of them and the trading store. While the list cannot be loaded both connection
    /// states read `.reconnecting` with the number of attempts that failed.
    ///
    /// A call returns at once when the environment has started or is starting (the call that is running does the job),
    /// and after `shutdown()`. A call that is cancelled while it waits for the list leaves and starts nothing, and puts
    /// the environment back where it was, so that a later call begins again. Once the list is there the start-up
    /// itself is not interrupted by a cancellation: a market client that was started with no trading behind it could
    /// not be put right by a later call.
    func bootstrap() async {
        guard phase == .idle else { return }
        phase = .loading
        let list = await loadSymbols()
        guard let list, phase == .loading, !Task.isCancelled else {
            if phase == .loading { phase = .idle }
            return
        }
        phase = .running
        let startUp = Task { await start(with: list) }
        self.startUp = startUp
        await startUp.value
    }

    /// The server's symbols, asked for again after every failure; nil when the caller was cancelled, a wait failed or
    /// the environment was shut down in the meantime.
    private func loadSymbols() async -> [SymbolDTO]? {
        var failures = 0
        while phase == .loading {
            do {
                let list = try await rest.symbols()
                if !list.isEmpty { return list }
            } catch is CancellationError {
                return nil
            } catch {
                // A request that ends because its task was cancelled reports a URL error, not a `CancellationError`.
                if Task.isCancelled { return nil }
            }
            failures = failures < Int.max ? failures + 1 : failures
            marketConnection = .reconnecting(attempt: failures)
            tradingConnection = .reconnecting(attempt: failures)
            do {
                try await sleep(ReconnectBackoff().delay(attempt: failures - 1, jitter: jitter()))
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Builds and starts the clients for `list`. Nothing in it throws or returns early.
    private func start(with list: [SymbolDTO]) async {
        symbols = list
        let client = makeMarketClient(config, list, marketState, latency)
        marketClient = client
        // The stream is made before the start: a supervised client says nothing until it starts, and then its first
        // state is what this observer sees first. With no connection open `subscribe` only stores the tickers, and the
        // first connection sends all of them.
        observe(client.connection) { [weak self] in self?.marketConnection = $0 }
        await client.subscribe(list.map(\.ticker))
        client.start()
        await trading.start()
        // The stream is made after the start: a new stream says the current state first, and one made before the start
        // would be dead for a client that was stopped earlier.
        observe(tradingClient.connection) { [weak self] in self?.tradingConnection = $0 }
    }

    /// Copies every state of `states` to `publish` until the stream ends or the environment is shut down.
    private func observe(
        _ states: AsyncStream<ConnectionState>, publish: @escaping @MainActor (ConnectionState) -> Void
    ) {
        observers.append(
            Task {
                for await state in states { publish(state) }
            })
    }

    // MARK: Life cycle

    /// The app became active: the display link runs. When the app comes back from the background the clients are told
    /// to replace their connections, because the system may have cut or suspended them while the app was away. A
    /// short trip through inactive (Control Center, the notification shade) never left the foreground and nudges
    /// nothing: a nudge replaces a healthy connection and cuts a call that is in flight.
    func appDidBecomeActive() {
        guard phase != .shutDown else { return }
        pump.start()
        guard wasInBackground else { return }
        wasInBackground = false
        guard phase == .running else { return }
        marketClient?.nudge()
        tradingClient.nudge()
    }

    /// The app left the foreground: the display link stops, and the connections are left to the system.
    func appDidEnterBackground() {
        guard phase != .shutDown else { return }
        pump.stop()
        wasInBackground = true
    }

    /// Ends the environment's life: stops the observers, the pump and both clients, and starts nothing again. A
    /// start-up that is under way finishes first, so that what it started is stopped. The environment is not used again
    /// afterwards.
    func shutdown() async {
        guard phase != .shutDown else { return }
        phase = .shutDown
        await startUp?.value
        for observer in observers { observer.cancel() }
        observers = []
        pump.stop()
        await marketClient?.stop()
        await tradingClient.stop()
    }

    // MARK: Configuration

    /// One line about the server address when the config could not be used as it was written, or nil when it could.
    ///
    /// `ClientConfig` falls back to its default address for a host or port that makes no URL, so a mistyped host
    /// would otherwise talk to the local server without a word. The address in use is the one in `restBase`; it is
    /// the configured one when its host (read as the URL does, without the brackets of an IPv6 address, and in either
    /// case) and its port are the configured ones.
    nonisolated static func configNotice(for config: ClientConfig) -> String? {
        let base = config.restBase
        var host = config.host
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if base.host?.lowercased() == host.lowercased(), base.port == config.restPort {
            return nil
        }
        let address = "\(base.host ?? "an unknown host"):\(base.port.map(String.init) ?? "an unknown port")"
        return "The server address in the configuration cannot be used, so the app talks to \(address)."
    }
}

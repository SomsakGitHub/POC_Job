import Contracts
import Synchronization
import TradeCore
import TradeNetworking
@testable import TradePulse

/// What the environment handed its client factories, so that a test can check that it passed the pieces it owns.
final class Builds: Sendable {
    /// The arguments of one call of the market client factory.
    struct Market: Sendable {
        /// The config the client was built for.
        let config: ClientConfig
        /// The symbols it was built for.
        let symbols: [SymbolDTO]
        /// The market state it feeds.
        let state: MarketState
        /// The latency recorder it records into.
        let latency: LatencyRecorder
    }

    /// The arguments of one call of the trading client factory.
    struct Trading: Sendable {
        /// The config the client was built for.
        let config: ClientConfig
        /// The latency recorder it records into.
        let latency: LatencyRecorder
    }

    /// Every call of each factory, in order.
    private let shared = Mutex<(market: [Market], trading: [Trading])>(([], []))

    /// Notes a call of the market client factory.
    func record(_ market: Market) {
        shared.withLock { $0.market.append(market) }
    }

    /// Notes a call of the trading client factory.
    func record(_ trading: Trading) {
        shared.withLock { $0.trading.append(trading) }
    }

    /// The calls of the market client factory, in order.
    var market: [Market] { shared.withLock { $0.market } }
    /// The calls of the trading client factory, in order.
    var trading: [Trading] { shared.withLock { $0.trading } }
}

/// An environment over fakes: a REST API that answers from a script, one market client and one trading client that
/// record what they are asked, and a sleep that returns, waits or fails as the test chose. The factories hand out
/// the one fake client of each kind, so a client built twice shows as a second start.
@MainActor
struct EnvRig {
    /// The calls both fake clients received, in order.
    let log = EventLog()
    /// What the environment handed the client factories.
    let builds = Builds()
    /// The REST API the environment loads the symbols from.
    let rest: FakeRest
    /// The sleep the environment waits between attempts with.
    let sleeper: FakeSleeper
    /// The market client the environment builds.
    let market: FakeMarketClient
    /// The trading client the environment builds and the store uses.
    let tradingClient: FakeTradingClient
    /// The environment under test.
    let env: AppEnvironment

    /// An environment over fakes. `holdsSubscribe` makes the market client keep its first subscribe until it is
    /// released, `tradingStartsAs` is the state the trading client reports once its event stream starts, and
    /// `tradingSubmits` are the answers of its first calls of `submit`.
    init(
        rest: FakeRest = FakeRest(), sleeper: FakeSleeper = FakeSleeper(), config: ClientConfig = ClientConfig(),
        holdsSubscribe: Bool = false, tradingStartsAs: ConnectionState = .connecting,
        tradingSubmits: [FakeTradingClient.SubmitAnswer] = []
    ) {
        let log = log
        let builds = builds
        let market = FakeMarketClient(log: log, holdsSubscribe: holdsSubscribe)
        let tradingClient = FakeTradingClient(log: log, startsAs: tradingStartsAs, submits: tradingSubmits)
        self.rest = rest
        self.sleeper = sleeper
        self.market = market
        self.tradingClient = tradingClient
        env = AppEnvironment(
            config: config,
            rest: rest,
            makeMarketClient: { config, symbols, state, latency in
                builds.record(Builds.Market(config: config, symbols: symbols, state: state, latency: latency))
                return market
            },
            makeTradingClient: { config, latency in
                builds.record(Builds.Trading(config: config, latency: latency))
                return tradingClient
            },
            sleep: { try await sleeper.sleep($0) },
            jitter: { 1.0 }
        )
    }

    /// A task that runs `bootstrap()`, and the flag it sets when that call has returned.
    func bootstrapInTask() -> (task: Task<Void, Never>, finished: Flag) {
        let env = env
        let finished = Flag()
        let task = Task { @MainActor in
            await env.bootstrap()
            finished.set()
        }
        return (task, finished)
    }
}

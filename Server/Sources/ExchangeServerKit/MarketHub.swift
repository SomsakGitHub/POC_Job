import Contracts
import ExchangeCore
import TradeCore

/// Identifies one connection registered with a `MarketHub`.
public typealias ConnectionID = UInt64

/// The market feed's switchboard: it keeps the latest quote of every symbol and, for every connection, what it
/// subscribes to and what is waiting to be sent to it.
///
/// The hub never waits for a connection. Each connection has its own flusher task that takes its next frame from the
/// hub (a short call) and awaits `send` outside the hub, so a slow or stalled socket delays nothing but itself:
/// `publish`, `subscribe` and every other connection go on, and the slow one is sent the newest state when it is ready
/// (one waiting quote per symbol, latest wins). Frames of one connection are at least 5 ms apart; a connection that has
/// been sent nothing for a second gets an empty frame as a heartbeat; the lab's latency, jitter and dropped updates
/// apply to every frame.
///
/// A connection ends when it is unregistered, when `dropAll` runs or when a `send` throws, whichever comes first; its
/// `close` is called exactly once then, and its flusher stops.
public actor MarketHub {
    private struct Connection {
        var feed = ConnectionFeed()
        let close: @Sendable () async -> Void
        let wake: AsyncStream<Void>.Continuation
        let flusher: Task<Void, Never>
    }

    private let symbolIds: [String: UInt32]
    private let lab: LabControls
    private let nowNs: @Sendable () -> Int64
    private let idleTimeout: Duration
    private var latest: [UInt32: SymbolQuote] = [:]
    private var connections: [ConnectionID: Connection] = [:]
    private var nextId: ConnectionID = 1

    /// A hub serving `symbols`, applying `lab`'s feed settings, and stamping every frame with `nowNs` (nanoseconds
    /// since the Unix epoch, the clock clients compare their receipt time with).
    public init(symbols: [SymbolInfo], lab: LabControls, nowNs: @escaping @Sendable () -> Int64 = { WallClock.nowNs() }) {
        self.init(symbols: symbols, lab: lab, nowNs: nowNs, idleTimeout: MarketFlusher.idleTimeout)
    }

    /// A hub whose connections get a heartbeat after `idleTimeout` of silence instead of a second, so that a test can
    /// tell a frame that was sent at once from one that waited for the heartbeat however slowly the test runs.
    init(symbols: [SymbolInfo], lab: LabControls, nowNs: @escaping @Sendable () -> Int64, idleTimeout: Duration) {
        symbolIds = Dictionary(symbols.map { ($0.ticker, $0.id) }, uniquingKeysWith: { first, _ in first })
        self.lab = lab
        self.nowNs = nowNs
        self.idleTimeout = idleTimeout
    }

    /// Registers a connection and starts its flusher. `send` delivers one frame and throws if the connection is gone
    /// (which ends it); `close` closes the connection and is called exactly once, when the connection ends for any
    /// reason. The connection subscribes to nothing yet; it gets a heartbeat after a second of silence.
    public func register(
        send: @escaping @Sendable (Tp_MarketFrame) async throws -> Void, close: @escaping @Sendable () async -> Void
    ) -> ConnectionID {
        let id = nextId
        nextId += 1
        let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let flusher = MarketFlusher(hub: self, id: id, lab: lab, idleTimeout: idleTimeout, send: send, wake: wake)
        let task = Task { await flusher.run(wakes: wakes) }
        connections[id] = Connection(close: close, wake: wake, flusher: task)
        return id
    }

    /// Ends a connection: stops its flusher and calls its `close`. An unknown or already ended id is ignored, so it is
    /// safe to call whenever a connection's handler finishes, whatever ended it.
    public func unregister(_ id: ConnectionID) {
        guard let close = remove(id) else { return }
        Task { await close() }
    }

    /// Subscribes the connection to every known ticker in `tickers` and queues each one's current full state, so the
    /// client has the whole picture at once; subscribing to a ticker again re-sends its state. Returns the tickers that
    /// name no symbol, in request order.
    public func subscribe(_ id: ConnectionID, tickers: [String]) -> [String] {
        var unknown: [String] = []
        for ticker in tickers {
            guard let symbolId = symbolIds[ticker] else {
                unknown.append(ticker)
                continue
            }
            connections[id]?.feed.subscribe(symbolId, current: latest[symbolId])
        }
        connections[id]?.wake.yield()
        return unknown
    }

    /// Ends the connection's subscription to each ticker and forgets its waiting quote. Unknown tickers are ignored.
    public func unsubscribe(_ id: ConnectionID, tickers: [String]) {
        for ticker in tickers {
            guard let symbolId = symbolIds[ticker] else { continue }
            connections[id]?.feed.unsubscribe(symbolId)
        }
    }

    /// Queues the current full state of `ticker` for the connection, subscribed or not, so that a client that saw a
    /// gap in `seq` can start again from a whole state. Returns false for an unknown ticker.
    public func resync(_ id: ConnectionID, ticker: String) -> Bool {
        guard let symbolId = symbolIds[ticker] else { return false }
        if let current = latest[symbolId] {
            connections[id]?.feed.resync(current)
            connections[id]?.wake.yield()
        }
        return true
    }

    /// Keeps each quote as its symbol's latest (whether or not anyone subscribes to it, so a later subscriber gets it)
    /// and queues it on every connection subscribed to that symbol, replacing what was waiting there.
    public func publish(_ quotes: [SymbolQuote]) {
        for quote in quotes { latest[quote.symbolId] = quote }
        for id in Array(connections.keys) {
            var queued = false
            for quote in quotes where connections[id]?.feed.offer(quote) == true { queued = true }
            if queued { connections[id]?.wake.yield() }
        }
    }

    /// Ends every connection: calls each one's `close` exactly once, stops their flushers and empties the registry.
    /// The hub itself keeps running and takes new connections.
    public func dropAll() async {
        let ended = Array(connections.keys).compactMap { remove($0) }
        for close in ended { await close() }
    }

    /// The largest number of quotes waiting on any one connection: at most one per subscribed symbol, however fast the
    /// quotes come and however slow the connection is.
    public func maxPendingCount() -> Int {
        connections.values.map(\.feed.pendingCount).max() ?? 0
    }

    /// How many connections are registered.
    func connectionCount() -> Int {
        connections.count
    }

    /// Whether a quote is waiting for the connection; nil once the connection has ended.
    func hasPending(_ id: ConnectionID) -> Bool? {
        connections[id]?.feed.hasPending
    }

    /// The connection's next frame, stamped now, or `.nothing` when there is nothing to send yet; `.ended` once the
    /// connection has ended.
    func takeFrame(_ id: ConnectionID, dropUpdates: Bool, heartbeatDue: Bool) -> FlushStep {
        guard connections[id] != nil else { return .ended }
        let frame = connections[id]?.feed.takeFrame(
            serverSendNs: nowNs(), dropUpdates: dropUpdates, heartbeatDue: heartbeatDue
        )
        return frame.map { .frame($0) } ?? .nothing
    }

    /// Ends a connection whose `send` failed. Does nothing if something else ended it first.
    func sendFailed(_ id: ConnectionID) async {
        guard let close = remove(id) else { return }
        await close()
    }

    /// Takes the connection out of the registry and stops its flusher; returns its `close`, which the caller must call,
    /// or nil if the connection had already ended. Being removed here is what makes `close` happen only once.
    private func remove(_ id: ConnectionID) -> (@Sendable () async -> Void)? {
        guard let connection = connections.removeValue(forKey: id) else { return nil }
        connection.wake.finish()
        connection.flusher.cancel()
        return connection.close
    }
}

/// What a flusher gets when it asks the hub for the next frame.
enum FlushStep: Sendable {
    /// Send this frame.
    case frame(Tp_MarketFrame)
    /// Nothing to send now.
    case nothing
    /// The connection has ended: stop.
    case ended
}

import Contracts
import Foundation
import Synchronization
import TradeCore

/// What the market-data client keeps between connections, and one connection's run.
///
/// The stored subscriptions, the open task (if any), the latest clock offset and the resync count sit behind one
/// lock, which is never held across an `await`. Everything that belongs to one connection (its socket, its clock
/// estimator, its resync limits, its activity) lives in that connection's run and goes with it.
final class MarketFeed: Sendable {
    private struct Shared {
        var subscriptions: Set<String> = []
        /// The task of the open connection, from the moment its run publishes it until the run ends.
        var task: URLSessionWebSocketTask?
        var clockOffsetNs: Int64 = 0
        var resyncCount = 0
    }

    /// Thrown by the watchdog when the connection has been silent too long.
    private struct Silent: Error {}

    private let config: ClientConfig
    private let state: MarketState
    private let watchdog: Duration
    private let session: URLSession
    /// The resync message of every symbol id, made once, so that answering a gap costs no encoding.
    private let resyncMessages: [UInt32: String]
    private let shared = Mutex(Shared())

    init(config: ClientConfig, symbols: [SymbolDTO], state: MarketState, watchdog: Duration, session: URLSession) {
        self.config = config
        self.state = state
        self.watchdog = watchdog
        self.session = session
        resyncMessages = Dictionary(
            symbols.map { ($0.id, FeedControl.resync($0.ticker)) }, uniquingKeysWith: { first, _ in first }
        )
    }

    var clockOffsetNs: Int64 { shared.withLock { $0.clockOffsetNs } }
    var resyncCount: Int { shared.withLock { $0.resyncCount } }

    /// Stores `tickers` first and then sends them on the open connection, if there is one. A connection that opens
    /// meanwhile sends the stored set once it is published, so the tickers reach the server either way (twice at
    /// worst, which only makes the server send their state again).
    func subscribe(_ tickers: [String]) async {
        guard !tickers.isEmpty else { return }
        let task = shared.withLock { shared in
            shared.subscriptions.formUnion(tickers)
            return shared.task
        }
        // A failed send means the connection is going down; its replacement sends the stored set.
        try? await task?.send(.string(FeedControl.subscribe(tickers)))
    }

    /// Removes `tickers` from the stored set and then tells the open connection, if there is one.
    func unsubscribe(_ tickers: [String]) async {
        guard !tickers.isEmpty else { return }
        let task = shared.withLock { shared in
            shared.subscriptions.subtract(tickers)
            return shared.task
        }
        try? await task?.send(.string(FeedControl.unsubscribe(tickers)))
    }

    /// One connection, from opening the socket until it is lost, silent or cancelled.
    ///
    /// Three children run side by side: the receive loop, the sender (the subscriptions, then the pings) and the
    /// watchdog. The first to end, by returning or throwing, ends the connection: the others are cancelled and the
    /// socket is cancelled with them. `URLSessionWebSocketTask.receive()` does not notice the cancellation of the
    /// Swift task awaiting it, so the socket itself is cancelled, both when a child ends and from the cancellation
    /// handler when the whole run is cancelled (by a nudge or `stop()`); that is what lets a run on a silent socket
    /// end at once. The run returns only once every child has ended.
    func run(markConnected: @Sendable () -> Void) async throws {
        let task = session.webSocketTask(with: WebSocketMarketDataClient.makeRequest(config: config))
        let activity = Activity()
        // The new connection numbers every symbol's updates from 1 again; nothing of it has been received yet.
        state.beginConnection()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            shared.withLock { shared in
                if shared.task === task { shared.task = nil }
            }
        }
        try await withTaskCancellationHandler {
            task.resume()
            activity.touch()
            try await withoutActuallyEscaping(markConnected) { markConnected in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    defer { task.cancel(with: .goingAway, reason: nil) }
                    group.addTask { try await self.receive(on: task, activity: activity, markConnected: markConnected) }
                    group.addTask { try await self.send(on: task) }
                    group.addTask { try await self.watch(activity) }
                    try await group.next()
                    group.cancelAll()
                }
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    /// Publishes `task` as the open connection, sends the stored subscriptions in one message, then pings on the
    /// `PingSchedule` for as long as the connection lives.
    private func send(on task: URLSessionWebSocketTask) async throws {
        let tickers = shared.withLock { shared in
            shared.task = task
            return shared.subscriptions.sorted()
        }
        if !tickers.isEmpty {
            try await task.send(.string(FeedControl.subscribe(tickers)))
        }
        var ping = 0
        while true {
            try await Task.sleep(for: PingSchedule.delay(before: ping))
            try await task.send(.string(FeedControl.ping(clientNs: WallClock.nowNs())))
            ping += 1
        }
    }

    /// Reads messages until the socket fails or is cancelled. Every message is a sign of life. A binary one is a
    /// market frame, applied to the state, with a resync for each gap the limiter lets through; a pong adds a sample
    /// to this connection's clock estimator and the first one proves the connection; anything else is ignored.
    private func receive(
        on task: URLSessionWebSocketTask, activity: Activity, markConnected: @Sendable () -> Void
    ) async throws {
        var estimator = ClockOffsetEstimator()
        var limiter = ResyncLimiter()
        var connected = false
        while true {
            let message = try await task.receive()
            // Read before anything is done with the message: the latency of a frame is the time until it arrived.
            let receivedAtNs = WallClock.nowNs()
            activity.touch()
            switch message {
            case .data(let data):
                // A frame that does not decode is skipped; the next one carries the newest state anyway.
                guard let frame = try? Tp_MarketFrame(serializedBytes: data) else { continue }
                let gaps = state.apply(frame: frame, receivedAtNs: receivedAtNs)
                for symbolId in gaps {
                    guard let resync = resyncMessages[symbolId], limiter.admit(symbolId, at: .now) else { continue }
                    try await task.send(.string(resync))
                    shared.withLock { $0.resyncCount += 1 }
                }
            case .string(let text):
                guard case .pong(let clientNs, let serverNs) = FeedReply(text: text) else { continue }
                // The send time is the one the server echoed, so a pong is matched with its own ping.
                estimator.add(clientSendNs: clientNs, serverNs: serverNs, clientRecvNs: receivedAtNs)
                let offset = estimator.offsetNs
                state.setClockOffset(offset)
                shared.withLock { $0.clockOffsetNs = offset }
                if !connected {
                    connected = true
                    markConnected()
                }
            @unknown default:
                continue
            }
        }
    }

    /// Throws `Silent` once `watchdog` has passed since the last sign of life (the socket's start or any message).
    private func watch(_ activity: Activity) async throws {
        while true {
            let deadline = activity.last + watchdog
            if deadline <= ContinuousClock.now { throw Silent() }
            try await Task.sleep(until: deadline, clock: .continuous)
        }
    }
}

/// The moment of a connection's last sign of life, on the monotonic clock, which a change of the wall clock cannot
/// move.
private final class Activity: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    /// Records a sign of life now.
    func touch() {
        let now = ContinuousClock.now
        instant.withLock { $0 = now }
    }

    var last: ContinuousClock.Instant {
        instant.withLock { $0 }
    }
}

import Contracts
import Synchronization
import TradeCore

/// The market as this client sees it: the newest snapshot of every symbol, built from the frames of the market feed,
/// and the latency of those frames.
///
/// The task that reads the feed calls `apply(frame:receivedAtNs:)` for every frame, and the screen reads
/// `snapshot(_:)`, `version` and `isFresh(nowNs:maxAgeNs:)` from wherever it likes. All of the state is one value
/// behind one lock, so every call is atomic: a reader never sees half of an update, and a snapshot it was handed is a
/// copy that later frames do not touch.
///
/// Lock order: there is none to get wrong, because the lock is never held while anything else is called. A call takes
/// the state's lock, changes the state, releases the lock, and only then reads the injected clock and records into the
/// `LatencyRecorder`, which has a lock of its own. The two locks are never nested, and a clock that reads this state
/// again (a test's does) cannot deadlock.
public final class MarketState: Sendable {
    private let storage = Mutex(MarketStateStorage())
    private let latency: LatencyRecorder
    private let clock: @Sendable () -> Int64

    /// A market state that records its latency samples into `latency`.
    ///
    /// `nowNs` is the client's clock, read once per applied frame for the "applied" sample. It is a parameter so that a
    /// test can say what the clock reads; the default is the wall clock, the one the server stamps its frames with.
    public init(latency: LatencyRecorder, nowNs: @escaping @Sendable () -> Int64 = WallClock.nowNs) {
        self.latency = latency
        self.clock = nowNs
    }

    /// Sets the difference between the server's clock and this client's: `serverNs - clientNs`, in nanoseconds (0 until
    /// it is set).
    ///
    /// The server stamps a frame with its own clock, so a latency is only the difference of two timestamps once the
    /// client's clock is moved onto the server's: every sample is `(client time + offset) - server time`. The offset is
    /// measured against the server's `/v1/time`; it can be set again at any time and each sample uses the one in force
    /// when it is taken.
    public func setClockOffset(_ ns: Int64) {
        storage.withLock { $0.clockOffsetNs = ns }
    }

    /// Starts a new connection to the feed.
    ///
    /// The server numbers the updates of every symbol from 1 on each connection, so the numbers of the last connection
    /// say nothing about this one: they are forgotten, as are the gap counts, and the first update of each symbol is a
    /// baseline (applied, neither stale nor a gap). The snapshots stay, so the last prices can be shown until the
    /// first updates of the new connection replace them. The version does not change, because nothing visible does.
    public func beginConnection() {
        storage.withLock { $0.beginConnection() }
    }

    /// Applies the updates of one frame and returns the symbols whose sequence numbers jumped.
    ///
    /// An update at or below the symbol's last number is stale (a repeat) and is ignored. An update more than one above
    /// it is applied all the same and becomes the new baseline, but its symbol is returned and counted in
    /// `SymbolSnapshot.gapCount`: updates are missing, and the caller can fetch the state again to fill the hole. Each
    /// symbol is returned at most once per call, in the order of the frame; the result is empty, and costs no
    /// allocation, when nothing jumped.
    ///
    /// Every frame, a heartbeat with no updates included, counts as proof that the feed is alive (`lastFrameAtNs`).
    /// A frame that applied nothing (a heartbeat, or one whose updates were all stale) changes no snapshot, leaves
    /// `version` alone and records no latency. A frame that applied at least one update bumps `version` once, however
    /// many updates it carried, and, if it is stamped (`serverSendNs > 0`), records one `tickToApp` and one
    /// `tickToApplied` sample: once per frame and not once per update, because one frame is one network event. The
    /// raw sample goes to the recorder, which clamps it and counts it as clamped: a client clock that is wrong by
    /// seconds shows up as clamped samples and never as a negative percentile.
    public func apply(frame: Tp_MarketFrame, receivedAtNs: Int64) -> [UInt32] {
        let serverSendNs = frame.serverSendNs
        let result = storage.withLock {
            $0.apply(updates: frame.updates, serverSendNs: serverSendNs, receivedAtNs: receivedAtNs)
        }
        guard result.applied > 0, serverSendNs > 0 else { return result.gaps }
        // The clock is read after the updates are in the state and outside the lock, so the sample covers the time
        // taken to apply them and a clock that looks at this state again does not deadlock.
        let appliedAtNs = clock()
        let offsetNs = result.offsetNs
        latency.record(
            .tickToApp, nanos: Self.sample(clientNs: receivedAtNs, offsetNs: offsetNs, serverSendNs: serverSendNs)
        )
        latency.record(
            .tickToApplied, nanos: Self.sample(clientNs: appliedAtNs, offsetNs: offsetNs, serverSendNs: serverSendNs)
        )
        return result.gaps
    }

    /// The newest snapshot of `symbolId`, or nil if the feed has not mentioned it since the start or the last
    /// `reset()`. It is a copy: it does not change when later updates arrive.
    public func snapshot(_ symbolId: UInt32) -> SymbolSnapshot? {
        storage.withLock { $0.entries[symbolId]?.snapshot }
    }

    /// Tells the state that the screen has just drawn what was applied, at `atNs` on the client's clock.
    ///
    /// It records `tickToRender`: the time from the server stamping the oldest applied frame that was not drawn yet to
    /// this moment. The oldest is the one measured because it has waited longest and one draw shows all of them. Then
    /// it forgets the stamp, so a draw with nothing new to show records nothing and a frame is measured once.
    public func markRendered(atNs: Int64) {
        let (stamp, offsetNs) = storage.withLock { $0.takePendingRenderStamp() }
        guard let stamp else { return }
        latency.record(.tickToRender, nanos: Self.sample(clientNs: atNs, offsetNs: offsetNs, serverSendNs: stamp))
    }

    /// Forgets the stamp of the frames applied since the last draw, without recording anything, for a screen that was
    /// not drawing while they arrived. The next `markRendered` then measures only frames applied after this call.
    /// The snapshots and the version are left as they are, so the new prices are still shown.
    public func discardPendingRender() {
        storage.withLock { _ = $0.takePendingRenderStamp() }
    }

    /// A number that goes up by one for every `apply` that changed a snapshot, however many updates it carried, and
    /// for every `reset()`. It never goes back, so a screen that remembers the version it drew can tell with one
    /// comparison whether there is anything new.
    public var version: UInt64 {
        storage.withLock { $0.version }
    }

    /// When the newest frame was received, in client wall-clock nanoseconds; 0 if none has been since the start or the
    /// last `reset()`. Heartbeats count, because they are how a quiet market is told from a dead connection.
    public var lastFrameAtNs: Int64 {
        storage.withLock { $0.lastFrameAtNs ?? 0 }
    }

    /// Whether the feed is alive: a frame has been received and the newest is at most `maxAgeNs` old at `nowNs`.
    ///
    /// False until the first frame, however generous the limit, because nothing says the feed works yet. A `nowNs`
    /// before the last frame (the clock stepped back) counts as an age of 0.
    public func isFresh(nowNs: Int64, maxAgeNs: Int64) -> Bool {
        storage.withLock { $0.isFresh(nowNs: nowNs, maxAgeNs: maxAgeNs) }
    }

    /// Forgets the market: the snapshots, the sequence numbers, the time of the last frame and any frame waiting to be
    /// drawn, so that what comes next starts from nothing, as it did at launch. A screen that would rather show "no
    /// data" than the last prices calls it. The version goes up, so a screen that watches it redraws; the clock offset
    /// and the recorder, which are not market data, are left alone.
    public func reset() {
        storage.withLock { $0.reset() }
    }

    /// One latency sample: `(clientNs + offsetNs) - serverSendNs`.
    ///
    /// The sum is worked out in `Int128`, so no values of the three can overflow it, and it is only narrowed to `Int64`
    /// at the end. The sample is not clamped here: whether it is plausible is the recorder's to say.
    private static func sample(clientNs: Int64, offsetNs: Int64, serverSendNs: Int64) -> Int64 {
        Int64(clamping: Int128(clientNs) + Int128(offsetNs) - Int128(serverSendNs))
    }
}

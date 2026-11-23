import Contracts
import ExchangeCore

/// What one market-feed connection has subscribed to, what is waiting to be sent to it, and the numbering of what it
/// was sent. A plain value with no clock and no tasks: the hub keeps one per connection and the flusher asks it for the
/// next frame.
///
/// - Conflation: at most one pending quote per symbol; a newer quote replaces the waiting one (latest wins), so a
///   slow connection is sent the newest state, never a backlog.
/// - `seq` is per symbol, starts at 1 and grows by exactly 1 for every update assigned, including one that
///   `dropUpdates` withholds; it is never reset, not even by unsubscribing, because a client ignores a lower `seq` as
///   stale.
/// - `frameSeq` counts the frames handed out for sending, starting at 1, heartbeats included.
/// - With `dropUpdates` on, every second published update (one counter across symbols, advancing only while the
///   setting is on) keeps its `seq` but is withheld, so the client sees a gap. A state queued by `subscribe` or
///   `resync` is exempt and does not count, because a client asked for it and would otherwise wait for it in vain.
struct ConnectionFeed: Sendable {
    private struct Pending: Sendable {
        var quote: SymbolQuote
        /// Queued by `subscribe` or `resync`: never withheld. A newer quote that replaces it before it is sent keeps
        /// the exemption, since it is still the state the client asked for, only newer.
        var exempt: Bool
    }

    private(set) var subscribed: Set<UInt32> = []
    private var pending: [UInt32: Pending] = [:]
    private var seqs: [UInt32: UInt64] = [:]
    private var dropCounter: UInt64 = 0
    private(set) var frameSeq: UInt64 = 0

    /// How many symbols have a quote waiting.
    var pendingCount: Int { pending.count }

    /// Whether any quote is waiting to be sent.
    var hasPending: Bool { !pending.isEmpty }

    /// Subscribes to `symbolId` and queues `current`, its full state, if the hub has one yet (a symbol without a quote
    /// is sent at its first publish). Subscribing again re-sends the state.
    mutating func subscribe(_ symbolId: UInt32, current: SymbolQuote?) {
        subscribed.insert(symbolId)
        if let current { pending[symbolId] = Pending(quote: current, exempt: true) }
    }

    /// Ends the subscription to `symbolId` and forgets its waiting quote.
    mutating func unsubscribe(_ symbolId: UInt32) {
        subscribed.remove(symbolId)
        pending[symbolId] = nil
    }

    /// Queues `current`, a symbol's full state, whether or not the connection subscribes to it.
    mutating func resync(_ current: SymbolQuote) {
        pending[current.symbolId] = Pending(quote: current, exempt: true)
    }

    /// Queues `quote` if the connection subscribes to its symbol, replacing any older one; returns whether it did.
    mutating func offer(_ quote: SymbolQuote) -> Bool {
        guard subscribed.contains(quote.symbolId) else { return false }
        let exempt = pending[quote.symbolId]?.exempt ?? false
        pending[quote.symbolId] = Pending(quote: quote, exempt: exempt)
        return true
    }

    /// Takes every waiting quote and returns the frame to send now, stamped `serverSendNs`, or nil when there is
    /// nothing to send: no quote was waiting and no heartbeat is due, or every waiting quote was withheld (such a frame
    /// is not sent at all, unless a heartbeat is due). Updates are in ascending symbol-id order, one per symbol.
    mutating func takeFrame(serverSendNs: Int64, dropUpdates: Bool, heartbeatDue: Bool) -> Tp_MarketFrame? {
        var updates: [Tp_SymbolUpdate] = []
        for symbolId in pending.keys.sorted() {
            guard let waiting = pending[symbolId] else { continue }
            let seq = (seqs[symbolId] ?? 0) + 1
            seqs[symbolId] = seq
            if dropUpdates && !waiting.exempt {
                dropCounter += 1
                if dropCounter.isMultiple(of: 2) { continue }
            }
            updates.append(MarketFrameMapping.update(waiting.quote, seq: seq))
        }
        pending.removeAll()
        guard !updates.isEmpty || heartbeatDue else { return nil }
        frameSeq += 1
        var frame = Tp_MarketFrame()
        frame.serverSendNs = serverSendNs
        frame.frameSeq = frameSeq
        frame.updates = updates
        return frame
    }
}

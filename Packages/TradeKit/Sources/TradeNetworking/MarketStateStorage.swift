import Contracts
import TradeCore

/// Everything a `MarketState` keeps behind its lock: the snapshots, the sequence bookkeeping and the counters.
///
/// It is plain bookkeeping with no lock, no clock and no latency recorder of its own, so each rule about sequence
/// numbers, versions and freshness is written once, here, and can be read without the threading around it.
/// `MarketState` calls into it with the lock held and does everything that touches anything else after the lock is
/// released.
struct MarketStateStorage {
    /// What is known about one symbol.
    struct Entry {
        var snapshot: SymbolSnapshot
        /// Whether `snapshot.seq` is a number from the current connection. It is false for a symbol the connection has
        /// not mentioned yet, whose next update is therefore a baseline: applied, and neither stale nor a gap.
        var hasBaseline: Bool
    }

    /// What `apply` did with the updates of one frame.
    struct FrameResult {
        /// How many updates were applied; the rest were stale.
        var applied = 0
        /// The symbols whose numbering jumped, once each, in the order of the frame. Empty (and allocation-free) when
        /// nothing jumped, which is nearly always.
        var gaps: [UInt32] = []
        /// The clock offset in force while the updates were applied, so that the latency of the frame is worked out
        /// with the offset it was applied under.
        var offsetNs: Int64
    }

    /// What became of one update.
    private enum UpdateOutcome {
        case stale
        case applied
        case appliedAfterGap
    }

    /// How many symbols the dictionary has room for before it first has to grow; the exchange lists a dozen.
    private static let expectedSymbols = 64

    /// The snapshot of a symbol nothing is known about: every number 0 and every candle all zeros.
    private static func blank(symbolId: UInt32) -> SymbolSnapshot {
        let noCandle = Candle(
            openTimeMs: 0, open: Price(satang: 0), high: Price(satang: 0), low: Price(satang: 0),
            close: Price(satang: 0), volume: 0
        )
        return SymbolSnapshot(
            symbolId: symbolId, seq: 0, last: Price(satang: 0), bid: Price(satang: 0), ask: Price(satang: 0),
            bidQty: 0, askQty: 0, dayVolume: 0, candle1s: noCandle, candle1m: noCandle, candle5m: noCandle,
            appliedAtNs: 0, gapCount: 0
        )
    }

    private(set) var entries = [UInt32: Entry](minimumCapacity: Self.expectedSymbols)
    /// Goes up by one for every frame that changed a snapshot and for every reset; never goes back.
    private(set) var version: UInt64 = 0
    /// When the newest frame was received; nil until one has been, so that a receive time of 0 still counts as a frame.
    private(set) var lastFrameAtNs: Int64?
    /// The `serverSendNs` of the oldest applied frame that has not been drawn yet, if it carried one.
    private(set) var pendingRenderStamp: Int64?
    /// The server's clock minus the client's, in nanoseconds.
    var clockOffsetNs: Int64 = 0

    /// Applies one frame's updates and notes that the frame arrived.
    ///
    /// Every frame, an empty one (a heartbeat) included, sets `lastFrameAtNs`, because it is proof that the feed is
    /// alive. Only a frame that applied something bumps `version` and may become the pending render stamp.
    mutating func apply(updates: [Tp_SymbolUpdate], serverSendNs: Int64, receivedAtNs: Int64) -> FrameResult {
        lastFrameAtNs = receivedAtNs
        var result = FrameResult(offsetNs: clockOffsetNs)
        for update in updates {
            switch applyUpdate(update, receivedAtNs: receivedAtNs) {
            case .stale:
                break
            case .applied:
                result.applied += 1
            case .appliedAfterGap:
                result.applied += 1
                if !result.gaps.contains(update.symbolID) {
                    result.gaps.append(update.symbolID)
                }
            }
        }
        if result.applied > 0 {
            version &+= 1
            // Several applied frames can wait for one draw; the oldest is the one measured, so a later one never
            // replaces it. A frame with no stamp has nothing to measure and sets none.
            if serverSendNs > 0, pendingRenderStamp == nil {
                pendingRenderStamp = serverSendNs
            }
        }
        return result
    }

    /// Takes the stamp that is waiting for a draw, if there is one, and the offset in force now.
    mutating func takePendingRenderStamp() -> (stamp: Int64?, offsetNs: Int64) {
        let stamp = pendingRenderStamp
        pendingRenderStamp = nil
        return (stamp, clockOffsetNs)
    }

    /// Starts a connection: every symbol's next update is a baseline again and the gap counts start from 0. The
    /// snapshots stay, so the last prices can still be read until the next update replaces them.
    mutating func beginConnection() {
        for index in entries.values.indices {
            entries.values[index].hasBaseline = false
            entries.values[index].snapshot = entries.values[index].snapshot.withGapCount(0)
        }
    }

    /// Forgets the market: the snapshots, the numbering, the time of the last frame and the pending render stamp.
    /// The version goes up, so that whoever watches it redraws. The clock offset is not market data and stays.
    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        lastFrameAtNs = nil
        pendingRenderStamp = nil
        version &+= 1
    }

    /// Whether a frame has been received and the newest is no older than `maxAgeNs` at `nowNs`.
    ///
    /// The age is worked out in `Int128`, so no pair of times overflows, and a clock that went backwards (a `nowNs`
    /// before the last frame) counts as an age of 0.
    func isFresh(nowNs: Int64, maxAgeNs: Int64) -> Bool {
        guard let lastFrameAtNs else { return false }
        let age = max(0, Int128(nowNs) - Int128(lastFrameAtNs))
        return age <= Int128(maxAgeNs)
    }

    /// Judges one update against the numbering of its symbol and, unless it is stale, puts it in the snapshot.
    private mutating func applyUpdate(_ update: Tp_SymbolUpdate, receivedAtNs: Int64) -> UpdateOutcome {
        let id = update.symbolID
        let known = entries[id]
        let previous = known?.snapshot ?? Self.blank(symbolId: id)
        var gapCount = previous.gapCount
        var outcome = UpdateOutcome.applied
        if known?.hasBaseline == true {
            // The server never goes back within a connection, so a number at or below the last is a repeat.
            if update.seq <= previous.seq { return .stale }
            // Here `update.seq > previous.seq`, so the subtraction cannot underflow whatever the numbers are.
            if update.seq - previous.seq > 1 {
                gapCount &+= 1
                outcome = .appliedAfterGap
            }
        }
        // An update that leaves a candle out says nothing about it, which is not the same as a candle of zeros.
        let snapshot = SymbolSnapshot(
            symbolId: id, seq: update.seq, last: Price(satang: update.last), bid: Price(satang: update.bid),
            ask: Price(satang: update.ask), bidQty: update.bidQty, askQty: update.askQty, dayVolume: update.dayVolume,
            candle1s: update.hasCandle1S ? Candle(wire: update.candle1S) : previous.candle1s,
            candle1m: update.hasCandle1M ? Candle(wire: update.candle1M) : previous.candle1m,
            candle5m: update.hasCandle5M ? Candle(wire: update.candle5M) : previous.candle5m,
            appliedAtNs: receivedAtNs, gapCount: gapCount
        )
        // The update is the new baseline whether or not it jumped: that is what keeps the answer to a resync, which
        // carries the next number, from reporting the same gap twice.
        entries[id] = Entry(snapshot: snapshot, hasBaseline: true)
        return outcome
    }
}

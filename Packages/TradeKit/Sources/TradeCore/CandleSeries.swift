/// The candles of one interval that the chart draws: the closed ones and, last, the one still in progress.
///
/// It is fed in two steps: `seed(history:)` once, with the history from REST, then `apply(current:)` for each live
/// update of the current candle. At most `capacity` candles are kept, the one in progress included; when a new candle
/// opens past that, the oldest drops. Nothing here traps.
public struct CandleSeries: Sendable {
    /// The width of the candles this series holds. The series does not use it to place or merge candles (it trusts each
    /// candle's `openTimeMs`, as the server aligned it): it only says which series this is.
    public let interval: CandleInterval

    /// Starts at 0 and goes up by one each time `all` changes, so a chart can tell whether it has to redraw. Seeding or
    /// applying content that equals what is already there leaves it alone. It wraps at `UInt64.max` rather than trap.
    public private(set) var version: UInt64 = 0

    private let capacity: Int
    /// The closed candles, oldest first: at most `capacity - 1`, because the one in progress takes the last place.
    private var closed: RingBuffer<Candle>
    private var inProgress: Candle?

    /// A capacity below 1 is clamped to 1: the candle in progress is always kept.
    public init(interval: CandleInterval, capacity: Int = 1000) {
        let capacity = max(capacity, 1)
        self.interval = interval
        self.capacity = capacity
        // With a capacity of 1 there is no place for a closed candle: this ring (its smallest size is 1) stays empty.
        closed = RingBuffer(capacity: capacity - 1)
    }

    /// The candles, ascending by `openTimeMs`: the closed ones, then the one in progress; never more than `capacity`.
    /// A new array on each call, so read it once per frame.
    public var all: [Candle] {
        var candles = closed.toArray()
        if let inProgress {
            candles.append(inProgress)
        }
        return candles
    }

    /// Replaces everything with the newest `capacity` candles of `history`. The last of them becomes the candle in
    /// progress, so a later `apply(current:)` with the same `openTimeMs` replaces it.
    ///
    /// `history` must be ascending by `openTimeMs`, which is what the server sends. Anything else is not an error and
    /// is not sorted: the last `capacity` candles are kept in the order given.
    public mutating func seed(history: [Candle]) {
        let kept = Array(history.suffix(capacity))
        guard kept != all else { return }

        closed.removeAll()
        for candle in kept.dropLast() {
            closed.append(candle)
        }
        inProgress = kept.last
        version &+= 1
    }

    /// Takes a live update of the current candle.
    ///
    /// - The same `openTimeMs` as the candle in progress replaces it.
    /// - A later one starts a new candle: the old one is closed as it last was, and the oldest candle drops when the
    ///   series is full. Gaps are not filled in.
    /// - An earlier one is ignored: closed candles are final, and a late update never goes backwards.
    /// - On an empty series the candle simply becomes the one in progress.
    public mutating func apply(current candle: Candle) {
        if let last = inProgress {
            if candle.openTimeMs < last.openTimeMs {
                return
            }
            if candle.openTimeMs == last.openTimeMs {
                if candle == last { return }
            } else if capacity > 1 {
                closed.append(last)
            }
        }
        inProgress = candle
        version &+= 1
    }
}

/// Folds a stream of trades into candles of one interval, one candle at a time.
///
/// Trades are expected in time order, as the simulator produces them. Nothing here traps, whatever the prices,
/// quantities and times.
public struct CandleAggregator: Sendable {
    private let interval: CandleInterval

    /// The candle being built: nil until the first trade, and from then on always the candle of the newest bucket seen.
    public private(set) var current: Candle?

    public init(interval: CandleInterval) {
        self.interval = interval
    }

    /// Adds one trade and returns the candle that this trade just closed, if it did. `atMs` is in milliseconds since
    /// the Unix epoch and only picks the bucket.
    ///
    /// - The first trade opens `current` and returns nil.
    /// - A trade in the same bucket as `current` updates it (high, low, close, volume) and returns nil. Inside one
    ///   bucket the order of the calls, not `atMs`, decides which price is the open and which the close.
    /// - A trade in a later bucket returns the previous `current`, now closed, and opens a new candle at that bucket.
    ///   Buckets with no trades in between get no candle: a gap creates nothing.
    /// - A trade in an earlier bucket than `current` is late: it is ignored, so it returns nil, changes nothing and
    ///   never creates a candle backwards.
    ///
    /// Volume adds `quantity`, saturating at `Int64.max` instead of wrapping. A quantity of zero or less adds nothing,
    /// so volume never decreases; the trade's price still counts like any other.
    public mutating func add(price: Price, quantity: Int64, atMs: Int64) -> Candle? {
        let bucket = interval.bucketStartMs(forMs: atMs)
        let volume = max(quantity, 0)

        guard var candle = current else {
            current = Self.opening(bucket: bucket, price: price, volume: volume)
            return nil
        }
        if bucket < candle.openTimeMs {
            return nil
        }
        if bucket > candle.openTimeMs {
            current = Self.opening(bucket: bucket, price: price, volume: volume)
            return candle
        }

        candle.high = max(candle.high, price)
        candle.low = min(candle.low, price)
        candle.close = price
        let (sum, overflow) = candle.volume.addingReportingOverflow(volume)
        candle.volume = overflow ? .max : sum
        current = candle
        return nil
    }

    private static func opening(bucket: Int64, price: Price, volume: Int64) -> Candle {
        Candle(openTimeMs: bucket, open: price, high: price, low: price, close: price, volume: volume)
    }
}

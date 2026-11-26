/// The width of one candlestick. The raw value is the width in seconds.
public enum CandleInterval: Int, CaseIterable, Sendable {
    case s1 = 1
    case m1 = 60
    case m5 = 300

    /// The width of one candle in seconds: the raw value.
    public var seconds: Int {
        rawValue
    }

    /// The short name for the interval picker: "1s", "1m", "5m".
    public var label: String {
        switch self {
        case .s1: "1s"
        case .m1: "1m"
        case .m5: "5m"
        }
    }

    /// The start, in milliseconds since the Unix epoch, of the candle that `ms` falls in: `ms - ms % width`, with the
    /// width being `seconds * 1000`.
    ///
    /// For the positive epoch milliseconds real timestamps are, that is the largest multiple of the width that is not
    /// above `ms`. The remainder takes the sign of `ms`, so a negative time is rounded toward zero, not down: -1500 ms
    /// is in the one-second bucket that starts at -1000, and every time from `-(width - 1)` to `width - 1` is in the
    /// one bucket that starts at 0. The subtraction always moves toward zero, so it cannot overflow: no `Int64` input
    /// traps.
    public func bucketStartMs(forMs ms: Int64) -> Int64 {
        ms - ms % (Int64(seconds) * 1000)
    }
}

/// One candlestick: the prices of the trades inside one bucket of time, and the shares traded.
///
/// `openTimeMs` is where the bucket starts, in milliseconds since the Unix epoch (a multiple of the interval's width,
/// see `CandleInterval.bucketStartMs(forMs:)`). `volume` is a number of shares.
public struct Candle: Equatable, Sendable {
    public var openTimeMs: Int64
    public var open, high, low, close: Price
    public var volume: Int64

    /// The fields in declared order. Nothing is checked, so `high` and `low` are whatever the caller says they are:
    /// a candle that came off the wire is taken as it came.
    public init(openTimeMs: Int64, open: Price, high: Price, low: Price, close: Price, volume: Int64) {
        self.openTimeMs = openTimeMs
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }
}

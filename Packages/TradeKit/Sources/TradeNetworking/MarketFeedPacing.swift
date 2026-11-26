/// Decides whether a gap in a symbol's updates is answered with a resync: at most once per symbol per window.
///
/// One gap is enough reason to ask for the whole state again, but while updates keep going missing every new update
/// is another gap, and a resync for each would flood the server. So a symbol that was resynced less than `window` ago
/// is refused, and the refused gap is not queued: the next gap after the window asks again, and by then the state it
/// gets is newer anyway. Time is read from a monotonic clock, which a change of the wall clock cannot move. Symbols
/// are independent of one another.
struct ResyncLimiter {
    private let window: Duration
    /// When each symbol was last let through.
    private var lastSent: [UInt32: ContinuousClock.Instant] = [:]

    /// A limiter that lets one resync per symbol through per `window`.
    init(window: Duration = .seconds(1)) {
        self.window = window
    }

    /// Whether a gap of `symbolId` seen at `now` is answered with a resync; if it is, the window starts again from
    /// `now`. A gap a whole window (or more) after the last resync is let through.
    mutating func admit(_ symbolId: UInt32, at now: ContinuousClock.Instant) -> Bool {
        if let last = lastSent[symbolId], now - last < window { return false }
        lastSent[symbolId] = now
        return true
    }
}

/// When the pings of one feed connection go out.
///
/// The first `rounds` pings are sent `spacing` apart from the moment the connection opens, so the clock offset is
/// measured from several round trips (the estimator keeps the fastest) before the screen relies on it. After that one
/// ping goes out every `interval`, to follow a clock that drifts.
enum PingSchedule {
    /// How many pings measure the offset when a connection opens.
    static let rounds = 8
    /// The time between two of those first pings.
    static let spacing = Duration.milliseconds(50)
    /// The time between two pings once the first rounds are done.
    static let interval = Duration.seconds(30)

    /// The wait before ping number `ping` (0 is the first, sent at once).
    static func delay(before ping: Int) -> Duration {
        if ping <= 0 { return .zero }
        return ping < rounds ? spacing : interval
    }
}

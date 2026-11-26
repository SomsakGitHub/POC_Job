import Synchronization

/// What is measured. Times are wall-clock nanoseconds (`WallClock`); "server time" is the timestamp the server put on
/// the frame or event before sending it. The raw values are the case names.
public enum LatencyMetric: String, CaseIterable, Sendable, Codable {
    /// Server time to the WebSocket frame being received by the app.
    case tickToApp
    /// Server time to the update having been applied to the app's market state.
    case tickToApplied
    /// Server time to the display frame that shows the tick being committed (read from the display link).
    case tickToRender
    /// Just before `SubmitOrder` is called to its response arriving: the whole round trip.
    case orderSubmitToAck
    /// The server's own part of that round trip: its ack time minus its receive time. Reported apart from the round
    /// trip, so the two can be told apart.
    case orderServerProcessing
    /// Just before `SubmitOrder` is called to the fill event arriving on the stream.
    case orderSubmitToFill
}

/// One histogram per `LatencyMetric`, safe to record into and read from many tasks at once.
///
/// All six metrics always exist: `snapshot()` has an entry for each, an unused one as an empty summary, and
/// `summary(_:)` of a metric nothing was recorded for is the same empty summary (count 0, no percentiles).
///
/// The histograms sit behind one lock, so each call is atomic and `snapshot()` is one consistent moment across all
/// six metrics. Summaries are worked out inside the lock, which takes microseconds. Samples go through
/// `LatencyHistogram.record(nanos:)`: negative and over-10-s samples are clamped there and counted as clamped.
public final class LatencyRecorder: Sendable {
    private let histograms = Mutex<[LatencyMetric: LatencyHistogram]>([:])

    /// What a metric with no samples summarises to.
    private static let empty = LatencyHistogram().summary()

    public init() {}

    /// Records one latency in nanoseconds for `metric`.
    public func record(_ metric: LatencyMetric, nanos: Int64) {
        histograms.withLock { $0[metric, default: LatencyHistogram()].record(nanos: nanos) }
    }

    /// The summary of `metric`: empty (count 0, no percentiles) if nothing was recorded since the start or the last
    /// `reset()`.
    public func summary(_ metric: LatencyMetric) -> PercentileSummary {
        histograms.withLock { $0[metric]?.summary() ?? Self.empty }
    }

    /// The summary of every metric, all six, taken at one moment.
    public func snapshot() -> [LatencyMetric: PercentileSummary] {
        histograms.withLock { state in
            Dictionary(uniqueKeysWithValues: LatencyMetric.allCases.map { ($0, state[$0]?.summary() ?? Self.empty) })
        }
    }

    /// Forgets every sample of every metric.
    public func reset() {
        histograms.withLock { $0.removeAll() }
    }
}

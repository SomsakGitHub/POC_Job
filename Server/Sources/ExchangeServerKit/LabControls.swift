import Contracts

/// The lab's settings and the one place they change.
///
/// The lab exists to stress the clients: it makes the market tick faster, and delays, jitters and thins out what the
/// market feed sends. The market runner uses `rateMultiplier` and `stress`; `extraLatencyMs`, `jitterMs` and
/// `dropUpdates` are the market feed's. Whoever uses a setting reads it afresh each time (the runner at every
/// iteration, the feed for every frame), so a change takes effect at once, with no restart.
///
/// A patch is clamped into the ranges below and never refused, and `apply` answers the settings that are now in force,
/// so a caller that sent a value out of range sees the value the server used. These ranges are the server's contract:
/// a picker in a client stays inside them.
///
/// - `rateMultiplier`: 0.1 to 10. A value that is not a finite positive number is ignored, because it names no rate.
/// - `extraLatencyMs`: 0 to 5,000.
/// - `jitterMs`: 0 to 2,000.
/// - `stress` and `dropUpdates` are taken as sent.
public actor LabControls {
    private static let rateMultiplierRange = 0.1...10.0
    private static let extraLatencyMsRange = 0...5_000
    private static let jitterMsRange = 0...2_000

    private var current = LabSettings()

    /// A lab at the neutral settings: the normal rate, no stress, no delay, no jitter and no dropped updates.
    public init() {}

    /// The settings in force now.
    public func settings() -> LabSettings {
        current
    }

    /// Applies the fields present in `patch`, each clamped into its range, and leaves the others as they were.
    /// Returns the settings in force afterwards.
    @discardableResult
    public func apply(_ patch: LabPatch) -> LabSettings {
        if let rate = patch.rateMultiplier, rate.isFinite, rate > 0 {
            current.rateMultiplier = Self.clamp(rate, to: Self.rateMultiplierRange)
        }
        if let stress = patch.stress {
            current.stress = stress
        }
        if let latency = patch.extraLatencyMs {
            current.extraLatencyMs = Self.clamp(latency, to: Self.extraLatencyMsRange)
        }
        if let jitter = patch.jitterMs {
            current.jitterMs = Self.clamp(jitter, to: Self.jitterMsRange)
        }
        if let drop = patch.dropUpdates {
            current.dropUpdates = drop
        }
        return current
    }

    private static func clamp<Value: Comparable>(_ value: Value, to range: ClosedRange<Value>) -> Value {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

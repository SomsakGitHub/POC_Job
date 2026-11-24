import Observation
import QuartzCore
import TradeCore
import TradeNetworking

/// The app's frame clock: a display link that calls `step` once per display refresh, and what `step` makes of the
/// market's changes.
///
/// The feed can deliver far more updates than the display can show, and a screen that redrew for each of them would
/// spend its time on frames nobody sees. The pump turns the updates of one display frame into one change of `tick`, and
/// into none in a frame in which the market did not change, so a view that reads `tick` is evaluated once per frame
/// that has something new to show. It also counts the frames and the ones that hitched, and tells the market state
/// when the new prices of a frame are due on screen, for the render latency.
///
/// Only `tick`, `frames` and `hitches` are observable. The two counters change with every frame, so a view that wants
/// to redraw for new prices reads `tick` alone.
@MainActor @Observable
final class FramePump {
    /// What makes a display link: one that calls `selector` of `target` once per display frame.
    typealias LinkFactory = (_ target: FrameLinkTarget, _ selector: Selector) -> CADisplayLink

    /// How many display frames showed new market data.
    private(set) var tick: UInt64 = 0
    /// How many display frames were measured, the hitches among them. The first frame after a start is not one: it
    /// has no interval to measure.
    private(set) var frames = 0
    /// How many of the measured frames took more than one and a half times the time a frame is meant to take.
    private(set) var hitches = 0

    /// The running display link; nil while the pump is stopped.
    @ObservationIgnored private(set) var displayLink: CADisplayLink?

    /// The market whose changes the pump watches and whose renders it stamps.
    @ObservationIgnored private let marketState: MarketState
    /// Counts the frames and the hitches from the interval between two frames.
    @ObservationIgnored private var detector: HitchDetector
    /// The client's wall clock in nanoseconds, which is the clock the market state measures its latencies on.
    @ObservationIgnored private let now: @Sendable () -> Int64
    /// The display's clock in seconds, which is the clock the timestamps of a display link are on.
    @ObservationIgnored private let mediaNow: () -> CFTimeInterval
    /// Makes the display link of a start.
    @ObservationIgnored private let makeLink: LinkFactory
    /// How long the views took to draw, as they reported it.
    @ObservationIgnored private var drawHistogram = LatencyHistogram()
    /// The market version the last tick was made for.
    @ObservationIgnored private var lastVersion: UInt64
    /// The timestamp of the previous frame; nil before the first frame and again after every start.
    @ObservationIgnored private var previousTimestamp: CFTimeInterval?
    /// When the newest frame is due on screen, on the client's wall clock; nil before the first frame.
    @ObservationIgnored private var lastPresentNs: Int64?

    /// Whether the display link is running.
    var isRunning: Bool { displayLink != nil }

    /// What drawing took, as the 50th, 95th and 99th percentile of the times reported to `notifyRendered`.
    var drawCost: PercentileSummary { drawHistogram.summary() }

    /// A pump that watches `marketState`. `now` is the client's wall clock in nanoseconds and `mediaNow` the display's
    /// clock in seconds, so that a test can set both. `makeLink` makes the display link of `start()`, so that a test
    /// can hand the pump a link that no run loop drives.
    init(
        marketState: MarketState, hitchDetector: HitchDetector = .init(),
        now: @escaping @Sendable () -> Int64 = { WallClock.nowNs() },
        mediaNow: @escaping () -> CFTimeInterval = { CACurrentMediaTime() },
        makeLink: @escaping LinkFactory = { CADisplayLink(target: $0, selector: $1) }
    ) {
        self.marketState = marketState
        detector = hitchDetector
        self.now = now
        self.mediaNow = mediaNow
        self.makeLink = makeLink
        lastVersion = marketState.version
        frames = hitchDetector.frames
        hitches = hitchDetector.hitches
    }

    /// Starts the display link, on the main run loop in the common modes so that it also fires while a list scrolls.
    /// Starting a pump that runs does nothing. The first frame after a start has no interval, so the time the app
    /// spent stopped is never counted as a hitch.
    func start() {
        guard displayLink == nil else { return }
        let link = makeLink(FrameLinkTarget(pump: self), #selector(FrameLinkTarget.fire(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        previousTimestamp = nil
    }

    /// Ends the display link. Stopping a pump that is stopped does nothing.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// One display frame, as the display link reports it: `timestamp` is when the previous frame was shown,
    /// `targetTimestamp` when this one is due on screen, and `duration` how long a frame is meant to take, all in
    /// seconds of the display's clock.
    ///
    /// It counts the frame and the hitch (an interval of more than 1.5 times `duration` since the previous frame),
    /// works out when the frame is due on the client's wall clock, and, if the market changed since the last frame,
    /// moves `tick` and tells the market state that this frame renders what was applied. The latency that records is
    /// the time from the server's stamp to the moment the display link says the frame is due on screen; it is not a
    /// measurement of the GPU.
    func step(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval, duration: CFTimeInterval) {
        let interval = previousTimestamp.map { Self.nanoseconds(timestamp - $0) } ?? 0
        detector.record(frameIntervalNs: interval, expectedNs: Self.nanoseconds(duration))
        // A counter is written only when it moved, so that a view that reads one is not told of a write that changed
        // nothing.
        if detector.frames != frames { frames = detector.frames }
        if detector.hitches != hitches { hitches = detector.hitches }
        previousTimestamp = timestamp

        let presentNs = Self.saturatingAdd(now(), Self.nanoseconds(targetTimestamp - mediaNow()))
        lastPresentNs = presentNs
        let version = marketState.version
        guard version != lastVersion else { return }
        lastVersion = version
        tick &+= 1
        // The frame prepared in this callback is the one that carries the tick. Stamping it here, and not only when
        // a chart draws, keeps the stamp of a frame from waiting minutes on a screen that has no chart.
        marketState.markRendered(atNs: presentNs)
    }

    /// A view finished drawing, and it took `drawNs`. Frames applied since the last `step` are rendered by this draw,
    /// so they are stamped with the same due time as that step, or with the clock when no frame has been stepped yet.
    func notifyRendered(drawNs: Int64) {
        marketState.markRendered(atNs: lastPresentNs ?? now())
        drawHistogram.record(nanos: drawNs)
    }

    /// `seconds` as whole nanoseconds, rounded to the nearest. A number that is not finite is 0 and one that does not
    /// fit in an `Int64` is the nearest bound. The comparisons come before the conversion, because `Double(Int64.max)`
    /// is 2^63, which `Int64(_:)` traps on.
    nonisolated static func nanoseconds(_ seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        let nanoseconds = (seconds * 1e9).rounded()
        if nanoseconds >= Double(Int64.max) { return .max }
        if nanoseconds <= Double(Int64.min) { return .min }
        return Int64(nanoseconds)
    }

    /// `lhs + rhs`, kept at the `Int64` bound of the addends' sign when the sum does not fit.
    nonisolated static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs < 0 ? .min : .max
    }
}

/// What a display link calls: it hands every frame to the pump.
///
/// The run loop holds a link's target, so a target that held the pump would keep a pump that nothing else uses alive,
/// and its link firing, for ever. It holds the pump weakly instead, and ends the link when the pump is gone.
final class FrameLinkTarget: NSObject {
    /// The pump that gets the frames; nil once nothing else holds it.
    private weak var pump: FramePump?

    /// A target that hands the frames of its link to `pump`.
    init(pump: FramePump) {
        self.pump = pump
    }

    /// The selector of the display link, which fires on the main run loop.
    @objc func fire(_ link: CADisplayLink) {
        handle(
            timestamp: link.timestamp, targetTimestamp: link.targetTimestamp, duration: link.duration,
            invalidate: link.invalidate
        )
    }

    /// Passes one frame to the pump, or, when the pump is gone, ends the link through `invalidate`.
    func handle(
        timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval, duration: CFTimeInterval, invalidate: () -> Void
    ) {
        guard let pump else {
            invalidate()
            return
        }
        MainActor.assumeIsolated {
            pump.step(timestamp: timestamp, targetTimestamp: targetTimestamp, duration: duration)
        }
    }
}

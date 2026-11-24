import Contracts
import QuartzCore
import TradeCore
import TradeNetworking
@testable import TradePulse

/// A pump over a market state whose clocks a test moves by hand: `clock` is the client's wall clock in nanoseconds
/// (what the market state and the pump read as "now") and `media` is the display's clock in seconds. Nothing in it
/// waits for time to pass: every frame is a call to `step`.
@MainActor
struct PumpRig {
    /// Where the pump and the market state record their latencies.
    let latency = LatencyRecorder()
    /// The wall clock in nanoseconds.
    let clock: ManualClock
    /// The display's media clock in seconds.
    let media: ManualMedia
    /// The market state the pump watches.
    let market: MarketState
    /// The pump under test.
    let pump: FramePump

    /// A rig whose wall clock reads `nowNs` and whose media clock reads `mediaNow`. The pump gets its display link
    /// from `makeLink`, which makes the system's link unless a test passes its own.
    init(
        nowNs: Int64 = 5_000_000_000, mediaNow: Double = 100.0,
        makeLink: @escaping FramePump.LinkFactory = { CADisplayLink(target: $0, selector: $1) }
    ) {
        let latency = latency
        let clock = ManualClock(nowNs)
        let media = ManualMedia(mediaNow)
        self.clock = clock
        self.media = media
        market = MarketState(latency: latency, nowNs: { clock.read() })
        pump = FramePump(
            marketState: market, now: { clock.read() }, mediaNow: { media.read() }, makeLink: makeLink
        )
    }

    /// Applies one frame, stamped `sendNs` by the server (0 is unstamped), that changes the first symbol's snapshot.
    /// `seq` has to be higher than the one before, or the update counts as a repeat and changes nothing.
    func apply(seq: UInt64, sendNs: Int64 = 0) {
        let frame = marketFrame(sendNs: sendNs, updates: [symbolUpdate(seq: seq)])
        _ = market.apply(frame: frame, receivedAtNs: sendNs + 1_000)
    }

    /// One display frame at `timestamp` seconds that is due on screen 16 ms later, for a display of 16 ms frames.
    func step(at timestamp: Double) {
        pump.step(timestamp: timestamp, targetTimestamp: timestamp + 0.016, duration: 0.016)
    }
}

/// A display link that no run loop drives: it reports the times it was given, and notes what it was asked to do.
/// A link the system did not make has nothing behind it, so the real `add(to:forMode:)` and `invalidate()` are never
/// called on it.
final class StubLink: CADisplayLink {
    /// One call of `add(to:forMode:)`.
    struct Registration {
        /// The run loop the link was added to.
        let loop: RunLoop
        /// The mode it was added in.
        let mode: RunLoop.Mode
    }

    /// What the link reports as the time of the previous frame.
    private let stampedAt: CFTimeInterval
    /// What the link reports as the time this frame is due on screen.
    private let dueAt: CFTimeInterval
    /// What the link reports as the length of a frame.
    private let frameLength: CFTimeInterval

    /// Every call of `add(to:forMode:)`, in order.
    private(set) var registrations: [Registration] = []
    /// How many times the link was invalidated.
    private(set) var invalidations = 0

    /// A link that reports these three times, in seconds.
    init(timestamp: CFTimeInterval = 0, targetTimestamp: CFTimeInterval = 0, duration: CFTimeInterval = 0) {
        stampedAt = timestamp
        dueAt = targetTimestamp
        frameLength = duration
        super.init()
    }

    /// The time of the previous frame.
    override var timestamp: CFTimeInterval { stampedAt }
    /// The time this frame is due on screen.
    override var targetTimestamp: CFTimeInterval { dueAt }
    /// The length of a frame.
    override var duration: CFTimeInterval { frameLength }

    /// Notes the run loop and the mode, and adds nothing to the run loop.
    override func add(to runloop: RunLoop, forMode mode: RunLoop.Mode) {
        registrations.append(Registration(loop: runloop, mode: mode))
    }

    /// Counts the call, and ends nothing.
    override func invalidate() {
        invalidations += 1
    }
}

/// A link factory for a pump that makes `StubLink`s and keeps what the pump asked for.
@MainActor
final class StubLinks {
    /// The target and the selector of every link the pump asked for, in order.
    private(set) var requests: [(target: FrameLinkTarget, selector: Selector)] = []
    /// The links that were made, in order.
    private(set) var made: [StubLink] = []

    /// The link for `target` and `selector`: a new `StubLink`, which the pump runs in place of a system link.
    func make(_ target: FrameLinkTarget, _ selector: Selector) -> CADisplayLink {
        let link = StubLink()
        requests.append((target, selector))
        made.append(link)
        return link
    }
}

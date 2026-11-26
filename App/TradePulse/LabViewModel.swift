import Contracts
import Dispatch
import Foundation
import Observation
import TradeCore
import TradeNetworking

/// What the last probe of the REST API found. REST has no connection that is up or down, so the Lab shows what a probe
/// of the server's clock found.
enum RestStatus: Equatable {
    /// No probe has been answered yet.
    case unknown
    /// The server answered the probe, `rttNs` nanoseconds after it was sent.
    case reachable(rttNs: Int64)
    /// The probe failed.
    case unreachable
}

/// What the Lab screen shows and what its controls do.
///
/// The settings it shows are always the ones the server answered with: the server holds a value in its range, so the
/// answer to a change, and not the change that was asked for, is what is in force. Requests can overlap, and an answer
/// that arrives after a newer request of the same kind was made is dropped, whether it is good or bad. A request that
/// ended because it was cancelled is never an error to show.
///
/// A control that is ahead of the server while a request is on its way, such as a slider under a finger, looks at the
/// settings again when `settingsRevision` changes: whatever the request brought, the settings are what it shows.
///
/// The model reads nothing that moves with the display frames when it is made or when a view reads it. The pump's
/// counters are read only in `sampleFrames()`, which the screen calls twice a second, and the texts that come out of
/// it are the model's own properties, so the views that show them change twice a second and not sixty times.
@MainActor @Observable
final class LabViewModel {
    /// How long the loop waits between two rounds of looking at the server.
    private static let roundInterval = Duration.seconds(5)

    // MARK: What the screen reads

    /// The settings in force on the server, as it last said so: the defaults until it has said anything.
    private(set) var settings = LabSettings()
    /// Whether the server has told the settings, by the answer to a read or to a change. The controls wait for it.
    private(set) var settingsLoaded = false
    /// How many requests for the settings have ended in a way that counts: with an answer or with a failure. A request
    /// that was cancelled, or that a newer request overtook, is not counted. It changes at the pace of the user's taps
    /// and not of the prices or the frames.
    private(set) var settingsRevision = 0
    /// What the comparison of the app's account with the server's found last; in flight until it has found anything.
    private(set) var reconciliation: Reconciliation = .inFlight
    /// What the last probe of the REST API found.
    private(set) var restStatus = RestStatus.unknown
    /// The line under the controls: what the last request that did not work could not do; nil when it worked.
    private(set) var lastError: String?
    /// The frames per second between the last two samples, in words.
    private(set) var fpsText = LabLabels.noData
    /// The hitches and their share of the frames at the last sample, in words.
    private(set) var hitchText = LabLabels.noData
    /// What drawing the chart cost at the last sample, in words.
    private(set) var drawTimeText = LabLabels.noData

    // MARK: What the model works with

    /// The REST API the settings, the probe and the three buttons go to.
    @ObservationIgnored private let rest: any RestAPI
    /// The recorder whose samples Reset stats forgets.
    @ObservationIgnored private let latency: LatencyRecorder
    /// The frame clock whose counters are sampled and reset.
    @ObservationIgnored private let pump: FramePump
    /// The trading store whose account the check compares with the server's.
    @ObservationIgnored private let trading: TradingStore
    /// How the loop waits between rounds.
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// A clock that only goes forward, in nanoseconds: what the round trip of a probe is measured on.
    @ObservationIgnored private let monotonicNs: @Sendable () -> UInt64
    /// Turns the pump's counter into a rate.
    @ObservationIgnored private var meter = FrameRateMeter()
    /// How many requests for the settings (reads and changes together) have started; the newest one is the only one
    /// whose answer counts.
    @ObservationIgnored private var settingsGeneration = 0
    /// How many probes have started.
    @ObservationIgnored private var probeGeneration = 0
    /// How many account checks have started.
    @ObservationIgnored private var checkGeneration = 0

    /// A model over the server's REST API `rest`, the recorder `latency`, the frame clock `pump` and the trading store
    /// `trading`. `sleep` is how the loop waits and `monotonicNs` the clock a probe's round trip is measured on, so a
    /// test can run the loop without waiting and say what the clock reads.
    init(
        rest: any RestAPI, latency: LatencyRecorder, pump: FramePump, trading: TradingStore,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        monotonicNs: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.rest = rest
        self.latency = latency
        self.pump = pump
        self.trading = trading
        self.sleep = sleep
        self.monotonicNs = monotonicNs
    }

    // MARK: Requests

    /// Reads the settings the server holds. A failure keeps what the model had and says the server could not be
    /// reached; a later read that works enables the controls.
    func load() async {
        await requestSettings(failure: LabMessages.couldNotReachTheServer) { try await rest.lab() }
    }

    /// Changes the settings with `patch`. What the screen shows afterwards is the whole answer, the settings now in
    /// force: the server may have held a value in its range, or another client may have changed a setting that the
    /// patch left alone. A failure keeps the settings and says the change did not work.
    func apply(_ patch: LabPatch) async {
        await requestSettings(failure: LabMessages.couldNotChangeTheSetting) { try await rest.setLab(patch) }
    }

    /// Asks the server for `patch` as `apply` does, and returns at once: a tap or a drag does not wait for the server,
    /// and what the controls show is the settings the answer brings. The task is the wait for the answer, which a
    /// caller with nothing to do after it lets go.
    @discardableResult
    func ask(_ patch: LabPatch) -> Task<Void, Never> {
        Task { await apply(patch) }
    }

    /// Asks the server to close the live connections it holds to the app. The app's own clients notice that on their
    /// own and reconnect, which is what the button is there to show, so nothing else happens here.
    func dropConnections() async {
        do {
            try await rest.dropConnections()
            lastError = nil
        } catch {
            if !Self.isCancellation(error) { lastError = LabMessages.couldNotDropTheConnections }
        }
    }

    /// Asks the server to start a new epoch: the account goes back to its starting cash and the orders are forgotten.
    /// The app's own clients notice the new epoch on their own, so nothing else happens here.
    func resetAccount() async {
        do {
            _ = try await rest.resetServer()
            lastError = nil
        } catch {
            if !Self.isCancellation(error) { lastError = LabMessages.couldNotResetTheAccount }
        }
    }

    /// Sends one request for the settings and takes its answer, unless a newer request has started by then: reads and
    /// changes share one order, the order they were started in, so the answer of the newest one stands whichever
    /// comes back first. A failure that is not a cancellation is `failure`, under the same rule. A request that ends
    /// in an answer or in such a failure is counted in `settingsRevision`.
    private func requestSettings(failure: String, _ ask: () async throws -> LabSettings) async {
        settingsGeneration &+= 1
        let started = settingsGeneration
        do {
            let answer = try await ask()
            guard started == settingsGeneration else { return }
            settings = answer
            settingsLoaded = true
            lastError = nil
        } catch {
            guard started == settingsGeneration, !Self.isCancellation(error) else { return }
            lastError = failure
        }
        settingsRevision &+= 1
    }

    /// Whether `error` is the end of a request whose task was cancelled. A task that is cancelled while it waits for
    /// the server ends with a `CancellationError` or, when the system cancels the transfer, with a URL error; neither
    /// is a failure to show.
    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }

    // MARK: Looking at the server

    /// Looks at the server until the task is cancelled: a probe of the REST API, the account check, and then a wait of
    /// five seconds, over and over. The first round is made before the first wait, so the screen has numbers the
    /// moment it opens. A wait that ends in an error ends the loop.
    func monitor() async {
        while !Task.isCancelled {
            await probeRest()
            guard !Task.isCancelled else { return }
            await refreshReconciliation()
            do {
                try await sleep(Self.roundInterval)
            } catch {
                return
            }
        }
    }

    /// Asks the server for its clock and times the answer on the monotonic clock. An answer is `reachable` with the
    /// round trip, which is never negative and is clamped into an `Int64`; a failure is `unreachable`. A probe that
    /// was cancelled, or that a newer probe has overtaken, changes nothing.
    func probeRest() async {
        probeGeneration &+= 1
        let started = probeGeneration
        let startedAt = monotonicNs()
        do {
            _ = try await rest.serverTimeNs()
            let endedAt = monotonicNs()
            guard started == probeGeneration else { return }
            let elapsed = endedAt >= startedAt ? endedAt - startedAt : 0
            restStatus = .reachable(rttNs: Int64(clamping: elapsed))
        } catch {
            guard started == probeGeneration, !Self.isCancellation(error) else { return }
            restStatus = .unreachable
        }
    }

    /// Compares the app's account with the server's and shows what the comparison found. A store that has not read the
    /// server yet is not compared: it would report drift against the server's starting cash, a defect that is only
    /// "not loaded yet", so the answer stays in flight and the server is not asked. A check that was cancelled, or
    /// that a newer check has overtaken, changes nothing.
    func refreshReconciliation() async {
        checkGeneration &+= 1
        let started = checkGeneration
        guard trading.state.epoch != nil else {
            reconciliation = .inFlight
            return
        }
        let verdict = await trading.reconcile()
        guard started == checkGeneration, !Task.isCancelled else { return }
        reconciliation = verdict
    }

    // MARK: Frames

    /// Takes a sample of the frames: reads the pump's counters and the cost of drawing, and turns them into the
    /// model's texts. The screen calls it twice a second, and this is the only place the model reads the counters,
    /// which change with every frame: the texts change at the pace of the samples.
    func sampleFrames() {
        let frames = pump.frames
        let hitches = pump.hitches
        let drawn = pump.drawCost
        let rate = meter.sample(frames: frames, atNs: Int64(clamping: monotonicNs()))
        fpsText = FrameRateMeter.text(for: rate)
        hitchText = HitchRateText.text(hitches: hitches, frames: frames)
        drawTimeText = DrawTimeText.text(for: drawn)
    }

    /// Starts everything the Lab shows over: the latency samples, the frame and hitch counts and the draw times, and
    /// the frame rate, which counts only the frames since now. The server is not touched.
    func resetStats() {
        latency.reset()
        pump.resetStatistics()
        meter.restart()
        sampleFrames()
    }
}

import Contracts
import Dispatch
import Foundation
import Observation
import TradeCore
import TradeNetworking

/// What the Lab screen shows and what its controls do.
///
/// The settings it shows are always the ones the server answered with: the server holds a value in its range, so the
/// answer to a change, and not the change that was asked for, is what is in force. The loop reads them every round, so
/// a server that started over or a change from outside shows too. `SettingsOrder` says whose answer counts when
/// requests overlap. A request that ended because it was cancelled is never an error to show.
///
/// A control that is ahead of the server while a request is on its way, such as a slider under a finger, looks at the
/// settings again when `settingsRevision` changes. A round that finds the server as the screen shows it changes
/// nothing, so no view is evaluated again for it.
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
    /// How many times the server has brought something the controls must look at again: a request of the user's for the
    /// settings that ended with an answer or a failure, and a read of the loop that found other settings than the ones
    /// on show. A request that was cancelled or set aside, and a read that found nothing new, is not counted.
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
    /// Whose answer counts when requests for the settings overlap.
    @ObservationIgnored private var order = SettingsOrder()
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

    /// Reads the settings the server holds, because the user asked to. A failure keeps what the model had and says the
    /// server could not be reached; an answer enables the controls.
    func load() async {
        let read = order.startRead()
        await settle(LabMessages.couldNotReachTheServer, stands: order.counts(read)) { try await rest.lab() }
    }

    /// Reads the settings the server holds, as the loop does every round, and says nothing unless there is something
    /// new: other settings than the ones on show, or the first ones. An answer takes the line "could not reach the
    /// server" away, never the line of a change, a drop or a reset that did not work. A failure is said only while the
    /// controls wait for the first answer, where it makes them say the settings are unavailable; the REST row already
    /// says when the server is down.
    func refreshSettings() async {
        let read = order.startRead()
        do {
            let answer = try await rest.lab()
            guard order.counts(read) else { return }
            if lastError == LabMessages.couldNotReachTheServer { lastError = nil }
            guard answer != settings || !settingsLoaded else { return }
            settings = answer
            settingsLoaded = true
            settingsRevision &+= 1
        } catch {
            guard order.counts(read), !endsACancelledRequest(error) else { return }
            if !settingsLoaded, lastError == nil { lastError = LabMessages.couldNotReachTheServer }
        }
    }

    /// Changes the settings with `patch`. What the screen shows afterwards is the whole answer, the settings now in
    /// force: the server may have held a value in its range, or another client may have changed a setting that the
    /// patch left alone. A failure keeps the settings and says the change did not work.
    func apply(_ patch: LabPatch) async {
        let change = order.startChange()
        defer { order.endChange() }
        await settle(LabMessages.couldNotChangeTheSetting, stands: order.counts(change)) {
            try await rest.setLab(patch)
        }
    }

    /// Asks the server for `patch` as `apply` does, and returns at once, so a tap or a drag does not wait for the
    /// server. The task is the wait for the answer, which a caller with nothing to do after it lets go.
    @discardableResult
    func ask(_ patch: LabPatch) -> Task<Void, Never> {
        Task { await apply(patch) }
    }

    /// Asks the server to close the live connections it holds to the app. The app's own clients notice that on their
    /// own and reconnect, which is what the button is there to show, so nothing else happens here.
    func dropConnections() async {
        await attempt(failure: LabMessages.couldNotDropTheConnections) { try await rest.dropConnections() }
    }

    /// Asks the server to start a new epoch: the account goes back to its starting cash and the orders are forgotten.
    /// The app's own clients notice the new epoch on their own, so nothing else happens here.
    func resetAccount() async {
        await attempt(failure: LabMessages.couldNotResetTheAccount) { _ = try await rest.resetServer() }
    }

    /// Makes a request that is not about the settings: the line under the controls goes when it works, and is `failure`
    /// when it does not, unless the request was cancelled.
    private func attempt(failure: String, _ request: () async throws -> Void) async {
        do {
            try await request()
            lastError = nil
        } catch {
            if !endsACancelledRequest(error) { lastError = failure }
        }
    }

    /// Sends one request of the user's for the settings and takes its answer, or its failure (`line` is what is said,
    /// unless it was cancelled), if it `stands` as `SettingsOrder` says. What is taken counts in `settingsRevision`.
    private func settle(_ line: String, stands: @autoclosure () -> Bool, _ ask: () async throws -> LabSettings) async {
        do {
            let answer = try await ask()
            guard stands() else { return }
            settings = answer
            settingsLoaded = true
            lastError = nil
        } catch {
            guard stands(), !endsACancelledRequest(error) else { return }
            lastError = line
        }
        settingsRevision &+= 1
    }

    // MARK: Looking at the server

    /// Looks at the server until the task is cancelled: a probe of the REST API, a read of the settings, the account
    /// check, and then a wait of five seconds, over and over. The first round is made before the first wait, so the
    /// screen has numbers and live controls the moment it opens. A wait that ends in an error ends the loop.
    func monitor() async {
        while !Task.isCancelled {
            await probeRest()
            guard !Task.isCancelled else { return }
            await refreshSettings()
            guard !Task.isCancelled else { return }
            await refreshReconciliation()
            do { try await sleep(Self.roundInterval) } catch { return }
        }
    }

    /// Asks the server for its clock and times the answer on the monotonic clock: `reachable` with the round trip,
    /// which is never negative and is clamped into an `Int64`, or `unreachable`. A probe that was cancelled, or that a
    /// newer probe has overtaken, changes nothing.
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
            guard started == probeGeneration, !endsACancelledRequest(error) else { return }
            restStatus = .unreachable
        }
    }

    /// Compares the app's account with the server's and shows what the comparison found. A store that has not read the
    /// server yet is not compared, as it would report drift against the server's starting cash: the answer stays in
    /// flight and the server is not asked. A check that was cancelled or overtaken changes nothing.
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
    /// model's texts. The screen calls it twice a second, and it is the only place the model reads the counters, which
    /// change with every frame.
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

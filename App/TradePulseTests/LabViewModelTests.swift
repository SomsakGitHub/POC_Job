import Contracts
import Foundation
import Testing
import TradeNetworking
@testable import TradePulse

/// What the Lab does with the server's settings and with the three requests that change the server: the settings it
/// shows are the ones the server answers with, an answer that arrives after a newer request was made is dropped, and
/// a request that failed or was cancelled is told in plain words or not at all.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LabViewModelTests {
    /// The settings the server answers with once the rate has been set to 2: no other knob is on.
    private let calm = LabSettings(rateMultiplier: 2, stress: false, extraLatencyMs: 0, jitterMs: 0, dropUpdates: false)
    /// Settings that differ from `calm` and from `busyLab` in every field.
    private let other = LabSettings(
        rateMultiplier: 3, stress: true, extraLatencyMs: 200, jitterMs: 20, dropUpdates: false
    )

    /// One of the four requests of the Lab, with what is needed to hold it in flight and to let it go.
    enum Request: CaseIterable, CustomTestStringConvertible, Sendable {
        case load, apply, dropConnections, resetAccount

        var testDescription: String {
            switch self {
            case .load: "load"
            case .apply: "apply"
            case .dropConnections: "dropConnections"
            case .resetAccount: "resetAccount"
            }
        }

        /// A REST fake whose call for this request is held until the test releases it.
        func heldRest() -> FakeRest {
            switch self {
            case .load: FakeRest(labRead: ScriptedCall([.hold]))
            case .apply: FakeRest(labWrite: ScriptedCall([.hold]))
            case .dropConnections: FakeRest(drops: ScriptedCall([.hold]))
            case .resetAccount: FakeRest(resets: ScriptedCall([.hold]))
            }
        }

        /// How many calls of this request wait in `rest`.
        func held(in rest: FakeRest) -> Int {
            switch self {
            case .load: rest.labRead.heldCount
            case .apply: rest.labWrite.heldCount
            case .dropConnections: rest.drops.heldCount
            case .resetAccount: rest.resets.heldCount
            }
        }

        /// Lets the first call of this request end with `error`; false when it was not held.
        func release(in rest: FakeRest, failingWith error: any Error) -> Bool {
            switch self {
            case .load: rest.labRead.release(call: 0, .failure(error))
            case .apply: rest.labWrite.release(call: 0, .failure(error))
            case .dropConnections: rest.drops.release(call: 0, .failure(error))
            case .resetAccount: rest.resets.release(call: 0, .failure(error))
            }
        }

        /// Makes the request on `model`.
        func run(on model: LabViewModel) async {
            switch self {
            case .load: await model.load()
            case .apply: await model.apply(LabPatch(stress: true))
            case .dropConnections: await model.dropConnections()
            case .resetAccount: await model.resetAccount()
            }
        }
    }

    // MARK: Loading the settings

    @Test func loadReadsSettings() async {
        let rest = FakeRest(labRead: ScriptedCall([.value(busyLab)]))
        let rig = LabRig(rest: rest)
        #expect(rig.model.settings == LabSettings())
        #expect(!rig.model.settingsLoaded)

        await rig.model.load()

        #expect(rig.model.settings == busyLab)
        #expect(rig.model.settingsLoaded)
        #expect(rig.model.lastError == nil)
        #expect(rest.labRead.count == 1)
        #expect(rest.labWrite.count == 0)
    }

    @Test func loadFailureSetsErrorAndKeepsDefaults() async {
        let rest = FakeRest(labRead: ScriptedCall([.failure(URLError(.cannotConnectToHost))]))
        let rig = LabRig(rest: rest)

        await rig.model.load()

        #expect(rig.model.settings == LabSettings())
        #expect(!rig.model.settingsLoaded)
        #expect(rig.model.lastError == LabMessages.couldNotReachTheServer)
        #expect(rest.labRead.count == 1)
    }

    @Test func aLaterLoadThatWorksEnablesTheControlsAndClearsTheError() async {
        let rest = FakeRest(labRead: ScriptedCall([.failure(URLError(.timedOut)), .value(busyLab)]))
        let rig = LabRig(rest: rest)
        await rig.model.load()
        let failedFirst = rig.model.lastError
        let loadedAfterFailure = rig.model.settingsLoaded

        await rig.model.load()

        #expect(failedFirst != nil)
        #expect(!loadedAfterFailure)
        #expect(rig.model.settingsLoaded)
        #expect(rig.model.settings == busyLab)
        #expect(rig.model.lastError == nil)
    }

    @Test func aLoadThatFailsAfterOneThatWorkedKeepsWhatTheServerSaid() async {
        let rest = FakeRest(labRead: ScriptedCall([.value(busyLab), .failure(URLError(.timedOut))]))
        let rig = LabRig(rest: rest)
        await rig.model.load()

        await rig.model.load()

        #expect(rig.model.settings == busyLab)
        #expect(rig.model.settingsLoaded)
        #expect(rig.model.lastError == LabMessages.couldNotReachTheServer)
    }

    // MARK: Changing a setting

    @Test func applyPatchUpdatesSettings() async {
        let rest = FakeRest(labWrite: ScriptedCall([.value(calm)]))
        let rig = LabRig(rest: rest)
        let patch = LabPatch(rateMultiplier: 2)

        await rig.model.apply(patch)

        #expect(rig.model.settings == calm)
        #expect(rig.model.settingsLoaded)
        #expect(rig.model.lastError == nil)
        #expect(rest.labWrite.arguments == [patch])
        #expect(rest.labRead.count == 0)
    }

    @Test func answerIsTheClampedValueNotThePatch() async {
        // The server holds a value in its range: it answers 10 and 5,000 to a request of 99 and 9,000.
        let clamped = LabSettings(
            rateMultiplier: 10, stress: false, extraLatencyMs: 5_000, jitterMs: 0, dropUpdates: false
        )
        let rest = FakeRest(labWrite: ScriptedCall([.value(clamped)]))
        let rig = LabRig(rest: rest)

        await rig.model.apply(LabPatch(rateMultiplier: 99, extraLatencyMs: 9_000))

        #expect(rig.model.settings.rateMultiplier == 10)
        #expect(rig.model.settings.extraLatencyMs == 5_000)
        #expect(rig.model.settings == clamped)
    }

    @Test func theWholeAnswerReplacesTheSettingsAndNotOnlyTheFieldsThatWerePatched() async {
        // Somebody else turned the jitter off and the drop on while this app changed the stress.
        let answer = LabSettings(rateMultiplier: 4.5, stress: false, extraLatencyMs: 50, jitterMs: 0, dropUpdates: true)
        let rest = FakeRest(labRead: ScriptedCall([.value(busyLab)]), labWrite: ScriptedCall([.value(answer)]))
        let rig = LabRig(rest: rest)
        await rig.model.load()

        await rig.model.apply(LabPatch(stress: false))

        #expect(rig.model.settings == answer)
        #expect(rig.model.settings.jitterMs == 0)
    }

    @Test func failedApplyKeepsSettingsAndReportsIt() async {
        let rest = FakeRest(
            labRead: ScriptedCall([.value(busyLab)]),
            labWrite: ScriptedCall([.failure(URLError(.cannotConnectToHost))])
        )
        let rig = LabRig(rest: rest)
        await rig.model.load()

        await rig.model.apply(LabPatch(stress: false))

        #expect(rig.model.settings == busyLab)
        #expect(rig.model.settingsLoaded)
        #expect(rig.model.lastError == LabMessages.couldNotChangeTheSetting)
        #expect(rest.labWrite.count == 1)
    }

    // MARK: Answers that come in the wrong order

    @Test func olderAnswerDoesNotOverwriteNewer() async {
        let rest = FakeRest(labWrite: ScriptedCall([.hold, .hold]))
        let rig = LabRig(rest: rest)
        let first = Task { @MainActor in await rig.model.apply(LabPatch(rateMultiplier: 2)) }
        await waitFor("the first request is in flight") { rest.labWrite.heldCount == 1 }
        let second = Task { @MainActor in await rig.model.apply(LabPatch(rateMultiplier: 3)) }
        await waitFor("both requests are in flight") { rest.labWrite.heldCount == 2 }

        let releasedNewer = rest.labWrite.release(call: 1, .success(other))
        await second.value
        let afterNewer = rig.model.settings
        let releasedOlder = rest.labWrite.release(call: 0, .success(calm))
        await first.value

        #expect(releasedNewer)
        #expect(releasedOlder)
        #expect(afterNewer == other)
        #expect(rig.model.settings == other)
        #expect(rig.model.lastError == nil)
    }

    @Test func anOlderAnswerThatArrivesFirstChangesNothingAndTheNewerOneStands() async {
        let rest = FakeRest(labWrite: ScriptedCall([.hold, .hold]))
        let rig = LabRig(rest: rest)
        let first = Task { @MainActor in await rig.model.apply(LabPatch(rateMultiplier: 2)) }
        await waitFor("the first request is in flight") { rest.labWrite.heldCount == 1 }
        let second = Task { @MainActor in await rig.model.apply(LabPatch(rateMultiplier: 3)) }
        await waitFor("both requests are in flight") { rest.labWrite.heldCount == 2 }

        let releasedOlder = rest.labWrite.release(call: 0, .success(calm))
        await first.value
        let afterOlder = rig.model.settings
        let loadedAfterOlder = rig.model.settingsLoaded
        let releasedNewer = rest.labWrite.release(call: 1, .success(other))
        await second.value

        #expect(releasedOlder)
        #expect(releasedNewer)
        #expect(afterOlder == LabSettings())
        #expect(!loadedAfterOlder)
        #expect(rig.model.settings == other)
        #expect(rig.model.settingsLoaded)
    }

    @Test func anOlderFailureThatArrivesLastIsNotShown() async {
        let rest = FakeRest(labWrite: ScriptedCall([.hold, .hold]))
        let rig = LabRig(rest: rest)
        let first = Task { @MainActor in await rig.model.apply(LabPatch(rateMultiplier: 2)) }
        await waitFor("the first request is in flight") { rest.labWrite.heldCount == 1 }
        let second = Task { @MainActor in await rig.model.apply(LabPatch(rateMultiplier: 3)) }
        await waitFor("both requests are in flight") { rest.labWrite.heldCount == 2 }

        let releasedNewer = rest.labWrite.release(call: 1, .success(other))
        await second.value
        let releasedOlder = rest.labWrite.release(call: 0, .failure(URLError(.timedOut)))
        await first.value

        #expect(releasedNewer)
        #expect(releasedOlder)
        #expect(rig.model.settings == other)
        #expect(rig.model.lastError == nil)
    }

    @Test func anOlderSuccessThatArrivesLastDoesNotClearTheNewerFailure() async {
        let rest = FakeRest(labWrite: ScriptedCall([.hold, .hold]))
        let rig = LabRig(rest: rest)
        let first = Task { @MainActor in await rig.model.apply(LabPatch(rateMultiplier: 2)) }
        await waitFor("the first request is in flight") { rest.labWrite.heldCount == 1 }
        let second = Task { @MainActor in await rig.model.apply(LabPatch(rateMultiplier: 3)) }
        await waitFor("both requests are in flight") { rest.labWrite.heldCount == 2 }

        let releasedNewer = rest.labWrite.release(call: 1, .failure(URLError(.timedOut)))
        await second.value
        let releasedOlder = rest.labWrite.release(call: 0, .success(calm))
        await first.value

        #expect(releasedNewer)
        #expect(releasedOlder)
        #expect(rig.model.lastError == LabMessages.couldNotChangeTheSetting)
        #expect(rig.model.settings == LabSettings())
    }

    @Test func aLoadAndAnApplyAreOrderedByWhenTheyStartedWhicheverIsAnsweredFirst() async {
        // The load starts first and is answered last: the apply that started after it is the newer.
        let restA = FakeRest(labRead: ScriptedCall([.hold]), labWrite: ScriptedCall([.value(other)]))
        let rigA = LabRig(rest: restA)
        let load = Task { @MainActor in await rigA.model.load() }
        await waitFor("the load is in flight") { restA.labRead.heldCount == 1 }
        await rigA.model.apply(LabPatch(stress: true))
        let releasedLoad = restA.labRead.release(call: 0, .success(busyLab))
        await load.value

        // The apply starts first and is answered last: the load that started after it is the newer.
        let restB = FakeRest(labRead: ScriptedCall([.value(busyLab)]), labWrite: ScriptedCall([.hold]))
        let rigB = LabRig(rest: restB)
        let apply = Task { @MainActor in await rigB.model.apply(LabPatch(stress: true)) }
        await waitFor("the apply is in flight") { restB.labWrite.heldCount == 1 }
        await rigB.model.load()
        let releasedApply = restB.labWrite.release(call: 0, .success(other))
        await apply.value

        #expect(releasedLoad)
        #expect(rigA.model.settings == other)
        #expect(releasedApply)
        #expect(rigB.model.settings == busyLab)
    }

    // MARK: Asking without waiting

    @Test func askReturnsAtOnceAndTheTaskItReturnsBringsTheAnswer() async {
        let rest = FakeRest(labWrite: ScriptedCall([.hold]))
        let rig = LabRig(rest: rest)
        let patch = LabPatch(stress: true)

        let waiting = rig.model.ask(patch)
        await waitFor("the request is in flight") { rest.labWrite.heldCount == 1 }
        let whileWaiting = rig.model.settings
        let loadedWhileWaiting = rig.model.settingsLoaded
        let released = rest.labWrite.release(call: 0, .success(other))
        await waiting.value

        #expect(whileWaiting == LabSettings(), "the settings are what the server answered, and it has not")
        #expect(!loadedWhileWaiting)
        #expect(released)
        #expect(rest.labWrite.arguments == [patch])
        #expect(rig.model.settings == other)
        #expect(rig.model.settingsLoaded)
    }

    // MARK: What the controls take back

    @Test func everyRequestForTheSettingsThatEndsIsCountedWhateverItBrought() async {
        let rest = FakeRest(
            labRead: ScriptedCall([.value(busyLab)]),
            labWrite: ScriptedCall([.value(calm), .failure(URLError(.timedOut))])
        )
        let rig = LabRig(rest: rest)
        var counts = [rig.model.settingsRevision]

        await rig.model.load()
        counts.append(rig.model.settingsRevision)
        await rig.model.apply(LabPatch(rateMultiplier: 2))
        counts.append(rig.model.settingsRevision)
        await rig.model.apply(LabPatch(rateMultiplier: 3))
        counts.append(rig.model.settingsRevision)

        #expect(counts == [0, 1, 2, 3], "before anything, after a read, after a change and after one that failed")
        #expect(rig.model.settings == calm, "the change that failed left the settings as they were")
        #expect(rig.model.lastError == LabMessages.couldNotChangeTheSetting)
    }

    @Test(arguments: [false, true])
    func aRequestThatWasOvertakenIsNotCountedWhetherItFailedOrNot(failing: Bool) async {
        let rest = FakeRest(labWrite: ScriptedCall([.hold, .hold]))
        let rig = LabRig(rest: rest)
        let first = Task { @MainActor in await rig.model.apply(LabPatch(rateMultiplier: 2)) }
        await waitFor("the first request is in flight") { rest.labWrite.heldCount == 1 }
        let second = Task { @MainActor in await rig.model.apply(LabPatch(rateMultiplier: 3)) }
        await waitFor("both requests are in flight") { rest.labWrite.heldCount == 2 }
        let olderAnswer: Result<LabSettings, any Error> = failing ? .failure(URLError(.timedOut)) : .success(calm)

        let releasedOlder = rest.labWrite.release(call: 0, olderAnswer)
        await first.value
        let afterTheOlder = rig.model.settingsRevision
        let releasedNewer = rest.labWrite.release(call: 1, .success(other))
        await second.value

        #expect(releasedOlder)
        #expect(releasedNewer)
        #expect(afterTheOlder == 0, "the older answer was dropped, so no request has ended")
        #expect(rig.model.settingsRevision == 1, "the newer answer ended the request that counts")
    }

    @Test func aCancelledRequestIsNotCountedButTheNextOneIs() async {
        let rest = FakeRest(labWrite: ScriptedCall([.hold, .value(calm)]))
        let rig = LabRig(rest: rest)
        let task = Task { @MainActor in await rig.model.apply(LabPatch(stress: true)) }
        await waitFor("the request is in flight") { rest.labWrite.heldCount == 1 }

        task.cancel()
        let released = rest.labWrite.release(call: 0, .failure(CancellationError()))
        await task.value
        let afterTheCancelled = rig.model.settingsRevision
        await rig.model.apply(LabPatch(rateMultiplier: 2))

        #expect(released)
        #expect(afterTheCancelled == 0)
        #expect(rig.model.settingsRevision == 1, "the control: a request that was not cancelled is counted")
    }

    // MARK: Dropping the connections and resetting the account

    @Test func dropConnectionsCallsRest() async {
        let rest = FakeRest(drops: ScriptedCall([.value(())]))
        let rig = LabRig(rest: rest)

        await rig.model.dropConnections()

        #expect(rest.drops.count == 1)
        #expect(rest.resets.count == 0)
        #expect(rig.model.lastError == nil)
        #expect(rig.model.settings == LabSettings())
    }

    @Test func dropFailureIsReported() async {
        let rest = FakeRest(drops: ScriptedCall([.failure(URLError(.cannotConnectToHost))]))
        let rig = LabRig(rest: rest)

        await rig.model.dropConnections()

        #expect(rest.drops.count == 1)
        #expect(rig.model.lastError == LabMessages.couldNotDropTheConnections)
    }

    @Test func resetAccountCallsResetServer() async {
        let rest = FakeRest(resets: ScriptedCall([.value("E2")]))
        let rig = LabRig(rest: rest)

        await rig.model.resetAccount()

        #expect(rest.resets.count == 1)
        #expect(rest.drops.count == 0)
        #expect(rig.model.lastError == nil)
    }

    @Test func resettingTheAccountDoesNothingButAskTheServer() async {
        // The app's own clients notice the new epoch on their own: the model neither reads the account nor changes what
        // it shows.
        let rest = FakeRest(resets: ScriptedCall([.value("E2")]))
        let rig = LabRig(rest: rest)

        await rig.model.resetAccount()

        #expect(rest.resets.count == 1, "the control: the server was asked to start over")
        #expect(rest.accountCalls == 0)
        #expect(rest.labRead.count == 0)
        #expect(rest.labWrite.count == 0)
        #expect(rig.model.reconciliation == .inFlight)
        #expect(rig.model.settings == LabSettings())
        #expect(!rig.model.settingsLoaded)
    }

    @Test func resetFailureIsReported() async {
        let rest = FakeRest(resets: ScriptedCall([.failure(URLError(.cannotConnectToHost))]))
        let rig = LabRig(rest: rest)

        await rig.model.resetAccount()

        #expect(rig.model.lastError == LabMessages.couldNotResetTheAccount)
    }

    // MARK: Starting the statistics over

    @Test func resetStatsClearsRecorder() {
        let rig = LabRig()
        rig.latency.record(.tickToApp, nanos: 1_000_000)
        rig.latency.record(.tickToRender, nanos: 2_000_000)
        rig.latency.record(.orderSubmitToAck, nanos: 3_000_000)
        // The first frame has no interval. A frame 100 ms after it is a hitch, and the chart reports what it took to
        // draw.
        rig.pumpRig.step(at: 10)
        rig.pumpRig.step(at: 10.1)
        rig.pump.notifyRendered(drawNs: 4_000_000)
        let recorded = rig.latency.snapshot().values.filter { $0.count > 0 }.count
        let counted = (rig.pump.frames, rig.pump.hitches, rig.pump.drawCost.count)

        rig.model.resetStats()

        let snapshot = rig.latency.snapshot()
        #expect(recorded == 3)
        #expect(counted.0 == 1 && counted.1 == 1 && counted.2 == 1)
        #expect(snapshot.count == 6)
        #expect(snapshot.values.allSatisfy { $0.count == 0 })
        #expect(rig.pump.frames == 0)
        #expect(rig.pump.hitches == 0)
        #expect(rig.pump.drawCost.count == 0)
    }

    // MARK: The line under the controls

    @Test func successClearsTheError() async {
        /// A name, a server whose first drop fails, and the request that succeeds afterwards.
        typealias Recovery = (name: String, rest: FakeRest, request: @MainActor (LabViewModel) async -> Void)
        let timedOut = ScriptedCall<Void, Void>.Answer.failure(URLError(.timedOut))
        let recoveries: [Recovery] = [
            ("a drop", FakeRest(drops: ScriptedCall([timedOut, .value(())])), { await $0.dropConnections() }),
            ("a reset", FakeRest(drops: ScriptedCall([timedOut]), resets: ScriptedCall([.value("E2")])), {
                await $0.resetAccount()
            }),
            ("a change", FakeRest(labWrite: ScriptedCall([.value(calm)]), drops: ScriptedCall([timedOut])), {
                await $0.apply(LabPatch(rateMultiplier: 2))
            }),
        ]
        #expect(recoveries.count == 3)

        for recovery in recoveries {
            let rig = LabRig(rest: recovery.rest)
            await rig.model.dropConnections()
            let shownAfterFailure = rig.model.lastError

            await recovery.request(rig.model)

            #expect(shownAfterFailure == LabMessages.couldNotDropTheConnections, "before \(recovery.name)")
            #expect(rig.model.lastError == nil, "after \(recovery.name)")
        }
    }

    // MARK: Cancelling

    @Test(arguments: Request.allCases)
    func aCancelledRequestIsNeverShownAsAnError(request: Request) async {
        let errors: [any Error] = [CancellationError(), URLError(.cancelled)]
        for error in errors {
            let rest = request.heldRest()
            let rig = LabRig(rest: rest)
            let task = Task { @MainActor in await request.run(on: rig.model) }
            await waitFor("the \(request.testDescription) request is in flight") { request.held(in: rest) == 1 }

            task.cancel()
            let released = request.release(in: rest, failingWith: error)
            await task.value

            #expect(released, "\(request.testDescription) was held")
            #expect(rig.model.lastError == nil, "\(request.testDescription) after \(error)")
            #expect(!rig.model.settingsLoaded)
        }
    }

    @Test(arguments: Request.allCases)
    func theSameFailureOfARequestThatWasNotCancelledIsShown(request: Request) async {
        let rest = request.heldRest()
        let rig = LabRig(rest: rest)
        let task = Task { @MainActor in await request.run(on: rig.model) }
        await waitFor("the \(request.testDescription) request is in flight") { request.held(in: rest) == 1 }

        let released = request.release(in: rest, failingWith: URLError(.cannotConnectToHost))
        await task.value

        #expect(released)
        #expect(rig.model.lastError != nil, "\(request.testDescription)")
    }
}

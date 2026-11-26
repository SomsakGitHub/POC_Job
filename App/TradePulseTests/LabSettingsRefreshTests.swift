import Contracts
import Foundation
import Observation
import Testing
import TradeNetworking
@testable import TradePulse

/// How the Lab keeps the settings it shows in step with the server: the loop reads them every round, an answer that
/// is the same changes nothing the screen can see, a read that fails says nothing unless the controls are still
/// waiting for the first answer, and a read never takes away what a change brought, in whatever order they overlap.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LabSettingsRefreshTests {
    /// Settings that differ from `busyLab` and from the defaults in every field.
    private let calm = LabSettings(rateMultiplier: 2, stress: false, extraLatencyMs: 0, jitterMs: 0, dropUpdates: false)
    /// Settings that differ from `calm`, from `busyLab` and from the defaults in every field.
    private let other = LabSettings(
        rateMultiplier: 3, stress: true, extraLatencyMs: 200, jitterMs: 20, dropUpdates: false
    )
    /// What a server that is not answering does.
    private let timedOut = URLError(.timedOut)

    /// A read of the settings: the one the user asks for with "Try again", or the one the loop makes every round.
    enum Read: CaseIterable, CustomTestStringConvertible, Sendable {
        case load, refresh

        var testDescription: String {
            switch self {
            case .load: "load"
            case .refresh: "refresh"
            }
        }

        /// Makes the read on `model`.
        func run(on model: LabViewModel) async {
            switch self {
            case .load: await model.load()
            case .refresh: await model.refreshSettings()
            }
        }
    }

    /// What the controls would read, each watched for a change since the watch was made.
    @MainActor
    private struct Watch {
        let settings = Flag()
        let loaded = Flag()
        let error = Flag()
        let revision = Flag()

        /// Starts watching `model`.
        init(_ model: LabViewModel) {
            let flags = (settings: settings, loaded: loaded, error: error, revision: revision)
            withObservationTracking { _ = model.settings } onChange: { flags.settings.set() }
            withObservationTracking { _ = model.settingsLoaded } onChange: { flags.loaded.set() }
            withObservationTracking { _ = model.lastError } onChange: { flags.error.set() }
            withObservationTracking { _ = model.settingsRevision } onChange: { flags.revision.set() }
        }

        /// Whether any of the four changed.
        var anyChanged: Bool { settings.isSet || loaded.isSet || error.isSet || revision.isSet }
    }

    /// A read and a change that are both on their way to a server that answers neither until the test says so.
    @MainActor
    private struct Overlap {
        let rig: LabRig
        let change: Task<Void, Never>
        let reading: Task<Void, Never>

        /// Lets the read end with `settings` and waits for it to be over.
        func answerTheRead(with settings: LabSettings) async {
            rig.rest.labRead.release(call: 0, .success(settings))
            await reading.value
        }

        /// Lets the change end with `settings` and waits for it to be over.
        func answerTheChange(with settings: LabSettings) async {
            rig.rest.labWrite.release(call: 0, .success(settings))
            await change.value
        }
    }

    /// Starts a change and a read, the change first when `changeStartedFirst`, and waits until both are on their way.
    private func startOverlap(_ read: Read, changeStartedFirst: Bool) async -> Overlap {
        let rig = LabRig(rest: FakeRest(labRead: ScriptedCall([.hold]), labWrite: ScriptedCall([.hold])))
        let rest = rig.rest
        func startTheChange() async -> Task<Void, Never> {
            let task = Task { @MainActor in await rig.model.apply(LabPatch(stress: true)) }
            await waitFor("the change is on its way") { rest.labWrite.heldCount == 1 }
            return task
        }
        func startTheRead() async -> Task<Void, Never> {
            let task = Task { @MainActor in await read.run(on: rig.model) }
            await waitFor("the read is on its way") { rest.labRead.heldCount == 1 }
            return task
        }
        if changeStartedFirst {
            let change = await startTheChange()
            let reading = await startTheRead()
            return Overlap(rig: rig, change: change, reading: reading)
        }
        let reading = await startTheRead()
        let change = await startTheChange()
        return Overlap(rig: rig, change: change, reading: reading)
    }

    // MARK: What a read brings

    @Test func aRefreshTakesTheSettingsTheServerHoldsAndEnablesTheControls() async {
        let rest = FakeRest(labRead: ScriptedCall([.value(busyLab)]))
        let rig = LabRig(rest: rest)

        await rig.model.refreshSettings()

        #expect(rig.model.settings == busyLab)
        #expect(rig.model.settingsLoaded)
        #expect(rig.model.lastError == nil)
        #expect(rig.model.settingsRevision == 1)
        #expect(rest.labRead.count == 1)
        #expect(rest.labWrite.count == 0)
    }

    @Test func aServerThatHoldsTheDefaultsStillEnablesTheControls() async {
        // The defaults are what the model starts with, so the answer is no change; it is the first answer all the same.
        let rest = FakeRest(labRead: ScriptedCall([.value(LabSettings())]))
        let rig = LabRig(rest: rest)
        let watch = Watch(rig.model)

        await rig.model.refreshSettings()

        #expect(rig.model.settings == LabSettings())
        #expect(rig.model.settingsLoaded)
        #expect(rig.model.settingsRevision == 1)
        #expect(watch.loaded.isSet)
        #expect(watch.revision.isSet)
    }

    @Test func aRoundAfterTheServerStartedOverShowsTheSettingsItHoldsNow() async {
        // A server that started over holds the defaults: 1x, no stress, no delay, no jitter, nothing dropped.
        let rest = FakeRest(labRead: ScriptedCall([.value(busyLab), .value(LabSettings())]))
        let rig = LabRig(rest: rest)
        await rig.model.refreshSettings()
        let revisionBefore = rig.model.settingsRevision
        let watch = Watch(rig.model)

        await rig.model.refreshSettings()

        #expect(revisionBefore == 1)
        #expect(rig.model.settings == LabSettings())
        #expect(rig.model.settingsLoaded)
        #expect(rig.model.settingsRevision == 2)
        #expect(watch.settings.isSet)
        #expect(watch.revision.isSet)
    }

    @Test func aRoundFollowsAChangeMadeFromOutside() async {
        let rest = FakeRest(labRead: ScriptedCall([.value(calm), .value(other)]))
        let rig = LabRig(rest: rest)
        await rig.model.refreshSettings()

        await rig.model.refreshSettings()

        #expect(rig.model.settings == other)
        #expect(rig.model.settingsRevision == 2)
        #expect(rest.labWrite.count == 0, "the app only looked")
    }

    @Test func aRoundThatFindsNothingNewChangesNothingTheScreenCanSee() async {
        let rest = FakeRest(labRead: ScriptedCall([.value(busyLab), .value(busyLab), .value(other)]))
        let rig = LabRig(rest: rest)
        await rig.model.refreshSettings()

        let quiet = Watch(rig.model)
        await rig.model.refreshSettings()
        let quietAfterTheSame = !quiet.anyChanged
        let revisionAfterTheSame = rig.model.settingsRevision

        // The control: a round that finds other settings is told.
        let loud = Watch(rig.model)
        await rig.model.refreshSettings()

        #expect(rest.labRead.count == 3, "the rounds did ask")
        #expect(quietAfterTheSame, "the same settings again")
        #expect(revisionAfterTheSame == 1)
        #expect(loud.settings.isSet)
        #expect(loud.revision.isSet)
        #expect(!loud.loaded.isSet, "they were loaded already")
        #expect(!loud.error.isSet)
        #expect(rig.model.settings == other)
    }

    @Test func aRequestTheUserAskedForIsCountedAndToldWhenTheAnswerIsWhatWasShown() async {
        // The slider may be ahead of the server while a request is on its way: it looks at the settings again when the
        // request ends, whatever the request brought, so a request whose answer is what was shown is told as well.
        let rest = FakeRest(
            labRead: ScriptedCall([.value(busyLab), .value(busyLab)]), labWrite: ScriptedCall([.value(busyLab)])
        )
        let rig = LabRig(rest: rest)
        await rig.model.load()
        let afterTheFirstRead = rig.model.settingsRevision

        let afterAChange = Watch(rig.model)
        await rig.model.apply(LabPatch(stress: true))
        let revisionAfterAChange = rig.model.settingsRevision
        let afterARead = Watch(rig.model)
        await rig.model.load()

        #expect(afterTheFirstRead == 1)
        #expect(rest.labWrite.count == 1)
        #expect(revisionAfterAChange == 2)
        #expect(afterAChange.revision.isSet, "the change ended with the same settings, and the slider is told")
        #expect(!afterAChange.settings.isSet, "the settings are the same")
        #expect(rig.model.settingsRevision == 3)
        #expect(afterARead.revision.isSet, "a read that the user asked for is told as well")
        #expect(rig.model.settings == busyLab)
    }

    // MARK: What a read says

    @Test func aRoundThatWorksNeverTakesAwayTheLineOfARequestThatFailed() async {
        /// A request that fails, the server it fails on (which answers the settings), and the line it leaves.
        struct Failure {
            let name: String
            let rest: FakeRest
            let request: @MainActor (LabViewModel) async -> Void
            let line: String
        }
        let settings = ScriptedCall<Void, LabSettings>.Answer.value(busyLab)
        let failures: [Failure] = [
            Failure(
                name: "a change",
                rest: FakeRest(labRead: ScriptedCall([settings]), labWrite: ScriptedCall([.failure(timedOut)])),
                request: { await $0.apply(LabPatch(stress: true)) }, line: LabMessages.couldNotChangeTheSetting
            ),
            Failure(
                name: "a drop",
                rest: FakeRest(labRead: ScriptedCall([settings]), drops: ScriptedCall([.failure(timedOut)])),
                request: { await $0.dropConnections() }, line: LabMessages.couldNotDropTheConnections
            ),
            Failure(
                name: "a reset",
                rest: FakeRest(labRead: ScriptedCall([settings]), resets: ScriptedCall([.failure(timedOut)])),
                request: { await $0.resetAccount() }, line: LabMessages.couldNotResetTheAccount
            ),
        ]
        #expect(failures.count == 3)

        for failure in failures {
            let rig = LabRig(rest: failure.rest)
            await failure.request(rig.model)
            let lineBefore = rig.model.lastError

            await rig.model.refreshSettings()

            #expect(lineBefore == failure.line, "after \(failure.name)")
            #expect(rig.model.lastError == failure.line, "after \(failure.name) and a round that worked")
            #expect(rig.model.settings == busyLab, "the round did bring the settings, after \(failure.name)")
        }
    }

    @Test func theLineOfAFailedChangeStaysThroughARoundAndGoesWhenAChangeWorks() async {
        let rest = FakeRest(
            labRead: ScriptedCall([.value(busyLab), .value(busyLab)]),
            labWrite: ScriptedCall([.failure(timedOut), .value(calm)])
        )
        let rig = LabRig(rest: rest)
        await rig.model.refreshSettings()
        await rig.model.apply(LabPatch(rateMultiplier: 2))
        let afterTheFailure = rig.model.lastError

        await rig.model.refreshSettings()
        let afterTheRound = rig.model.lastError
        await rig.model.apply(LabPatch(rateMultiplier: 2))

        #expect(afterTheFailure == LabMessages.couldNotChangeTheSetting)
        #expect(afterTheRound == LabMessages.couldNotChangeTheSetting)
        #expect(rig.model.lastError == nil)
    }

    @Test func aRoundThatFailsWhileTheSettingsAreLoadedSaysNothing() async {
        let rest = FakeRest(labRead: ScriptedCall([.value(busyLab), .failure(timedOut)]))
        let rig = LabRig(rest: rest)
        await rig.model.refreshSettings()
        let watch = Watch(rig.model)

        await rig.model.refreshSettings()

        #expect(rest.labRead.count == 2, "the control: the round did ask")
        #expect(!watch.anyChanged)
        #expect(rig.model.lastError == nil)
        #expect(rig.model.settings == busyLab)
        #expect(rig.model.settingsRevision == 1)
    }

    @Test func aRoundThatFailsDoesNotReplaceTheLineOfARequestThatFailed() async {
        let rest = FakeRest(
            labRead: ScriptedCall([.value(busyLab), .failure(timedOut)]), drops: ScriptedCall([.failure(timedOut)])
        )
        let rig = LabRig(rest: rest)
        await rig.model.refreshSettings()
        await rig.model.dropConnections()

        await rig.model.refreshSettings()

        #expect(rest.labRead.count == 2, "the control: the round did ask")
        #expect(rig.model.lastError == LabMessages.couldNotDropTheConnections)
    }

    @Test func aRoundThatFailsBeforeTheSettingsWereEverReadMakesTheControlsSayTheyAreUnavailable() async {
        let rest = FakeRest(labRead: ScriptedCall([.failure(timedOut), .failure(timedOut), .failure(timedOut)]))
        let rig = LabRig(rest: rest)

        await rig.model.refreshSettings()
        let afterTheFirst = (rig.model.lastError, rig.model.settingsLoaded)
        let watch = Watch(rig.model)
        await rig.model.refreshSettings()
        await rig.model.refreshSettings()

        #expect(afterTheFirst.0 == LabMessages.couldNotReachTheServer)
        #expect(!afterTheFirst.1)
        #expect(!watch.anyChanged, "the unavailable state stays as it is while the server stays away")
        #expect(rig.model.lastError == LabMessages.couldNotReachTheServer)
        #expect(!rig.model.settingsLoaded)
        #expect(rig.model.settings == LabSettings())
        #expect(rig.model.settingsRevision == 0)
        #expect(rest.labRead.count == 3)
    }

    @Test func aRoundThatFailsBeforeAnythingWasReadKeepsTheLineOfAChangeThatFailed() async {
        let rest = FakeRest(labRead: ScriptedCall([.failure(timedOut)]), labWrite: ScriptedCall([.failure(timedOut)]))
        let rig = LabRig(rest: rest)
        await rig.model.apply(LabPatch(stress: true))

        await rig.model.refreshSettings()

        #expect(rest.labRead.count == 1, "the control: the round did ask")
        #expect(rig.model.lastError == LabMessages.couldNotChangeTheSetting)
        #expect(!rig.model.settingsLoaded)
    }

    @Test func theControlsComeAliveByThemselvesWhenTheServerAnswersLater() async {
        let rest = FakeRest(labRead: ScriptedCall([.failure(timedOut), .failure(timedOut), .value(busyLab)]))
        let rig = LabRig(rest: rest)
        await rig.model.refreshSettings()
        await rig.model.refreshSettings()
        let whileItIsAway = (rig.model.settingsLoaded, rig.model.lastError)

        await rig.model.refreshSettings()

        #expect(whileItIsAway.0 == false)
        #expect(whileItIsAway.1 == LabMessages.couldNotReachTheServer)
        #expect(rig.model.settingsLoaded)
        #expect(rig.model.settings == busyLab)
        #expect(rig.model.lastError == nil, "the line that said the server could not be reached is gone")
        #expect(rig.model.settingsRevision == 1)
    }

    @Test func aRoundThatWorksTakesAwayTheLineOfAReadThatFailedAndNothingElse() async {
        let rest = FakeRest(labRead: ScriptedCall([.value(busyLab), .failure(timedOut), .value(busyLab)]))
        let rig = LabRig(rest: rest)
        await rig.model.load()
        await rig.model.load()
        let afterTheFailure = rig.model.lastError
        let revisionAfterTheFailure = rig.model.settingsRevision
        let watch = Watch(rig.model)

        await rig.model.refreshSettings()

        #expect(afterTheFailure == LabMessages.couldNotReachTheServer)
        #expect(revisionAfterTheFailure == 2)
        #expect(rig.model.lastError == nil)
        #expect(watch.error.isSet)
        #expect(!watch.settings.isSet)
        #expect(!watch.revision.isSet, "the settings are the ones on show, so nothing moves with them")
        #expect(rig.model.settingsRevision == 2)
    }

    @Test func aRoundThatWasCancelledChangesNothingAndTheNextOneWorks() async {
        let errors: [any Error] = [CancellationError(), URLError(.cancelled)]
        for error in errors {
            let rest = FakeRest(labRead: ScriptedCall([.hold, .value(busyLab)]))
            let rig = LabRig(rest: rest)
            let round = Task { @MainActor in await rig.model.refreshSettings() }
            await waitFor("the read is on its way") { rest.labRead.heldCount == 1 }
            let watch = Watch(rig.model)

            round.cancel()
            let released = rest.labRead.release(call: 0, .failure(error))
            await round.value
            let nothingChanged = !watch.anyChanged
            await rig.model.refreshSettings()

            #expect(released, "\(error)")
            #expect(nothingChanged, "\(error)")
            #expect(rig.model.settingsRevision == 1, "the control: the round that was not cancelled counts, \(error)")
            #expect(rig.model.settings == busyLab, "\(error)")
            #expect(rig.model.lastError == nil, "\(error)")
        }
    }

    // MARK: Reads and changes that overlap

    @Test(arguments: Read.allCases, [true, false])
    func aReadThatOverlapsAChangeIsDroppedWhenItIsAnsweredFirst(read: Read, changeStartedFirst: Bool) async {
        let both = await startOverlap(read, changeStartedFirst: changeStartedFirst)
        let model = both.rig.model

        await both.answerTheRead(with: calm)
        let afterTheRead = (model.settings, model.settingsLoaded, model.settingsRevision, model.lastError)
        await both.answerTheChange(with: other)

        #expect(afterTheRead.0 == LabSettings(), "the read may have been answered before the change took effect")
        #expect(!afterTheRead.1)
        #expect(afterTheRead.2 == 0)
        #expect(afterTheRead.3 == nil)
        #expect(model.settings == other)
        #expect(model.settingsLoaded)
        #expect(model.settingsRevision == 1)
        #expect(model.lastError == nil)
    }

    @Test(arguments: Read.allCases, [true, false])
    func aReadThatOverlapsAChangeIsDroppedWhenItIsAnsweredLast(read: Read, changeStartedFirst: Bool) async {
        let both = await startOverlap(read, changeStartedFirst: changeStartedFirst)
        let model = both.rig.model

        await both.answerTheChange(with: other)
        let afterTheChange = (model.settings, model.settingsRevision)
        await both.answerTheRead(with: calm)

        #expect(afterTheChange.0 == other, "the change counts, although a read started after it")
        #expect(afterTheChange.1 == 1)
        #expect(model.settings == other, "the read is older than the change, so it brings nothing")
        #expect(model.settingsRevision == 1)
        #expect(model.lastError == nil)
    }

    @Test(arguments: Read.allCases, [true, false])
    func aReadThatFailsWhileAChangeOverlapsItSaysNothing(read: Read, changeStartedFirst: Bool) async {
        let both = await startOverlap(read, changeStartedFirst: changeStartedFirst)
        let model = both.rig.model

        let released = both.rig.rest.labRead.release(call: 0, .failure(timedOut))
        await both.reading.value
        let lineAfterTheRead = model.lastError
        let revisionAfterTheRead = model.settingsRevision
        await both.answerTheChange(with: other)

        #expect(released)
        #expect(lineAfterTheRead == nil, "no line for a read that was dropped, whether or not the settings are loaded")
        #expect(revisionAfterTheRead == 0)
        #expect(model.settings == other)
        #expect(model.lastError == nil)
    }

    @Test(arguments: Read.allCases, [true, false])
    func aChangeThatFailsWhileAReadOverlapsItIsShownAndTheReadIsDropped(read: Read, changeStartedFirst: Bool) async {
        let both = await startOverlap(read, changeStartedFirst: changeStartedFirst)
        let model = both.rig.model

        let released = both.rig.rest.labWrite.release(call: 0, .failure(timedOut))
        await both.change.value
        await both.answerTheRead(with: calm)

        #expect(released)
        #expect(model.lastError == LabMessages.couldNotChangeTheSetting)
        #expect(model.settings == LabSettings())
        #expect(!model.settingsLoaded)
        #expect(model.settingsRevision == 1, "the failed change is counted and the read that was dropped is not")
    }

    @Test(arguments: Read.allCases)
    func aReadThatIsCancelledNeverTakesTheAnswerOfAChangeAway(read: Read) async {
        let both = await startOverlap(read, changeStartedFirst: true)
        let model = both.rig.model

        both.reading.cancel()
        let released = both.rig.rest.labRead.release(call: 0, .failure(CancellationError()))
        await both.reading.value
        let afterTheCancelledRead = (model.settingsRevision, model.lastError)
        await both.answerTheChange(with: other)

        #expect(released)
        #expect(afterTheCancelledRead.0 == 0)
        #expect(afterTheCancelledRead.1 == nil)
        #expect(model.settings == other, "the screen shows what the change brought")
        #expect(model.settingsRevision == 1)
    }

    @Test(arguments: [true, false])
    func ofTwoReadsTheNewerOneStandsWhicheverIsAnsweredFirst(newerAnswersFirst: Bool) async {
        let rest = FakeRest(labRead: ScriptedCall([.hold, .hold]))
        let rig = LabRig(rest: rest)
        let olderTask = Task { @MainActor in await rig.model.load() }
        await waitFor("the first read is on its way") { rest.labRead.heldCount == 1 }
        let newerTask = Task { @MainActor in await rig.model.refreshSettings() }
        await waitFor("both reads are on their way") { rest.labRead.heldCount == 2 }
        let older = (call: 0, answer: calm, task: olderTask)
        let newer = (call: 1, answer: other, task: newerTask)
        let (first, second) = newerAnswersFirst ? (newer, older) : (older, newer)

        rest.labRead.release(call: first.call, .success(first.answer))
        await first.task.value
        let afterTheFirst = (rig.model.settings, rig.model.settingsRevision)
        rest.labRead.release(call: second.call, .success(second.answer))
        await second.task.value

        #expect(afterTheFirst.0 == (newerAnswersFirst ? other : LabSettings()))
        #expect(afterTheFirst.1 == (newerAnswersFirst ? 1 : 0))
        #expect(rig.model.settings == other)
        #expect(rig.model.settingsRevision == 1, "the read that was overtaken is not counted")
    }

    @Test func aReadThatStartedAfterAChangeEndedCounts() async {
        let rest = FakeRest(labRead: ScriptedCall([.value(other)]), labWrite: ScriptedCall([.value(calm)]))
        let rig = LabRig(rest: rest)
        await rig.model.apply(LabPatch(rateMultiplier: 2))

        await rig.model.refreshSettings()

        #expect(rig.model.settings == other, "the read answers what the server holds after the change")
        #expect(rig.model.settingsRevision == 2)
    }
}

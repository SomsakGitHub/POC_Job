import Contracts
import Foundation
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// What the Lab looks at while it is open: the loop that probes the REST API, reads the settings and checks the account
/// every five seconds, the round trip the probe measures, and the comparison of the app's account with the server's.
/// Nothing here waits for time to pass: the loop's wait is a double that records what it was asked for.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LabMonitorTests {
    // MARK: The loop

    @Test func theLoopLooksBeforeItWaitsAndThenWaitsFiveSecondsEveryTime() async {
        let log = EventLog()
        let rest = FakeRest(
            accounts: [labAccount(), labAccount(), labAccount(), labAccount()],
            serverTime: ScriptedCall([.value(1), .value(2), .value(3)], log: (log, "rest.serverTime")),
            labRead: ScriptedCall([.value(busyLab), .value(busyLab), .value(busyLab)], log: (log, "rest.lab")),
            accountLog: log
        )
        let sleeper = CountingSleeper(endsOnCall: 3, onCall: { _ in log.add("sleep") })
        let rig = LabRig(rest: rest, sleep: { try await sleeper.sleep($0) })
        await rig.startTrading()
        // The store read the account once when it started; the loop's rounds are what comes after.
        let before = log.entries.count

        await rig.model.monitor()

        let rounds = Array(log.entries.dropFirst(before))
        let round = ["rest.serverTime", "rest.lab", "rest.account", "sleep"]
        #expect(rounds == round + round + round)
        #expect(sleeper.durations == [.seconds(5), .seconds(5), .seconds(5)])
        #expect(rest.serverTime.count == 3)
        #expect(rest.labRead.count == 3)
        #expect(rest.labWrite.count == 0, "the loop only looks")
        #expect(rest.accountCalls == 1 + 3)
        #expect(rig.model.settings == busyLab)
    }

    @Test func cancellingTheLoopDuringItsWaitEndsItWithoutAnotherRound() async {
        let rest = FakeRest(
            accounts: [labAccount(), labAccount(), labAccount()], serverTime: ScriptedCall([.value(1), .value(2)]),
            labRead: ScriptedCall([.value(busyLab), .value(busyLab)])
        )
        let sleeper = FakeSleeper(.holdUntilReleased)
        let rig = LabRig(rest: rest, sleep: { try await sleeper.sleep($0) })
        await rig.startTrading()
        let loop = Task { @MainActor in await rig.model.monitor() }
        await waitFor("the first wait") { sleeper.requested == 1 }
        let probesInTheFirstRound = rest.serverTime.count
        let readsInTheFirstRound = rest.labRead.count

        // The control: a wait that ends is followed by another round, and the loop waits again.
        sleeper.release()
        await waitFor("the second wait") { sleeper.requested == 2 }
        let probesInTheSecondRound = rest.serverTime.count

        loop.cancel()
        await loop.value

        #expect(probesInTheFirstRound == 1)
        #expect(readsInTheFirstRound == 1)
        #expect(probesInTheSecondRound == 2)
        #expect(rest.serverTime.count == 2)
        #expect(rest.labRead.count == 2)
        #expect(rest.accountCalls == 1 + 2)
        #expect(sleeper.requested == 2)
    }

    @Test func aLoopCancelledDuringItsProbeMakesNoFurtherCall() async {
        let rest = FakeRest(accounts: [labAccount(), labAccount()], serverTime: ScriptedCall([.hold]))
        let sleeper = CountingSleeper(endsOnCall: 3)
        let rig = LabRig(rest: rest, sleep: { try await sleeper.sleep($0) })
        await rig.startTrading()
        let loop = Task { @MainActor in await rig.model.monitor() }
        await waitFor("the probe is in flight") { rest.serverTime.heldCount == 1 }

        loop.cancel()
        let released = rest.serverTime.release(call: 0, .failure(URLError(.cancelled)))
        await loop.value

        #expect(released)
        #expect(rest.labRead.count == 0, "the loop did not read the settings")
        #expect(rest.accountCalls == 1, "only the store's own read: the loop did not check the account")
        #expect(sleeper.durations.isEmpty)
        #expect(rig.model.restStatus == .unknown)
        #expect(rig.model.reconciliation == .inFlight)
    }

    @Test func aLoopCancelledDuringItsReadOfTheSettingsMakesNoFurtherCallAndSaysNothing() async {
        let rest = FakeRest(
            accounts: [labAccount(), labAccount()], serverTime: ScriptedCall([.value(1)]),
            labRead: ScriptedCall([.hold])
        )
        let sleeper = CountingSleeper(endsOnCall: 3)
        let rig = LabRig(rest: rest, sleep: { try await sleeper.sleep($0) })
        await rig.startTrading()
        let loop = Task { @MainActor in await rig.model.monitor() }
        await waitFor("the read of the settings is in flight") { rest.labRead.heldCount == 1 }

        loop.cancel()
        let released = rest.labRead.release(call: 0, .failure(URLError(.cancelled)))
        await loop.value

        #expect(released)
        #expect(rest.serverTime.count == 1, "the probe came first")
        #expect(rest.accountCalls == 1, "only the store's own read: the loop did not check the account")
        #expect(sleeper.durations.isEmpty)
        #expect(rig.model.lastError == nil, "a read that was cancelled says nothing")
        #expect(!rig.model.settingsLoaded)
        #expect(rig.model.settingsRevision == 0)
    }

    @Test func aLoopThatReadsTheSettingsEveryRoundShowsTheDefaultsOfAServerThatStartedOver() async {
        // The second answer is what a server that has just started holds: 1x, no stress, no delay, no jitter.
        let rest = FakeRest(
            accounts: [labAccount(), labAccount(), labAccount()], serverTime: ScriptedCall([.value(1), .value(2)]),
            labRead: ScriptedCall([.value(busyLab), .value(LabSettings())])
        )
        let sleeper = FakeSleeper(.holdUntilReleased)
        let rig = LabRig(rest: rest, sleep: { try await sleeper.sleep($0) })
        await rig.startTrading()
        let loop = Task { @MainActor in await rig.model.monitor() }
        await waitFor("the first wait") { sleeper.requested == 1 }
        let afterTheFirstRound = (rig.model.settings, rig.model.settingsLoaded, rig.model.settingsRevision)

        sleeper.release()
        await waitFor("the second wait") { sleeper.requested == 2 }
        loop.cancel()
        await loop.value

        #expect(afterTheFirstRound.0 == busyLab, "the first round reads before the first wait")
        #expect(afterTheFirstRound.1)
        #expect(afterTheFirstRound.2 == 1)
        #expect(rig.model.settings == LabSettings())
        #expect(rig.model.settingsRevision == 2)
        #expect(rest.labRead.count == 2)
    }

    @Test func theControlsComeAliveInTheFirstRoundTheServerIsThereFor() async {
        let rest = FakeRest(
            accounts: [labAccount(), labAccount(), labAccount()],
            serverTime: ScriptedCall([.failure(URLError(.cannotConnectToHost)), .value(2)]),
            labRead: ScriptedCall([.failure(URLError(.cannotConnectToHost)), .value(busyLab)])
        )
        let sleeper = FakeSleeper(.holdUntilReleased)
        let rig = LabRig(rest: rest, sleep: { try await sleeper.sleep($0) })
        await rig.startTrading()
        let loop = Task { @MainActor in await rig.model.monitor() }
        await waitFor("the first wait") { sleeper.requested == 1 }
        let whileTheServerIsAway = (rig.model.settingsLoaded, rig.model.lastError, rig.model.restStatus)

        sleeper.release()
        await waitFor("the second wait") { sleeper.requested == 2 }
        loop.cancel()
        await loop.value

        #expect(whileTheServerIsAway.0 == false)
        #expect(whileTheServerIsAway.1 == LabMessages.couldNotReachTheServer)
        #expect(whileTheServerIsAway.2 == .unreachable)
        #expect(rig.model.settingsLoaded)
        #expect(rig.model.settings == busyLab)
        #expect(rig.model.lastError == nil)
        #expect(rig.model.restStatus == .reachable(rttNs: 0))
    }

    // MARK: Probing the REST API

    @Test func theRestStatusStartsUnknown() {
        let rig = LabRig()

        #expect(rig.model.restStatus == .unknown)
    }

    @Test func theRestRowIsTheRoundTripOfTheServerTimeCall() async {
        let clock = SteppingClock([1_000, 3_211_000])
        let rest = FakeRest(serverTime: ScriptedCall([.value(1_700_000_000_000_000_000)]))
        let rig = LabRig(rest: rest, monotonicNs: { clock.read() })

        await rig.model.probeRest()

        #expect(rig.model.restStatus == .reachable(rttNs: 3_210_000))
        #expect(rest.serverTime.count == 1)
    }

    @Test func theClockIsReadBeforeTheCallAndAfterIt() async {
        let clock = SteppingClock([100, 600])
        let rest = FakeRest(serverTime: ScriptedCall([.hold]))
        let rig = LabRig(rest: rest, monotonicNs: { clock.read() })
        let probe = Task { @MainActor in await rig.model.probeRest() }
        await waitFor("the probe is in flight") { rest.serverTime.heldCount == 1 }
        let readsWhileInFlight = clock.reads

        let released = rest.serverTime.release(call: 0, .success(1))
        await probe.value

        #expect(released)
        #expect(readsWhileInFlight == 1)
        #expect(clock.reads == 2)
        #expect(rig.model.restStatus == .reachable(rttNs: 500))
    }

    @Test func aProbeWhoseClockWentBackIsAZeroRoundTripAndNeverNegative() async {
        let clock = SteppingClock([5_000, 1_000])
        let rest = FakeRest(serverTime: ScriptedCall([.value(1)]))
        let rig = LabRig(rest: rest, monotonicNs: { clock.read() })

        await rig.model.probeRest()

        #expect(rig.model.restStatus == .reachable(rttNs: 0))
    }

    @Test func aRoundTripTooLongForAnInt64IsClampedToIt() async {
        let clock = SteppingClock([0, UInt64.max])
        let rest = FakeRest(serverTime: ScriptedCall([.value(1)]))
        let rig = LabRig(rest: rest, monotonicNs: { clock.read() })

        await rig.model.probeRest()

        #expect(rig.model.restStatus == .reachable(rttNs: Int64.max))
    }

    @Test func aProbeThatFailsSaysUnreachableAndNeverTheOldReachable() async {
        let clock = SteppingClock([0, 2_000_000])
        let rest = FakeRest(serverTime: ScriptedCall([.value(1), .failure(URLError(.notConnectedToInternet))]))
        let rig = LabRig(rest: rest, monotonicNs: { clock.read() })
        await rig.model.probeRest()
        let reachable = rig.model.restStatus

        await rig.model.probeRest()

        #expect(reachable == .reachable(rttNs: 2_000_000))
        #expect(rig.model.restStatus == .unreachable)
    }

    @Test func aProbeThatWorksAfterAFailureIsReachableAgain() async {
        let rest = FakeRest(serverTime: ScriptedCall([.failure(URLError(.timedOut)), .value(1)]))
        let rig = LabRig(rest: rest)
        await rig.model.probeRest()
        let failed = rig.model.restStatus

        await rig.model.probeRest()

        #expect(failed == .unreachable)
        #expect(rig.model.restStatus == .reachable(rttNs: 0))
    }

    @Test func aCancelledProbeLeavesTheStatusAsItWasAndIsNeverUnreachable() async {
        let errors: [any Error] = [CancellationError(), URLError(.cancelled)]
        for error in errors {
            let rest = FakeRest(serverTime: ScriptedCall([.value(1), .hold]))
            let rig = LabRig(rest: rest)
            await rig.model.probeRest()
            let before = rig.model.restStatus
            let probe = Task { @MainActor in await rig.model.probeRest() }
            await waitFor("the second probe is in flight") { rest.serverTime.heldCount == 1 }

            probe.cancel()
            let released = rest.serverTime.release(call: 1, .failure(error))
            await probe.value

            #expect(released)
            #expect(before == .reachable(rttNs: 0))
            #expect(rig.model.restStatus == before, "after \(error)")
        }
    }

    @Test func anOlderProbeThatAnswersLastChangesNothing() async {
        let rest = FakeRest(serverTime: ScriptedCall([.hold, .failure(URLError(.timedOut))]))
        let rig = LabRig(rest: rest)
        let first = Task { @MainActor in await rig.model.probeRest() }
        await waitFor("the first probe is in flight") { rest.serverTime.heldCount == 1 }

        await rig.model.probeRest()
        let afterTheNewer = rig.model.restStatus
        let released = rest.serverTime.release(call: 0, .success(5))
        await first.value

        #expect(released)
        #expect(afterTheNewer == .unreachable)
        #expect(rig.model.restStatus == .unreachable)
    }

    // MARK: Checking the account

    @Test func aStoreThatNeverLoadedIsNotComparedAndStaysInFlight() async {
        // A server whose cash differs from the empty store's: a store compared before it loaded would be said to drift.
        let rest = FakeRest(accounts: [labAccount(cash: 5)])
        let rig = LabRig(rest: rest)
        let epoch = rig.trading.store.state.epoch

        await rig.model.refreshReconciliation()
        let shown = rig.model.reconciliation
        let calls = rest.accountCalls
        // The control: the same store, compared with the same server, does say drift.
        let wouldHaveSaid = await rig.trading.store.reconcile()

        #expect(epoch == nil)
        #expect(shown == .inFlight)
        #expect(calls == 0)
        guard case .drift = wouldHaveSaid else {
            Issue.record("a store that never loaded would say \(wouldHaveSaid), so the control proves nothing")
            return
        }
    }

    @Test func aConsistentStoreReadsConsistent() async {
        let rest = FakeRest(accounts: [labAccount(), labAccount()])
        let rig = LabRig(rest: rest)
        await rig.startTrading()
        let epoch = rig.trading.store.state.epoch

        await rig.model.refreshReconciliation()

        #expect(epoch == "E1")
        #expect(rig.model.reconciliation == .consistent)
        #expect(rest.accountCalls == 2)
    }

    @Test func aDriftIsShownWithTheDifferenceThatWasFound() async {
        let rest = FakeRest(accounts: [labAccount(cash: 100_000_000), labAccount(cash: 99_000_000)])
        let rig = LabRig(rest: rest)
        await rig.startTrading()

        await rig.model.refreshReconciliation()

        guard case .drift(let detail) = rig.model.reconciliation else {
            Issue.record("expected a drift, got \(rig.model.reconciliation)")
            return
        }
        #expect(detail.contains("100000000"))
        #expect(detail.contains("99000000"))
    }

    @Test func anAccountThatCouldNotBeReadIsInFlightAndNotAClaimOfDrift() async {
        let rest = FakeRest(accounts: [labAccount(), labAccount(), .failure(URLError(.timedOut))])
        let rig = LabRig(rest: rest)
        await rig.startTrading()
        await rig.model.refreshReconciliation()
        let before = rig.model.reconciliation

        await rig.model.refreshReconciliation()

        #expect(before == .consistent)
        #expect(rig.model.reconciliation == .inFlight)
    }

    @Test func anOlderCheckThatAnswersLastIsDropped() async {
        // Call 0 is the store's own read, call 1 the first check (held) and call 2 the second, which finds a drift.
        let rest = FakeRest(accounts: [labAccount(), .hold, labAccount(cash: 90_000_000)])
        let rig = LabRig(rest: rest)
        await rig.startTrading()
        let first = Task { @MainActor in await rig.model.refreshReconciliation() }
        await waitFor("the first check is in flight") { rest.heldAccountCount == 1 }

        await rig.model.refreshReconciliation()
        let afterTheNewer = rig.model.reconciliation
        let released = rest.releaseAccount(call: 1, .success(accountDTO(cash: 100_000_000)))
        await first.value

        #expect(released)
        guard case .drift = afterTheNewer else {
            Issue.record("the newer check should have found a drift, got \(afterTheNewer)")
            return
        }
        #expect(rig.model.reconciliation == afterTheNewer)
    }

    @Test func aCheckThatWasCancelledChangesNothing() async {
        let rest = FakeRest(accounts: [labAccount(), labAccount(), .hold])
        let rig = LabRig(rest: rest)
        await rig.startTrading()
        await rig.model.refreshReconciliation()
        let before = rig.model.reconciliation
        let check = Task { @MainActor in await rig.model.refreshReconciliation() }
        await waitFor("the second check is in flight") { rest.heldAccountCount == 1 }

        check.cancel()
        let released = rest.releaseAccount(call: 2, .success(accountDTO(cash: 1)))
        await check.value

        #expect(released)
        #expect(before == .consistent)
        #expect(rig.model.reconciliation == .consistent)
    }
}

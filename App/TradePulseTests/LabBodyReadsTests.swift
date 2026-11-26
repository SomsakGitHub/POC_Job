import Contracts
import Foundation
import Observation
import SwiftUI
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// What the bodies of the Lab read. The Lab is the screen that measures the app, and it holds sliders, switches and
/// buttons, so no body of it may be evaluated again at the pace of the prices or of the frames: that would disturb
/// what it measures, and a control whose body is evaluated again at that pace loses the touch it is tracking. What
/// moves with the frames is read only when the model is asked for a sample, and what the sample finds is read in a
/// part of the screen of its own. These tests evaluate a body once, under observation, make one change and say whether
/// the change would have made SwiftUI evaluate that body again. They do not see SwiftUI evaluate a body: that takes a
/// device.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LabBodyReadsTests {
    /// A rig that has started and the Lab screen over its environment.
    private typealias Lab = (rig: ScreenRig, screen: LabScreen)

    /// One thing that happens while the Lab is open: what it is called, and what it does to the rig. It says whether
    /// it did what its name says, so that a change that did nothing cannot pass for one that told nobody.
    private typealias Move = (name: String, apply: @MainActor (Lab) async -> Bool)

    /// A rig over a server that answers everything the moves below ask for, and the Lab screen over it.
    private func started() async -> Lab {
        // Every read of the account gives the same answer: the store reads it when it starts and again when its
        // connection comes up, and the account check reads it once more.
        let rest = FakeRest(
            accountsFallback: labAccount(), serverTime: ScriptedCall([.value(1)]),
            labRead: ScriptedCall([.value(busyLab)]), drops: ScriptedCall([.failure(URLError(.timedOut))])
        )
        let rig = await ScreenRig.started(rest: rest)
        return (rig, LabScreen(environment: rig.env))
    }

    // MARK: The moves

    /// A frame with new prices arrives, a second after the one before: the pump counts a tick, a frame and a hitch.
    private var aFrameCarryingPrices: Move {
        ("a frame that carried prices and hitched", { lab in
            lab.rig.frame(seq: 2, last: 3_500, at: 10)
            let pump = lab.rig.env.pump
            return pump.tick == 2 && pump.frames == 1 && pump.hitches == 1
        })
    }

    /// The chart reports what it took to draw.
    private var aDrawOfTheChart: Move {
        ("a draw of the chart", { lab in
            lab.rig.env.pump.notifyRendered(drawNs: 2_000_000)
            return lab.rig.env.pump.drawCost.count == 1
        })
    }

    /// Both connections drop and start to reconnect.
    private var theConnectionsDropping: Move {
        ("the connections dropping", { lab in
            await lab.rig.push(.reconnecting(attempt: 1))
            return lab.rig.env.marketConnection == .reconnecting(attempt: 1)
        })
    }

    /// The server answers the request for its settings.
    private var theSettingsLoaded: Move {
        ("the settings loaded", { lab in
            await lab.screen.model.load()
            return lab.screen.model.settingsLoaded && lab.screen.model.settings == busyLab
        })
    }

    /// A request fails, and the line under the controls says so.
    private var aRequestThatFailed: Move {
        ("a request that failed", { lab in
            await lab.screen.model.dropConnections()
            return lab.screen.model.lastError == LabMessages.couldNotDropTheConnections
        })
    }

    /// The probe of the REST API finds it.
    private var theRestApiProbed: Move {
        ("the REST API probed", { lab in
            await lab.screen.model.probeRest()
            guard case .reachable = lab.screen.model.restStatus else { return false }
            return true
        })
    }

    /// The account check finds the app and the server agreeing.
    private var theAccountChecked: Move {
        ("the account checked", { lab in
            await lab.screen.model.refreshReconciliation()
            return lab.screen.model.reconciliation == .consistent
        })
    }

    /// The model takes a sample of the frames, after a frame that hitched.
    private var aSampleOfTheFrames: Move {
        ("a sample of the frames", { lab in
            let model = lab.screen.model
            model.sampleFrames()
            lab.rig.frame(seq: 2, last: 3_500, at: 10)
            model.sampleFrames()
            return model.hitchText == "1 hitch (100.0%)"
        })
    }

    /// An order is sent and waits for the exchange's answer.
    private var anOrderSubmitted: Move {
        ("an order submitted", { lab in
            let draft = OrderDraft(clientOrderId: "own", symbolId: 4, side: .buy, type: .market, quantity: 100)
            await lab.rig.env.trading.submit(draft)
            return lab.rig.env.trading.state.orders.count == 1
        })
    }

    /// Every move there is.
    private var everyMove: [Move] {
        [
            aFrameCarryingPrices, aDrawOfTheChart, theConnectionsDropping, theSettingsLoaded, aRequestThatFailed,
            theRestApiProbed, theAccountChecked, aSampleOfTheFrames, anOrderSubmitted,
        ]
    }

    /// Every move except the ones named in `names`.
    private func everyMove(except names: Set<String>) -> [Move] {
        everyMove.filter { !names.contains($0.name) }
    }

    /// For each of `moves`: makes a new rig, evaluates the body of the view `make` builds over it, makes the move
    /// and checks that the body would (`expected`) or would not have been evaluated again.
    private func check<Content: View>(
        told expected: Bool, by moves: [Move], sourceLocation: SourceLocation = #_sourceLocation,
        make: (Lab) -> Content
    ) async {
        #expect(!moves.isEmpty, sourceLocation: sourceLocation)
        for move in moves {
            let lab = await started()
            let told = watchBody(of: make(lab))
            #expect(!told.isSet, "before \(move.name)", sourceLocation: sourceLocation)

            let took = await move.apply(lab)

            #expect(took, "\(move.name) happened", sourceLocation: sourceLocation)
            #expect(told.isSet == expected, "\(move.name)", sourceLocation: sourceLocation)
        }
    }

    // MARK: The screen and its parts

    @Test func theLabScreensBodyIsNotEvaluatedAgainWhenAnythingChanges() async {
        #expect(everyMove.count == 9)

        await check(told: false, by: everyMove) { lab in lab.screen }
        // The control: what the screen leaves to a part of its own is told.
        await check(told: true, by: [theSettingsLoaded]) { lab in LabControlsSection(model: lab.screen.model) }
    }

    @Test func theControlsAreEvaluatedAgainWhenTheSettingsOrTheErrorChangeAndNeverWithTheFrames() async {
        let told = [theSettingsLoaded, aRequestThatFailed]
        await check(told: true, by: told) { lab in LabControlsSection(model: lab.screen.model) }
        let quiet = everyMove(except: Set(told.map(\.name)))
        #expect(quiet.count == 7)
        await check(told: false, by: quiet) { lab in LabControlsSection(model: lab.screen.model) }
    }

    @Test func theRateControlIsEvaluatedAgainWhenARequestForTheSettingsEndsAndNeverWithTheFrames() async {
        await check(told: true, by: [theSettingsLoaded]) { lab in RateControl(current: 1, model: lab.screen.model) }
        let quiet = everyMove(except: [theSettingsLoaded.name])
        #expect(quiet.count == 8)
        await check(told: false, by: quiet) { lab in RateControl(current: 1, model: lab.screen.model) }
    }

    @Test func theConnectionsAreEvaluatedAgainByTheConnectionsAndTheProbeAndNothingElse() async {
        let told = [theConnectionsDropping, theRestApiProbed]
        await check(told: true, by: told) { lab in
            LabConnectionsSection(environment: lab.rig.env, model: lab.screen.model)
        }
        let quiet = everyMove(except: Set(told.map(\.name)))
        #expect(quiet.count == 7)
        await check(told: false, by: quiet) { lab in
            LabConnectionsSection(environment: lab.rig.env, model: lab.screen.model)
        }
    }

    @Test func theAccountRowIsEvaluatedAgainByTheCheckAloneAndTheSectionWithTheButtonNeverIs() async {
        await check(told: true, by: [theAccountChecked]) { lab in AccountCheckRow(model: lab.screen.model) }
        let quiet = everyMove(except: [theAccountChecked.name])
        #expect(quiet.count == 8)
        await check(told: false, by: quiet) { lab in AccountCheckRow(model: lab.screen.model) }
        await check(told: false, by: everyMove) { lab in LabAccountSection(model: lab.screen.model) }
    }

    @Test func theFramesAreEvaluatedAgainByASampleAndNeverByTheFramesThemselves() async {
        let epoch = Date(timeIntervalSince1970: 0)
        await check(told: true, by: [aSampleOfTheFrames]) { lab in
            LabFramesSection(model: lab.screen.model, environment: lab.rig.env, updatedAt: epoch)
        }
        let quiet = everyMove(except: [aSampleOfTheFrames.name])
        #expect(quiet.count == 8)
        await check(told: false, by: quiet) { lab in
            LabFramesSection(model: lab.screen.model, environment: lab.rig.env, updatedAt: epoch)
        }
    }

    // MARK: The timeline

    @Test func theMeasurementsAndWhatTheTimelineShowsReadNothingThatMovesWithTheFrames() async {
        await check(told: false, by: everyMove) { lab in
            LabMeasurementsSection(environment: lab.rig.env, model: lab.screen.model)
        }

        #expect(everyMove.count == 9)
        for move in everyMove {
            let lab = await started()
            let section = LabMeasurementsSection(environment: lab.rig.env, model: lab.screen.model)
            let told = Flag()
            withObservationTracking {
                _ = section.content(at: Date(timeIntervalSince1970: 0))
            } onChange: {
                told.set()
            }

            let took = await move.apply(lab)

            #expect(took, "\(move.name) happened")
            #expect(!told.isSet, "what the timeline shows, after \(move.name)")
        }
    }

    // MARK: The control

    @Test func aBodyThatReadsThePumpsCountersIsToldByEveryFrameWhichIsWhyTheLabDoesNot() async {
        let lab = await started()
        let pump = lab.rig.env.pump
        let toldByFrames = Flag()
        let toldByHitches = Flag()
        withObservationTracking { _ = pump.frames } onChange: { toldByFrames.set() }
        withObservationTracking { _ = pump.hitches } onChange: { toldByHitches.set() }

        lab.rig.frame(seq: 2, last: 3_500, at: 10)

        #expect(toldByFrames.isSet)
        #expect(toldByHitches.isSet)
    }

    @Test func makingTheModelOrTheScreenReadsNoCounterOfThePump() async {
        let lab = await started()
        let env = lab.rig.env
        let toldByTheModel = Flag()
        let toldByTheScreen = Flag()
        let toldByTheControl = Flag()
        withObservationTracking {
            _ = LabViewModel(rest: env.rest, latency: env.latency, pump: env.pump, trading: env.trading)
        } onChange: {
            toldByTheModel.set()
        }
        withObservationTracking {
            _ = LabScreen(environment: env)
        } onChange: {
            toldByTheScreen.set()
        }
        withObservationTracking { _ = env.pump.frames } onChange: { toldByTheControl.set() }

        lab.rig.frame(seq: 2, last: 3_500, at: 10)

        #expect(env.pump.frames == 1)
        #expect(toldByTheControl.isSet, "the control: a read of the counter is told")
        #expect(!toldByTheModel.isSet)
        #expect(!toldByTheScreen.isSet)
    }
}

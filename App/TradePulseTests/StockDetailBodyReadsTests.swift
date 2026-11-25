import Contracts
import Foundation
import Observation
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// What the body of the detail screen reads. A body that is evaluated again at the pace of the prices updates the two
/// segmented pickers again and again, and a segmented control that is updated while a finger is on it drops that
/// touch, so the body must read nothing that moves with the prices. These tests evaluate the body once, under
/// observation, and say whether a change would have made SwiftUI evaluate it again. They do not see SwiftUI evaluate
/// a body: that takes a device.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct StockDetailBodyReadsTests {
    /// A screen of PTT over an environment of fakes, as it is a few seconds after it appeared: its first history of 300
    /// candles is loaded, the market has given a price, and the pump has made a frame for it. A later history call
    /// answers from `candles`.
    private func screenAfterItsFirstLoad(
        then candles: [FakeRest.CandleAnswer] = []
    ) async -> (rig: EnvRig, screen: StockDetailScreen) {
        let rig = EnvRig(rest: FakeRest(candles: [.candles(history(count: 300))] + candles))
        let screen = StockDetailScreen(symbol: sampleSymbols[0], environment: rig.env)
        Self.feed(rig.env, seq: 1, last: 3_425)
        await screen.model.loadHistory()
        screen.model.refreshFromState()
        rig.env.pump.step(timestamp: 9, targetTimestamp: 9.016, duration: 0.016)
        return (rig, screen)
    }

    /// Gives the market of `env` one update of PTT that moves its price to `last` and, when `openTimeMs` is given,
    /// starts the one-minute candle that opens then.
    private static func feed(_ env: AppEnvironment, seq: UInt64, last: Int64, openTimeMs: Int64? = nil) {
        var update = symbolUpdate(seq: seq, last: last)
        if let openTimeMs {
            update.candle1M = candle(openTimeMs: openTimeMs).wire
        }
        _ = env.marketState.apply(frame: marketFrame(sendNs: 0, updates: [update]), receivedAtNs: 1_000)
    }

    /// Evaluates the body of `screen` once, watching what it reads, and gives a flag that is set when any of it
    /// changes: the moment at which SwiftUI would evaluate the body again.
    private func watchBody(of screen: StockDetailScreen) -> Flag {
        let told = Flag()
        withObservationTracking {
            _ = screen.body
        } onChange: {
            told.set()
        }
        return told
    }

    @Test func theBodyIsNotEvaluatedAgainWhenAnythingThatMovesWithThePricesChanges() async {
        let changes: [(name: String, apply: @MainActor (EnvRig, StockDetailScreen) -> Bool)] = [
            ("a frame that carried prices", { rig, _ in
                Self.feed(rig.env, seq: 2, last: 3_500)
                rig.env.pump.step(timestamp: 10, targetTimestamp: 10.016, duration: 0.016)
                return rig.env.pump.tick == 2
            }),
            ("the model taking a new price", { rig, screen in
                let header = screen.model.header
                Self.feed(rig.env, seq: 2, last: 3_500)
                screen.model.refreshFromState()
                return screen.model.lastPrice == satang(3_500) && screen.model.header != header
            }),
            ("the model taking a new candle", { rig, screen in
                let before = screen.model.series.version
                Self.feed(rig.env, seq: 2, last: 3_425, openTimeMs: 18_600_000)
                screen.model.refreshFromState()
                return screen.model.series.version != before
            }),
            ("the zoom", { _, screen in
                screen.model.visibleCount = 100
                return screen.model.visibleCount == 100
            }),
            ("the pan", { _, screen in
                screen.model.panOffset = 10
                return screen.model.panOffset == 10
            }),
        ]
        #expect(changes.count == 5)
        for change in changes {
            let (rig, screen) = await screenAfterItsFirstLoad()
            let told = watchBody(of: screen)
            #expect(!told.isSet, "before \(change.name)")

            let took = change.apply(rig, screen)

            #expect(took, "\(change.name) changed what it should")
            #expect(!told.isSet, "\(change.name)")
        }
    }

    @Test func theBodyIsNotEvaluatedAgainWhileAHistoryLoads() async {
        let (rig, screen) = await screenAfterItsFirstLoad(then: [.hold])
        let told = watchBody(of: screen)

        let model = screen.model
        async let load: Void = model.loadHistory()
        await waitFor("the history call is held") { rig.rest.heldCandleCount == 1 }

        #expect(model.isLoading)
        #expect(!told.isSet)

        // Lets the load end, so that nothing is left running.
        rig.rest.releaseCandles(call: 1, .success(history(count: 300)))
        await load
    }

    @Test func theBodyIsEvaluatedAgainWhenAHistoryFailsToLoad() async {
        // The control for the tests above: a change to what the body does read is told, whatever depth it reads it at.
        let (_, screen) = await screenAfterItsFirstLoad(then: [.failure(URLError(.timedOut))])
        let told = watchBody(of: screen)
        #expect(!told.isSet)

        await screen.model.loadHistory()

        #expect(screen.model.loadFailed)
        #expect(told.isSet)
    }
}

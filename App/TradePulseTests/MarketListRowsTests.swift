import Observation
import Testing
@testable import TradePulse

/// What the Market list shows, and what makes it draw again. Its rows are the server's symbols in the server's order,
/// each with the newest price the feed gave for it; it is evaluated again when the symbols arrive and when a frame
/// carried new prices, and not for the counters that change with every frame.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MarketListRowsTests {
    /// Gives the market a new price for the first symbol and runs the display frame at `timestamp` seconds, as the
    /// display link does.
    private func feed(_ env: AppEnvironment, seq: UInt64, last: Int64, at timestamp: Double) {
        let frame = marketFrame(sendNs: 0, updates: [symbolUpdate(seq: seq, last: last)])
        _ = env.marketState.apply(frame: frame, receivedAtNs: 1_000)
        env.pump.step(timestamp: timestamp, targetTimestamp: timestamp + 0.016, duration: 0.016)
    }

    // MARK: Rows

    @Test func thereAreNoRowsBeforeTheServerHasListedItsSymbols() {
        let rig = EnvRig()
        #expect(MarketListView.rows(in: rig.env).isEmpty)
    }

    @Test func theRowsAreTheSymbolsInTheServersOrderWithNoPriceYet() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        let rows = MarketListView.rows(in: rig.env)
        #expect(rows.map(\.ticker) == ["PTT", "AOT", "CPALL"])
        #expect(rows.map(\.lastText) == ["\u{2014}", "\u{2014}", "\u{2014}"])
    }

    @Test func aRowShowsThePriceOfItsOwnSymbolOnceAFrameHasCarriedIt() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        feed(rig.env, seq: 1, last: 3_450, at: 10.0)
        let rows = MarketListView.rows(in: rig.env)
        #expect(rows.map(\.lastText) == ["34.50", "\u{2014}", "\u{2014}"])
        #expect(rows.map(\.direction) == [.up, nil, nil])
    }

    // MARK: What makes the list draw again

    @Test func theListIsEvaluatedAgainWhenTheSymbolsArrive() async {
        let rig = EnvRig()
        let changed = Flag()
        withObservationTracking {
            _ = MarketListView.rows(in: rig.env)
        } onChange: {
            changed.set()
        }
        #expect(!changed.isSet)
        await rig.env.bootstrap()
        #expect(changed.isSet)
    }

    @Test func theListIsEvaluatedAgainWhenAFrameCarriesNewPrices() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        let changed = Flag()
        withObservationTracking {
            _ = MarketListView.rows(in: rig.env)
        } onChange: {
            changed.set()
        }
        #expect(!changed.isSet)
        feed(rig.env, seq: 1, last: 3_450, at: 10.0)
        #expect(changed.isSet)
    }

    @Test func theFrameAndHitchCountersDoNotMakeTheListDrawAgain() async {
        let rig = EnvRig()
        await rig.env.bootstrap()
        let changed = Flag()
        withObservationTracking {
            _ = MarketListView.rows(in: rig.env)
        } onChange: {
            changed.set()
        }
        // Two frames and a hitch go by while the market does not change.
        rig.env.pump.step(timestamp: 10.0, targetTimestamp: 10.016, duration: 0.016)
        rig.env.pump.step(timestamp: 10.016, targetTimestamp: 10.032, duration: 0.016)
        rig.env.pump.step(timestamp: 10.100, targetTimestamp: 10.116, duration: 0.016)
        #expect(rig.env.pump.frames == 2)
        #expect(rig.env.pump.hitches == 1)
        #expect(!changed.isSet)
    }
}

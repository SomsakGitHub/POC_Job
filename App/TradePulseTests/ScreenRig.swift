import Contracts
import Observation
import SwiftUI
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// An environment over fakes that has started, the way the app is a few seconds after launch: the symbols are loaded,
/// the trading store has started, both connections are up, and the market has given one price of PTT that the pump
/// has made a frame of. The tests of the screens use it to change one thing at a time and see what a body would
/// have been told.
@MainActor
struct ScreenRig {
    /// The environment over fakes and the fakes behind it.
    let rig: EnvRig
    /// The clock the tickets of this rig judge the age of the market data by. It reads one microsecond after the
    /// frames the rig gives, so the market data is fresh until a test makes it old.
    let clock = ManualClock(TicketRig.frameReceivedNs + 1_000)

    /// The environment the screens are made over.
    var env: AppEnvironment { rig.env }

    /// A rig whose environment has been started. `submits` are the answers of the trading client's first submits and
    /// `rest` the REST API behind the environment.
    static func started(
        submits: [FakeTradingClient.SubmitAnswer] = [], rest: FakeRest = FakeRest()
    ) async -> ScreenRig {
        let rig = EnvRig(rest: rest, tradingSubmits: submits)
        let (_, finished) = rig.bootstrapInTask()
        await waitFor("the environment has started") { finished.isSet }
        rig.market.push(.connected)
        rig.tradingClient.push(.connected)
        await waitFor("both connections are up") {
            rig.env.marketConnection == .connected && rig.env.tradingConnection == .connected
        }
        let started = ScreenRig(rig: rig)
        started.frame(seq: 1, last: 3_425, at: 9)
        return started
    }

    /// Gives the market one update of PTT that moves its price to `last` and lets the pump make its frame, which is
    /// what moves the pump's `tick`.
    func frame(seq: UInt64, last: Int64, at timestamp: Double) {
        let update = symbolUpdate(seq: seq, last: last)
        let frame = marketFrame(sendNs: 0, updates: [update])
        _ = env.marketState.apply(frame: frame, receivedAtNs: TicketRig.frameReceivedNs)
        env.pump.step(timestamp: timestamp, targetTimestamp: timestamp + 0.016, duration: 0.016)
    }

    /// Hands `event` to the trading store as the server's stream would.
    func deliver(_ event: Tp_OrderEvent) async throws {
        let handlers = try #require(rig.tradingClient.handlers, "the trading store was not started")
        await handlers.onEvent(event)
    }

    /// Makes the server's epoch `epoch` for the trading store: the first epoch it sees is adopted, every other one is
    /// an epoch change.
    func deliverEpoch(_ epoch: String) async throws {
        try await deliver(acceptedEvent(1, client: "client-\(epoch)", order: "order-\(epoch)", epoch: epoch))
    }

    /// Makes both connections report `state` and waits until the environment shows it.
    func push(_ state: ConnectionState) async {
        rig.market.push(state)
        rig.tradingClient.push(state)
        await waitFor("both connections read \(state)") {
            env.marketConnection == state && env.tradingConnection == state
        }
    }

    /// The ticket screen of PTT over this rig, judging the age of the market data by the rig's clock.
    func ticket(side: Side = .buy) -> OrderTicketScreen {
        let clock = clock
        return OrderTicketScreen(symbol: sampleSymbols[0], side: side, environment: env, now: { clock.read() })
    }
}

/// Evaluates the body of `view` once, watching what it reads, and gives a flag that is set when any of it changes:
/// the moment at which SwiftUI would evaluate the body again. It does not see SwiftUI evaluate a body, which takes a
/// device; it says whether a change would have made it.
@MainActor
func watchBody<Content: View>(of view: Content) -> Flag {
    let told = Flag()
    withObservationTracking {
        _ = view.body
    } onChange: {
        told.set()
    }
    return told
}

import Contracts
import Synchronization
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

// A trading store over the fake client, the ticket's model on top of it, and the order events and accounts the tests
// of the order screens feed in. Every protobuf message is built by assigning its properties, never through a
// memberwise initialiser.

/// Hands out the client order ids "order-1", "order-2" and so on, so that a test can say which order is which.
final class IdSequence: Sendable {
    /// How many ids have been handed out.
    private let count = Mutex(0)

    /// The next id.
    func next() -> String {
        count.withLock { count in
            count += 1
            return "order-\(count)"
        }
    }
}

/// A ledger entry event: `quantity` shares of `symbol` filled at `price`, with the cash and the position that follow.
func ledgerEvent(
    _ seq: UInt64, ledgerSeq: UInt64, order: String = "O1", symbol: UInt32 = 4, side: Tp_Side = .buy,
    quantity: Int64 = 100, price: Int64 = 3_425, commission: Int64 = 51, cashDelta: Int64 = -342_551,
    cashAfter: Int64 = 99_657_449, positionAfter: Int64 = 100, tsNs: Int64 = 1_795_615_402_000_000_000,
    epoch: String = "E1"
) -> Tp_OrderEvent {
    var entry = Tp_LedgerEntry()
    entry.ledgerSeq = ledgerSeq
    entry.orderID = order
    entry.symbolID = symbol
    entry.side = side
    entry.quantity = quantity
    entry.price = price
    entry.commission = commission
    entry.cashDelta = cashDelta
    entry.cashAfter = cashAfter
    entry.positionAfter = positionAfter
    entry.tsNs = tsNs
    var event = Tp_OrderEvent()
    event.eventSeq = seq
    event.serverEpoch = epoch
    event.serverTsNs = tsNs
    event.ledgerEntry = entry
    return event
}

/// The ledger row `ledgerEvent` makes of the same arguments.
func ledgerRow(
    _ id: UInt64, symbol: UInt32 = 4, side: Side = .buy, quantity: Int64 = 100, price: Int64 = 3_425,
    commission: Int64 = 51, cashDelta: Int64 = -342_551, tsNs: Int64 = 1_795_615_402_000_000_000
) -> LedgerRow {
    LedgerRow(
        id: id, orderId: "O1", symbolId: symbol, side: side, quantity: quantity, price: satang(price),
        commission: commission, cashDelta: cashDelta, tsNs: tsNs
    )
}

/// The account of the server in epoch `epoch` with `cash` satang and the positions `held` (symbol id to shares).
func accountDTO(cash: Int64, held: [UInt32: Int64] = [:], epoch: String = "E1") -> AccountDTO {
    AccountDTO(
        epoch: epoch, cash: cash,
        positions: held.sorted { $0.key < $1.key }.map { PositionDTO(symbolId: $0.key, quantity: $0.value) },
        lastEventSeq: 0, lastLedgerSeq: 0
    )
}

/// What a server that took an order answers: its own id for it.
let acceptedAnswer = SubmitResult(
    orderId: "O-1", accepted: true, rejectReason: nil, serverRecvNs: 1, serverAckNs: 2, clientRoundTripNs: 3
)

/// A trading store over the fake client, the way the app builds one: the test starts it, and delivers the events the
/// server's stream would.
@MainActor
struct TradingRig {
    /// The calls the fake client received, in order.
    let log = EventLog()
    /// The client the store trades through.
    let client: FakeTradingClient
    /// The REST API the store reads the account from.
    let rest: FakeRest
    /// The store under test.
    let store: TradingStore

    /// A store over a client that answers the first submits as `submits` says, and accepts every other.
    init(rest: FakeRest = FakeRest(), submits: [FakeTradingClient.SubmitAnswer] = []) {
        let client = FakeTradingClient(log: log, submits: submits)
        self.client = client
        self.rest = rest
        store = TradingStore(client: client, rest: rest, latency: LatencyRecorder())
    }

    /// Starts the store: it reads the account and starts the event stream.
    func start() async {
        await store.start()
    }

    /// Hands `event` to the store as the server's stream would. The store must have been started.
    func deliver(_ event: Tp_OrderEvent) async throws {
        let handlers = try #require(client.handlers, "the store was not started")
        await handlers.onEvent(event)
    }

    /// Makes the store see the server in epoch `epoch`: the first epoch it sees is adopted, every other one is an
    /// epoch change, which empties its ledger and counts in `epochChanges`.
    func deliverEpoch(_ epoch: String) async throws {
        try await deliver(acceptedEvent(1, client: "client-\(epoch)", order: "order-\(epoch)", epoch: epoch))
    }
}

/// An order ticket over a trading store, a market state the test feeds and a clock the test sets. The clock starts one
/// microsecond after the frame that `feed()` applies is received, so the market data is fresh until the test makes it
/// old.
@MainActor
struct TicketRig {
    /// The time the fed frames are received at, which is what `FakeMarketState` stamps them with.
    static let frameReceivedNs: Int64 = 1_000

    /// The trading side.
    let trading: TradingRig
    /// The market the ticket prices on.
    let market = FakeMarketState()
    /// The clock the ticket judges the age of the market data by.
    let clock = ManualClock(TicketRig.frameReceivedNs + 1_000)
    /// The ids the ticket gives its orders.
    let ids = IdSequence()
    /// The ticket under test.
    let model: OrderTicketViewModel

    /// A ticket for `symbol` that opens on `side`. `feedsPrices` gives the market one update of PTT (last 34.25, bid
    /// 34.00, ask 34.50), so that the market data is fresh.
    init(
        symbol: SymbolDTO = sampleSymbols[0], side: Side = .buy, rest: FakeRest = FakeRest(),
        submits: [FakeTradingClient.SubmitAnswer] = [], feedsPrices: Bool = true
    ) {
        trading = TradingRig(rest: rest, submits: submits)
        if feedsPrices { market.feed() }
        let clock = clock
        let ids = ids
        model = OrderTicketViewModel(
            symbol: symbol, store: trading.store, marketState: market.state, side: side, now: { clock.read() },
            makeId: { ids.next() }
        )
    }

    /// The fake client the orders go to.
    var client: FakeTradingClient { trading.client }
    /// The trading store the orders go through.
    var store: TradingStore { trading.store }

    /// Makes the market data older than the ticket accepts.
    func makeStale() {
        clock.set(Self.frameReceivedNs + OrderTicketViewModel.maxMarketAgeNs + 1)
    }

    /// Makes the market data young again.
    func makeFresh() {
        clock.set(Self.frameReceivedNs + 1_000)
    }

    /// Starts the trading store.
    func start() async {
        await trading.start()
    }
}

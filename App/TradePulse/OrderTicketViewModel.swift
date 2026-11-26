import Contracts
import Foundation
import Observation
import TradeCore
import TradeNetworking

/// What the order ticket shows and does for one symbol: the form the user fills in, the one sentence that says what is
/// wrong with it, the estimate, the warnings that never block, the reason the send button is off, and the sending.
///
/// A ticket is made for one presentation and one symbol and is never shared. It holds no timer and no task: the screen
/// calls `submit()` from a button, and `noteMarket()` when a frame carried prices.
///
/// What a view reads is observed only where it can change at the pace of the user: the form, `inFlight`, the id of the
/// order sent and a flag that changes only when the market data goes from fresh to old or back. The prices themselves
/// are not observed here (the market state is not observable), so a view that shows one reads it in a leaf of its own
/// that the screen's frame tick updates.
@MainActor
@Observable
final class OrderTicketViewModel {
    /// How old the market data may be, in nanoseconds, for an order to be sent on it: three seconds.
    static let maxMarketAgeNs: Int64 = 3_000_000_000

    /// What the form says once both texts have been read.
    private enum Reading {
        /// The form can be sent: this many shares and, for a limit order, this price.
        case ready(quantity: Quantity, limit: Price?)
        /// The first thing wrong with the form.
        case refused(String)
    }

    /// The symbol traded.
    let symbol: SymbolDTO
    /// Buy or sell.
    var side: Side
    /// Market or limit.
    var type = OrderType.market
    /// What the quantity field holds.
    var quantityText = "100"
    /// What the price field holds. A market order never reads it.
    var priceText = ""

    /// Whether an order is on its way: set before the first suspension of `submit()` and cleared when it ends.
    private(set) var inFlight = false
    /// The client order id of the last order this ticket sent; nil before the first.
    private(set) var lastClientOrderId: String?
    /// Whether the market data was fresh the last time `noteMarket()` looked, and when the ticket was made.
    private(set) var marketWasFresh: Bool

    /// The trading store the orders go through and the cash and the positions are read from.
    private let store: TradingStore
    /// The market the prices and the age of the data are read from.
    private let marketState: MarketState
    /// The clock the age of the market data is judged by, in nanoseconds.
    private let now: () -> Int64
    /// Where a new client order id comes from.
    private let makeId: () -> String

    /// A ticket for `symbol` that trades through `store` and prices on `marketState`. `side` is the side it opens on,
    /// `now` the clock and `makeId` the source of client order ids.
    init(
        symbol: SymbolDTO, store: TradingStore, marketState: MarketState, side: Side = .buy,
        now: @escaping () -> Int64 = WallClock.nowNs, makeId: @escaping () -> String = { UUID().uuidString }
    ) {
        self.symbol = symbol
        self.store = store
        self.marketState = marketState
        self.side = side
        self.now = now
        self.makeId = makeId
        marketWasFresh = marketState.isFresh(nowNs: now(), maxAgeNs: Self.maxMarketAgeNs)
    }

    // MARK: What the form says

    /// The first thing wrong with the form, in plain English, or nil when the form can be sent. It knows nothing of
    /// cash or positions: an order the account cannot pay for is for the exchange to refuse.
    var validationMessage: String? {
        if case .refused(let message) = reading { message } else { nil }
    }

    /// A warning about the form that never blocks it: an estimate above the cash, or a sale of more shares than are
    /// held. Nil for a form that is not valid, has no estimate or passes both checks.
    var balanceHint: String? {
        guard case .ready(let quantity, let limit) = reading, let estimate = estimate(quantity, limit) else {
            return nil
        }
        switch side {
        case .buy:
            let cash = store.state.cash
            return estimate > cash ? OrderMessages.cashHint(estimate: estimate, cash: cash) : nil
        case .sell:
            let held = store.state.positions[symbol.id] ?? 0
            return quantity > held ? OrderMessages.positionHint(held: held, ticker: symbol.ticker) : nil
        }
    }

    /// The value of the shares before commission, written as money after "≈ ", or a dash when the form is not valid or
    /// there is no price to work it out from.
    var estimatedCost: String {
        guard case .ready(let quantity, let limit) = reading, let estimate = estimate(quantity, limit) else {
            return "—"
        }
        return "≈ " + MoneyFormat.baht(satang: estimate)
    }

    /// The prices the market gave for the symbol last, as one line: "Last 34.25 · Bid 34.00 · Ask 34.50", with a dash
    /// for a price that is not above 0, or "Waiting for prices" while the market has given none.
    var marketLine: String {
        guard let snapshot = marketState.snapshot(symbol.id) else { return "Waiting for prices" }
        let last = Self.priceText(snapshot.last)
        return "Last \(last) · Bid \(Self.priceText(snapshot.bid)) · Ask \(Self.priceText(snapshot.ask))"
    }

    /// The row of the order this ticket sent last, as the trading store has it now; nil before the first order.
    var lastOrder: OrderRow? {
        guard let id = lastClientOrderId else { return nil }
        return store.state.orders.first { $0.id == id }
    }

    // MARK: Sending

    /// Why the send button is off, or nil when it is on: the first of an order in flight, the trading connection
    /// being down, the market data being old and the form being wrong.
    func blockedReason(tradingConnected: Bool) -> String? {
        if inFlight { return OrderMessages.orderInFlight }
        if !tradingConnected { return OrderMessages.tradingDisconnected }
        if !marketIsFresh { return OrderMessages.marketStale }
        return validationMessage
    }

    /// Whether an order can be sent: exactly when `blockedReason(tradingConnected:)` has nothing to say.
    func canSubmit(tradingConnected: Bool) -> Bool {
        blockedReason(tradingConnected: tradingConnected) == nil
    }

    /// Looks at the age of the market data and tells the readers of `blockedReason(tradingConnected:)` only when it
    /// went from fresh to old or back.
    func noteMarket() {
        let fresh = marketState.isFresh(nowNs: now(), maxAgeNs: Self.maxMarketAgeNs)
        if fresh != marketWasFresh {
            marketWasFresh = fresh
        }
    }

    /// Sends the order the form describes, with a new client order id. It sends nothing while an order is on its way,
    /// while the form is wrong or while the market data is old; it cannot see the trading connection, and an order
    /// that is sent as the connection drops ends as an unconfirmed row.
    func submit() async {
        guard !inFlight, case .ready(let quantity, let limit) = reading else { return }
        guard marketIsFresh else {
            // The refusal is how the screen learns that the data went old without a frame to say so.
            noteMarket()
            return
        }
        inFlight = true
        defer { inFlight = false }
        let id = makeId()
        lastClientOrderId = id
        let draft = OrderDraft(
            clientOrderId: id, symbolId: symbol.id, side: side, type: type, quantity: quantity, limitPrice: limit
        )
        await store.submit(draft)
    }

    // MARK: Working things out

    /// Whether the market data is fresh now. The answer is worked out from the clock each time; the flag is read only
    /// so that whoever asks is told when it changes.
    private var marketIsFresh: Bool {
        _ = marketWasFresh
        return marketState.isFresh(nowNs: now(), maxAgeNs: Self.maxMarketAgeNs)
    }

    /// The form read as the exchange will read it. The texts are read before any rule is applied, quantity first.
    private var reading: Reading {
        let quantity: Quantity
        switch Self.parseQuantity(quantityText) {
        case .value(let shares): quantity = shares
        case .empty: return .refused(OrderMessages.enterQuantity)
        case .notDigits: return .refused(OrderMessages.quantityDigitsOnly)
        case .tooLarge: return .refused(OrderMessages.quantityTooLarge)
        }
        var limit: Price?
        if type == .limit {
            switch Self.parsePrice(priceText) {
            case .value(let price): limit = price
            case .empty: return .refused(OrderMessages.enterPrice)
            case .unreadable: return .refused(OrderMessages.priceShape)
            }
        }
        let reference = Price(satang: symbol.reference)
        guard let reason = TickRules.validate(type: type, quantity: quantity, limit: limit, reference: reference) else {
            return .ready(quantity: quantity, limit: limit)
        }
        return .refused(Self.message(for: reason, limit: limit, reference: reference))
    }

    /// The sentence for a rule the form breaks: the base sentence of the reason, with what the ticket knows on top.
    private static func message(for reason: RejectReason, limit: Price?, reference: Price) -> String {
        switch reason {
        case .invalidTick:
            guard let limit, limit.satang > 0 else { return OrderMessages.priceAboveZero }
            return OrderMessages.priceStep(TickRules.tickSize(at: limit))
        case .outsidePriceBand:
            return OrderMessages.priceBand(reference: reference, band: TickRules.band(reference: reference))
        default:
            return OrderMessages.text(for: reason)
        }
    }

    /// What `quantity` shares are worth in satang before commission, or nil when there is no price to work it out
    /// from. A limit order uses its limit price. A market buy uses the ask and a market sell the bid, and either falls
    /// back to the last price when it is not above 0. The product is worked out wide and held to the range of `Int64`.
    private func estimate(_ quantity: Quantity, _ limit: Price?) -> Int64? {
        var price = limit?.satang ?? 0
        if limit == nil {
            guard let snapshot = marketState.snapshot(symbol.id) else { return nil }
            let quoted = side == .buy ? snapshot.ask.satang : snapshot.bid.satang
            price = quoted > 0 ? quoted : snapshot.last.satang
        }
        guard price > 0 else { return nil }
        return Int64(clamping: Int128(quantity) * Int128(price))
    }

    /// A price as text, or a dash when it is not above 0 (a book with nobody on one side).
    private static func priceText(_ price: Price) -> String {
        price.satang > 0 ? price.description : "—"
    }
}

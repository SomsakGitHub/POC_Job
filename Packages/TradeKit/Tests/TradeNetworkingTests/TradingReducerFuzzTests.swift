import Contracts
import Testing
import TradeCore
import TradeNetworking

/// A small deterministic generator (SplitMix64), so the fuzz test draws the same actions on every run and on every
/// machine: no clock, no system randomness.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// One of `items`, which must not be empty.
    mutating func pick<T>(_ items: [T]) -> T {
        items[Int(next() % UInt64(items.count))]
    }

    /// True `percent` times in a hundred.
    mutating func chance(_ percent: UInt64) -> Bool {
        next() % 100 < percent
    }

    /// True once in `count` times on average; `count` must not be 0.
    mutating func oneIn(_ count: UInt64) -> Bool {
        next() % count == 0
    }
}

/// Draws the random actions of the fuzz test. Ids come from small pools so that actions meet the same rows, and
/// numbers come from the edges of their types (0, 1, -1, 100 and the extremes) as well as from plausible ones. Event
/// numbers mostly follow on from the last, and now and then are repeated, late, jumped or 0, and very rarely the
/// largest there is (which shuts an epoch until the next one); the epoch now and then changes, as a restarted
/// server's would, and is sometimes empty.
struct ActionGenerator {
    private var rng: SplitMix64
    private var epoch = "E1"
    private var nextSeq: UInt64 = 1

    init(seed: UInt64) {
        rng = SplitMix64(seed: seed)
    }

    mutating func next() -> TradingAction {
        switch rng.next() % 100 {
        case 0..<18: .localSubmitted(submission(), createdNs: int64())
        case 18..<22: .submitRejected(clientOrderId: client(), reason: rejectReason())
        case 22..<26: .submitUnconfirmed(clientOrderId: client())
        case 26..<86: .event(event())
        case 86..<99: .account(account(), adoptEventSeq: rng.chance(50))
        default: .clear
        }
    }

    // MARK: Pieces

    private mutating func client() -> String {
        rng.chance(92) ? rng.pick(["C-1", "C-2", "C-3", "C-4", "C-5"]) : ""
    }

    private mutating func order() -> String {
        rng.chance(92) ? rng.pick(["O-000001", "O-000002", "O-000003", "O-000004", "O-000005"]) : ""
    }

    private mutating func int64() -> Int64 {
        rng.pick([0, 1, -1, 100, Int64.min, Int64.max])
    }

    private mutating func quantity() -> Int64 {
        rng.chance(65) ? rng.pick([1, 50, 100, 200, 300]) : int64()
    }

    private mutating func price() -> Int64 {
        rng.chance(65) ? rng.pick([0, 1_000, 3_400, 3_425, 3_450]) : int64()
    }

    private mutating func symbol() -> UInt32 {
        rng.chance(95) ? rng.pick([0, 1, 2, 3]) : UInt32.max
    }

    private mutating func side() -> Tp_Side {
        rng.pick([.buy, .buy, .sell, .sell, .unspecified, .UNRECOGNIZED(9)])
    }

    private mutating func type() -> Tp_OrderType {
        rng.pick([.market, .market, .limit, .limit, .unspecified, .UNRECOGNIZED(9)])
    }

    private mutating func rejectReason() -> RejectReason {
        rng.pick([.invalidQuantity, .invalidLot, .insufficientFunds, .noLiquidity, .invalidDuplicate])
    }

    private mutating func wireReason() -> Tp_RejectReason {
        rng.pick([.unspecified, .invalidQuantity, .insufficientFunds, .noLiquidity, .UNRECOGNIZED(77)])
    }

    private mutating func submission() -> OrderDraft {
        OrderDraft(
            clientOrderId: client(), symbolId: symbol(), side: rng.pick([.buy, .sell]),
            type: rng.pick([.market, .limit]), quantity: quantity(),
            limitPrice: rng.chance(50) ? Price(satang: price()) : nil)
    }

    // MARK: Events

    /// The number and the epoch of the next event.
    private mutating func envelope() -> (seq: UInt64, epoch: String) {
        if rng.oneIn(150) {
            epoch = rng.pick(["E1", "E2", "E3"])
            nextSeq = 1
        }
        let sent = rng.chance(2) ? "" : epoch
        if rng.oneIn(1_000) { return (UInt64.max, sent) }
        guard rng.chance(85) else {
            return (rng.pick([0, 1, 2, nextSeq &- 1, nextSeq &+ 3]), sent)
        }
        let seq = nextSeq
        nextSeq = seq == UInt64.max ? seq : seq + 1
        return (seq, sent)
    }

    private mutating func event() -> Tp_OrderEvent {
        let (seq, sent) = envelope()
        let stamp = int64()
        switch rng.next() % 100 {
        case 0..<4:
            return orderEvent(seq, epoch: sent, tsNs: stamp)
        case 4..<28:
            return acceptedEvent(
                seq, epoch: sent, tsNs: stamp, client: client(), order: order(), symbol: symbol(), side: side(),
                type: type(), quantity: quantity(), limitPrice: rng.chance(50) ? price() : 0)
        case 28..<34:
            return rejectedEvent(seq, epoch: sent, tsNs: stamp, client: client(), reason: wireReason())
        case 34..<66:
            return fillEvent(
                seq, epoch: sent, tsNs: stamp, order: order(), symbol: symbol(), side: side(), quantity: quantity(),
                price: price(), remaining: rng.chance(50) ? 0 : quantity())
        case 66..<78:
            return cancelledEvent(
                seq, epoch: sent, tsNs: stamp, order: order(), remaining: quantity(), reason: wireReason())
        default:
            return ledgerEvent(
                seq, epoch: sent, tsNs: stamp, ledgerSeq: rng.pick([0, 1, 2, 3, 4, 5, UInt64.max]), order: order(),
                symbol: symbol(), side: side(), quantity: quantity(), price: price(), commission: int64(),
                cashDelta: int64(), cashAfter: int64(), positionAfter: rng.chance(60) ? quantity() : int64())
        }
    }

    // MARK: Accounts

    private mutating func account() -> AccountDTO {
        let named = rng.chance(80) ? epoch : rng.pick(["E1", "E2", "E3", ""])
        let listed = (0..<(rng.next() % 5)).map { _ in (symbol(), rng.chance(70) ? quantity() : int64()) }
        let reached = rng.oneIn(200) ? UInt64.max : rng.pick([0, 1, nextSeq &- 1, nextSeq, nextSeq &+ 2])
        return accountSnapshot(
            epoch: named, cash: int64(), positions: listed, lastEventSeq: reached, lastLedgerSeq: rng.next() % 6)
    }
}

/// What the fuzz run did, counted from the states it saw, so that the test can say it really exercised the rules.
struct FuzzTally {
    var fillsApplied = 0
    var ledgerRowsAdded = 0
    var accountsApplied = 0
    var epochChangesSeen = 0
    var rowsMadeFromEvents = 0
    var rowsCancelled = 0
    var rowsCompared = 0

    mutating func record(_ action: TradingAction, from before: TradingState, to after: TradingState) {
        let sameEpoch = after.epoch == before.epoch && after.epochChanges == before.epochChanges
        if after.epochChanges > before.epochChanges { epochChangesSeen += 1 }
        if after.ledger.count > before.ledger.count && sameEpoch { ledgerRowsAdded += 1 }
        if case .account = action, after != before { accountsApplied += 1 }
        if case .event = action, sameEpoch, after.orders.count > before.orders.count { rowsMadeFromEvents += 1 }
        for row in after.orders where sameEpoch {
            guard let old = before.orders.first(where: { $0.id == row.id }) else { continue }
            rowsCompared += 1
            if row.filledQuantity > old.filledQuantity { fillsApplied += 1 }
            if row.status == .cancelled && old.status != .cancelled { rowsCancelled += 1 }
        }
    }
}

/// Whether a row may go from `from` to `to`: forward through its life and never out of an end.
private func mayMove(from: OrderStatus, to: OrderStatus) -> Bool {
    if from == to { return true }
    switch from {
    case .pending: return to == .unknown || to == .accepted || to == .rejected
    case .unknown: return to == .accepted || to == .rejected
    case .accepted: return to == .partiallyFilled || to == .filled || to == .cancelled
    case .partiallyFilled: return to == .filled || to == .cancelled
    case .filled, .cancelled, .rejected: return false
    }
}

/// Every way `after` breaks a promise the reducer makes about any state, given the state `before` the action.
private func violations(from before: TradingState, to after: TradingState) -> [String] {
    var problems: [String] = []
    if Set(after.orders.map(\.id)).count != after.orders.count { problems.append("duplicate order id") }
    if Set(after.ledger.map(\.id)).count != after.ledger.count { problems.append("duplicate ledger id") }
    if after.positions.values.contains(where: { $0 <= 0 }) { problems.append("a position of zero or less is stored") }
    if after.epochChanges < before.epochChanges { problems.append("epochChanges went down") }
    if after.epoch == nil && after.lastEventSeq != 0 { problems.append("a state with no epoch has a sequence") }
    for row in after.orders {
        if row.orderId?.isEmpty == true { problems.append("\(row.id) has an empty server id") }
        if row.filledQuantity < 0 { problems.append("\(row.id) has a negative filledQuantity") }
        if (row.filledQuantity > 0) != (row.averageFillPrice != nil) {
            problems.append("\(row.id): an average exists exactly when something was filled")
        }
        if let average = row.averageFillPrice, average.satang < 0 {
            problems.append("\(row.id) has a negative average")
        }
    }
    guard after.epoch == before.epoch else { return problems }
    if after.lastEventSeq < before.lastEventSeq { problems.append("lastEventSeq went down inside an epoch") }
    guard after.epochChanges == before.epochChanges else { return problems }
    for row in after.orders {
        guard let old = before.orders.first(where: { $0.id == row.id }) else { continue }
        if row.filledQuantity < old.filledQuantity { problems.append("\(row.id): filledQuantity went down") }
        if !mayMove(from: old.status, to: row.status) {
            problems.append("\(row.id): \(old.status) became \(row.status)")
        }
        if old.status == .filled || old.status == .cancelled || old.status == .rejected, row != old {
            problems.append("\(row.id): an ended row changed")
        }
    }
    return problems
}

/// What the rules at the door of an action promise about it, whatever state it meets: an event or account that must
/// be ignored changes nothing, one that is applied leaves the epoch, sequence and cash it carries, and a submission
/// either adds a pending row at the front or is turned away as a repeat.
private func doorViolations(of action: TradingAction, from before: TradingState, to after: TradingState) -> [String] {
    switch action {
    case .event(let event):
        let malformed = event.eventSeq == 0 || event.serverEpoch.isEmpty
        let late = before.epoch == event.serverEpoch && event.eventSeq <= before.lastEventSeq
        if malformed || late { return after == before ? [] : ["an event that must be ignored changed the state"] }
        let kept = after.epoch == event.serverEpoch && after.lastEventSeq == event.eventSeq
        return kept ? [] : ["an applied event left another epoch or sequence"]
    case .account(let account, let adoptEventSeq):
        let stale = before.epoch == account.epoch && account.lastEventSeq < before.lastEventSeq
        if account.epoch.isEmpty || stale {
            return after == before ? [] : ["an account that must be ignored changed the state"]
        }
        var problems: [String] = []
        if after.epoch != account.epoch || after.cash != account.cash {
            problems.append("an applied account left another epoch or cash")
        }
        let restarted = before.epoch != nil && before.epoch != account.epoch
        let expectedSeq = adoptEventSeq ? account.lastEventSeq : (restarted ? 0 : before.lastEventSeq)
        if after.lastEventSeq != expectedSeq { problems.append("an applied account left the wrong lastEventSeq") }
        if !restarted && (after.orders != before.orders || after.ledger != before.ledger) {
            problems.append("an account of the same epoch touched the orders or the ledger")
        }
        return problems
    case .localSubmitted(let draft, _):
        if before.orders.contains(where: { $0.id == draft.clientOrderId }) {
            return after == before ? [] : ["a repeated submission changed the state"]
        }
        let added = after.orders.count == before.orders.count + 1
        let first = after.orders.first
        return added && first?.id == draft.clientOrderId && first?.status == .pending
            ? [] : ["a new submission is not a pending row at the front"]
    case .clear:
        var emptied = TradingState()
        emptied.epochChanges = before.epochChanges
        return after == emptied ? [] : ["clear left something behind or lost the count of epoch changes"]
    case .submitRejected, .submitUnconfirmed:
        return []
    }
}

extension TradingReducerTests {
    // MARK: Random actions

    /// 20,000 random actions, applied one after the other from a fresh state, never trap and never break a promise: the
    /// rows and ledger entries are unique, no position of zero or less is stored, the sequence of an epoch and the
    /// count of epoch changes never go down, a row's filled shares never go down, rows move only forward through
    /// their life, and an ended row never changes. The run must really apply fills, ledger entries and accounts and
    /// cross epochs, or the test fails.
    @Test func randomActionsKeepEveryInvariant() {
        var generator = ActionGenerator(seed: 0x7A11_5EED_0001_C0DE)
        var state = TradingState()
        var tally = FuzzTally()
        for step in 0..<20_000 {
            let action = generator.next()
            let before = state
            TradingReducer.reduce(&state, action)
            let problems = doorViolations(of: action, from: before, to: state) + violations(from: before, to: state)
            guard problems.isEmpty else {
                Issue.record("step \(step), \(problems), after \(action) on \(before)")
                return
            }
            tally.record(action, from: before, to: state)
        }
        // The run is fixed, so these counts are too (219, 837, 1,420, 593, 272, 113 and 65,119); the floors are about
        // half of them.
        #expect(tally.fillsApplied > 100)
        #expect(tally.ledgerRowsAdded > 400)
        #expect(tally.accountsApplied > 700)
        #expect(tally.epochChangesSeen > 300)
        #expect(tally.rowsMadeFromEvents > 130)
        #expect(tally.rowsCancelled > 50)
        #expect(tally.rowsCompared > 30_000)
    }

    /// The generator gives the sequence of the published SplitMix64 reference for seed 0, so the run above draws the
    /// same actions on every machine and a failure of it can be reproduced.
    @Test func theGeneratorFollowsTheSplitMix64Reference() {
        var generator = SplitMix64(seed: 0)
        #expect(generator.next() == 0xE220_A839_7B1D_CDAF)
        #expect(generator.next() == 0x6E78_9E6A_A1B9_65F4)
        #expect(generator.next() == 0x06C4_5D18_8009_454F)
    }
}

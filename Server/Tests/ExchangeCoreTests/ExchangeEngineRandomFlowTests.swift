import Testing
import TradeCore
@testable import ExchangeCore

/// What one operation of the random flow did.
private enum OperationKind: CaseIterable {
    case limitAccepted, marketAccepted, rejectedForFunds, rejectedForPosition, rejectedAsInvalid
    case duplicateReplayed, duplicateRefused, cancelSucceeded, cancelRefused, advanceFilled, advanceQuiet
}

/// The symbols the random flow trades: three, so that orders meet each other's fills often.
private let flowSymbols = Array(catalogSymbols.prefix(3))

/// Draws one order from `generator` near the current quote of a random flow symbol.
private func randomOrder(
    _ clientOrderId: String, quotes: [SymbolQuote], using generator: inout SeededGenerator
) -> OrderRequest {
    let quote = quotes[generator.below(quotes.count)]
    let side: Side = generator.below(2) == 0 ? .buy : .sell
    let isMarket = generator.below(3) == 0
    var quantity = Quantity(100 * (1 + generator.below(30)))
    switch generator.below(40) {
    case 0: quantity = 150
    case 1: quantity = 2_000_000
    default: break
    }
    let anchor = side == .buy ? quote.ask : quote.bid
    let ticks = generator.below(9) - 5
    let limit = ticks < 0 ? PriceGrid.down(anchor, ticks: -ticks) : PriceGrid.up(anchor, ticks: ticks)
    return OrderRequest(
        clientOrderId: clientOrderId, symbolId: quote.symbolId, side: side, type: isMarket ? .market : .limit,
        quantity: quantity, limitPrice: isMarket ? nil : limit
    )
}

/// What every order of a log adds up to, checked record by record: `accepted` comes before an order's fills, each
/// fill is followed at once by its ledger event for the same shares, and each fill's `remaining` is the order's
/// quantity less all its fills so far. Returns a description of what is wrong (empty if all is well).
private func orderProblems(_ records: [OrderEventRecord]) -> [String] {
    var problems: [String] = []
    var quantities: [String: Quantity] = [:]
    var filled: [String: Quantity] = [:]
    for (index, record) in records.enumerated() {
        switch record.payload {
        case .accepted(let orderId, _, _, _, _, let quantity, _):
            quantities[orderId] = quantity
        case .fill(let orderId, _, _, let quantity, let price, let remaining):
            guard let ordered = quantities[orderId] else {
                problems.append("seq \(record.seq): a fill before \(orderId) was accepted")
                continue
            }
            let total = filled[orderId, default: 0] + quantity
            filled[orderId] = total
            if ordered - total != remaining {
                problems.append("seq \(record.seq): \(orderId) has \(remaining) left after \(total) of \(ordered)")
            }
            let next = index + 1 < records.count ? records[index + 1] : nil
            guard let next, next.seq == record.seq + 1, case .ledger(let entry) = next.payload,
                  entry.orderId == orderId, entry.quantity == quantity, entry.price == price
            else {
                problems.append("seq \(record.seq): the fill is not followed by its ledger event")
                continue
            }
        default:
            break
        }
    }
    return problems
}

extension ExchangeEngineTests {
    @Test func randomOrderFlowKeepsLedgerInvariants() async throws {
        let engine = makeEngine(symbols: flowSymbols, eventLogCapacity: 100_000)
        var generator = SeededGenerator(seed: 2_024)
        var counts: [OperationKind: Int] = [:]
        var requests: [OrderRequest] = []
        var acceptedCount = 0
        var stepProblems: [String] = []
        var atMs = marketStartMs

        for step in 1...2_000 {
            let seqBefore = await engine.account().lastEventSeq
            let roll = generator.below(100)
            let kind: OperationKind
            if roll < 45 {
                var request = randomOrder("c\(step)", quotes: await engine.quotes(), using: &generator)
                let isDuplicate = !requests.isEmpty && generator.below(20) == 0
                if isDuplicate {
                    request = requests[generator.below(requests.count)]
                }
                let refuse = isDuplicate && generator.below(2) == 0
                if refuse {
                    request = OrderRequest(
                        clientOrderId: request.clientOrderId, symbolId: request.symbolId, side: request.side,
                        type: request.type, quantity: request.quantity + 100, limitPrice: request.limitPrice
                    )
                }
                let outcome = await engine.submit(request)
                let appended = await engine.account().lastEventSeq - seqBefore
                switch (outcome, isDuplicate) {
                case (.rejected(.invalidDuplicate, _), true) where refuse: kind = .duplicateRefused
                case (_, true): kind = .duplicateReplayed
                case (.accepted, _): kind = request.type == .limit ? .limitAccepted : .marketAccepted
                case (.rejected(.insufficientFunds, _), _): kind = .rejectedForFunds
                case (.rejected(.insufficientPosition, _), _): kind = .rejectedForPosition
                case (.rejected, _): kind = .rejectedAsInvalid
                }
                if kind == .duplicateReplayed && appended != 0 {
                    stepProblems.append("step \(step): a replayed duplicate appended \(appended) events")
                }
                if !isDuplicate {
                    requests.append(request)
                    if case .accepted = outcome { acceptedCount += 1 }
                }
            } else if roll < 60 {
                let number = 1 + generator.below(acceptedCount + 3)
                let digits = String(number)
                let id = "O-" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
                kind = await engine.cancel(orderId: id) ? .cancelSucceeded : .cancelRefused
            } else {
                atMs += Int64(1 + generator.below(1_000))
                _ = await engine.advance(toMs: atMs, updatesPerSymbolPerSecond: 20)
                let appended = try await loggedPayloads(engine, after: seqBefore)
                kind = fills(in: appended).isEmpty ? .advanceQuiet : .advanceFilled
            }
            counts[kind, default: 0] += 1

            let ledger = await engine.ledgerSnapshot()
            if !ledger.invariantsHold() || ledger.cash < 0 || ledger.positions.values.contains(where: { $0 < 0 }) {
                stepProblems.append("step \(step) (\(kind)): the ledger is unsound")
            }
        }

        #expect(stepProblems.isEmpty, "\(stepProblems.prefix(5))")
        let missing = OperationKind.allCases.filter { counts[$0, default: 0] == 0 }
        #expect(missing.isEmpty, "never happened: \(missing); counts: \(counts)")

        let account = await engine.account()
        #expect(account.cash >= 0)
        #expect(account.positions.values.allSatisfy { $0 > 0 })
        let transactions = await engine.transactions(before: nil, limit: .max)
        #expect(transactions.count == Int(account.lastLedgerSeq))
        #expect(transactions.reduce(0) { $0 + $1.cashDelta } == account.cash - defaultStartingCash)
        let records = try await loggedEvents(engine)
        #expect(records.map(\.seq) == Array(stride(from: UInt64(1), through: account.lastEventSeq, by: 1)))
        let problems = orderProblems(records)
        #expect(problems.isEmpty, "\(problems.prefix(5))")
    }
}

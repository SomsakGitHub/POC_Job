import Testing
import TradeCore
@testable import ExchangeCore

/// Cash large enough that no test order is stopped by it: 10,000,000,000.00 baht.
let ampleCash: Int64 = 1_000_000_000_000

@Suite struct ExchangeEngineTests {
    @Test func marketBuyFillsAndUpdatesLedger() async throws {
        let engine = makeEngine()
        let quote = try await currentQuote(engine)
        let outcome = await engine.submit(order("c1", .buy, .market, 100))
        #expect(acceptedId(outcome) == "O-000001")

        let records = try await loggedEvents(engine)
        #expect(records.map(\.seq) == [1, 2, 3])
        let ledger = await engine.ledgerSnapshot()
        let entry = try #require(ledger.entries.first)
        let expected: [OrderEventPayload] = [
            .accepted(
                orderId: "O-000001", clientOrderId: "c1", symbolId: ptt.id, side: .buy, type: .market, quantity: 100,
                limitPrice: nil
            ),
            .fill(orderId: "O-000001", symbolId: ptt.id, side: .buy, quantity: 100, price: quote.ask, remaining: 0),
            .ledger(entry),
        ]
        #expect(records.map(\.payload) == expected)

        let notional = quote.ask.satang * 100
        let commission = Commission.compute(notional: notional, bps: 15)
        #expect(commission > 0)
        let account = await engine.account()
        #expect(account.cash == defaultStartingCash - notional - commission)
        #expect(account.positions == [ptt.id: 100])
        #expect(entry.orderId == "O-000001" && entry.quantity == 100 && entry.price == quote.ask)
        #expect(ledger.availableCash == ledger.cash)
        #expect(ledger.invariantsHold())
    }

    @Test func limitBuyRestsThenFillsWhenPriceCrosses() async throws {
        let engine = makeEngine(startingCash: ampleCash)
        let quote = try await currentQuote(engine)
        let limit = quote.bid
        let quantity: Quantity = 1_000_000
        let id = try await submitAccepted(engine, order("c1", .buy, .limit, quantity, limit: limit.satang))
        let resting = try await loggedPayloads(engine)
        #expect(resting.count == 1)
        #expect(fills(in: resting).isEmpty)

        let firstFound = try await advanceUntil(engine, fromMs: marketStartMs) { !fills(in: $0).isEmpty }
        let first = try #require(firstFound)
        let firstFills = fills(in: first.payloads)
        let shown = try await currentQuote(engine)
        #expect(firstFills.count == 1)
        #expect(firstFills.first?.orderId == id)
        #expect(firstFills.first?.price == limit)
        #expect(shown.ask <= limit)
        #expect(firstFills.first?.quantity == shown.askQty)
        let afterFirst = quantity - shown.askQty
        #expect(firstFills.first?.remaining == afterFirst)

        let secondFound = try await advanceUntil(engine, fromMs: first.atMs) { !fills(in: $0).isEmpty }
        let second = try #require(secondFound)
        let secondFill = try #require(fills(in: second.payloads).first)
        #expect(secondFill.price == limit)
        #expect(secondFill.remaining == afterFirst - secondFill.quantity)
        let ledger = await engine.ledgerSnapshot()
        #expect(ledger.entries.count == 2)
        #expect(ledger.entries.allSatisfy { $0.price == limit && $0.orderId == id })
        #expect(ledger.invariantsHold())
    }

    @Test func cancelReleasesReservation() async throws {
        let engine = makeEngine()
        let quote = try await currentQuote(engine)
        let id = try await submitAccepted(engine, order("c1", .buy, .limit, 1_000, limit: quote.bid.satang))
        let reserved = await engine.ledgerSnapshot()
        #expect(reserved.availableCash < defaultStartingCash)

        let cancelled = await engine.cancel(orderId: id)
        #expect(cancelled)
        let payloads = try await loggedPayloads(engine)
        #expect(payloads.last == .cancelled(orderId: id, remaining: 1_000, reason: nil))
        let released = await engine.ledgerSnapshot()
        #expect(released.availableCash == defaultStartingCash)
        #expect(released.cash == defaultStartingCash)

        let lastSeq = await engine.account().lastEventSeq
        let again = await engine.cancel(orderId: id)
        #expect(!again)
        let lastSeqAfter = await engine.account().lastEventSeq
        #expect(lastSeqAfter == lastSeq)
    }

    @Test func marketRemainderCancelledNoLiquidity() async throws {
        let engine = makeEngine(startingCash: ampleCash)
        let quote = try await currentQuote(engine)
        let quantity: Quantity = 10_000_000
        let id = try await submitAccepted(engine, order("c1", .buy, .market, quantity))

        let records = try await loggedEvents(engine)
        #expect(!records.isEmpty)
        #expect(records.map(\.seq) == Array(stride(from: UInt64(1), through: UInt64(records.count), by: 1)))
        let swept = fills(in: records.map(\.payload))
        #expect(swept.count >= 2)
        #expect(swept.first?.price == quote.ask)
        #expect(swept.first?.quantity == quote.askQty)
        #expect(zip(swept, swept.dropFirst()).allSatisfy { $0.price < $1.price })
        let filled = swept.reduce(0) { $0 + $1.quantity }
        #expect(filled < quantity)
        #expect(records.last?.payload == .cancelled(orderId: id, remaining: quantity - filled, reason: .noLiquidity))

        let ledger = await engine.ledgerSnapshot()
        #expect(ledger.positions == [ptt.id: filled])
        #expect(ledger.availableCash == ledger.cash)
        #expect(ledger.invariantsHold())
        let after = try await currentQuote(engine)
        #expect(after.askQty == 0)
    }

    @Test func rejectsInvalidInputsWithoutTouchingLedger() async throws {
        let engine = makeEngine()
        // A position of 100 shares, so that selling more than that is a case of its own.
        _ = await engine.submit(order("setup", .buy, .market, 100))
        let reference = ptt.reference.satang
        let band = TickRules.band(reference: ptt.reference)
        let belowBand = PriceGrid.down(PriceGrid.snappedUp(band.lowerBound)).satang
        let aboveBand = PriceGrid.up(PriceGrid.snappedDown(band.upperBound)).satang
        let cases: [(OrderRequest, RejectReason)] = [
            (order("q0", .buy, .limit, 0, limit: reference), .invalidQuantity),
            (order("qneg", .buy, .limit, -100, limit: reference), .invalidQuantity),
            (order("q150", .buy, .limit, 150, limit: reference), .invalidLot),
            (order("qbig", .buy, .market, 20_000_000), .invalidQuantity),
            (order("offtick", .buy, .limit, 100, limit: reference + 1), .invalidTick),
            (order("nolimit", .buy, .limit, 100), .invalidTick),
            (order("zerolimit", .buy, .limit, 100, limit: 0), .invalidTick),
            (order("neglimit", .buy, .limit, 100, limit: -reference), .invalidTick),
            (order("below", .buy, .limit, 100, limit: belowBand), .outsidePriceBand),
            (order("above", .sell, .limit, 100, limit: aboveBand), .outsidePriceBand),
            (order("unknown", .buy, .market, 100, symbol: 99), .unknownSymbol),
            (order("funds", .buy, .limit, 1_000_000, limit: reference), .insufficientFunds),
            (order("noposition", .sell, .market, 100, symbol: 2), .insufficientPosition),
            (order("noposition-limit", .sell, .limit, 100, limit: 5800, symbol: 2), .insufficientPosition),
            (order("overposition", .sell, .market, 200), .insufficientPosition),
            // The checks run in a fixed order and the first failure wins.
            (order("unknown-first", .buy, .limit, 0, limit: 1, symbol: 99), .unknownSymbol),
            (order("lot-before-tick", .buy, .limit, 150, limit: reference + 1), .invalidLot),
            (order("tick-before-position", .sell, .limit, 100, limit: 5801, symbol: 2), .invalidTick),
            (order("band-before-funds", .buy, .limit, 1_000_000, limit: belowBand), .outsidePriceBand),
        ]
        let ledgerBefore = await engine.ledgerSnapshot()
        let before = await engine.account()
        for (index, (request, reason)) in cases.enumerated() {
            let outcome = await engine.submit(request)
            #expect(rejectReason(outcome) == reason, "\(request.clientOrderId)")
            let account = await engine.account()
            #expect(account.cash == before.cash && account.positions == before.positions)
            #expect(account.lastLedgerSeq == before.lastLedgerSeq)
            #expect(account.lastEventSeq == before.lastEventSeq + UInt64(index) + 1, "\(request.clientOrderId)")
            let last = try await loggedPayloads(engine, after: account.lastEventSeq - 1)
            #expect(last == [.rejected(clientOrderId: request.clientOrderId, reason: reason)])
        }
        let ledgerAfter = await engine.ledgerSnapshot()
        #expect(ledgerAfter == ledgerBefore)

        // The edges of the band are inside it.
        let lowEdge = PriceGrid.snappedUp(band.lowerBound).satang
        let highEdge = PriceGrid.snappedDown(band.upperBound).satang
        let atLowEdge = await engine.submit(order("low-edge", .buy, .limit, 100, limit: lowEdge))
        let atHighEdge = await engine.submit(order("high-edge", .buy, .limit, 100, limit: highEdge))
        #expect(acceptedId(atLowEdge) != nil)
        #expect(acceptedId(atHighEdge) != nil)
    }

    @Test func duplicateClientOrderIdReturnsOriginalOutcome() async throws {
        let engine = makeEngine()
        let quote = try await currentQuote(engine)
        let request = order("c1", .buy, .limit, 500, limit: quote.bid.satang)
        let original = await engine.submit(request)
        #expect(acceptedId(original) == "O-000001")
        let ledgerBefore = await engine.ledgerSnapshot()
        let seqBefore = await engine.account().lastEventSeq

        let repeated = await engine.submit(request)
        #expect(repeated == original)
        let seqAfterRepeat = await engine.account().lastEventSeq
        #expect(seqAfterRepeat == seqBefore)
        let payloads = try await loggedPayloads(engine)
        let accepted = payloads.filter { if case .accepted = $0 { true } else { false } }
        #expect(accepted.count == 1)

        let changed = order("c1", .buy, .limit, 600, limit: quote.bid.satang)
        let duplicate = await engine.submit(changed)
        #expect(rejectReason(duplicate) == .invalidDuplicate)
        #expect(timing(duplicate) != timing(original))
        let ledgerAfter = await engine.ledgerSnapshot()
        #expect(ledgerAfter == ledgerBefore)
        let third = await engine.submit(request)
        #expect(third == original)
    }

    @Test func eventStreamReplaysThenGoesLive() async throws {
        let engine = makeEngine()
        _ = await engine.submit(order("r1", .buy, .limit, 150))
        _ = await engine.submit(order("r2", .buy, .limit, 150))
        let epoch = await engine.epoch
        let stream = try await engine.eventStream(after: 0, clientEpoch: epoch)
        _ = await engine.submit(order("r3", .buy, .limit, 150))
        let received = await firstRecords(of: stream, count: 3).records
        #expect(received.map(\.seq) == [1, 2, 3])
        let expected: [OrderEventPayload] = ["r1", "r2", "r3"].map { .rejected(clientOrderId: $0, reason: .invalidLot) }
        #expect(received.map(\.payload) == expected)
        #expect(received.allSatisfy { $0.epoch == epoch })
    }

    @Test func eventStreamResumesAfterSeq() async throws {
        let engine = makeEngine()
        for n in 1...5 {
            _ = await engine.submit(order("r\(n)", .buy, .limit, 150))
        }
        let resumed = try await loggedEvents(engine, after: 3)
        #expect(resumed.map(\.seq) == [4, 5])
        #expect(resumed.first?.payload == .rejected(clientOrderId: "r4", reason: .invalidLot))
    }

    @Test func eventStreamOutOfRangeWhenTooOld() async throws {
        let engine = makeEngine(eventLogCapacity: 10)
        for n in 1...25 {
            _ = await engine.submit(order("r\(n)", .buy, .limit, 150))
        }
        let epoch = await engine.epoch
        await #expect(throws: EventLogError.outOfRange(oldestRetained: 16)) {
            _ = try await engine.eventStream(after: 2, clientEpoch: epoch)
        }
        // Another epoch asks for the whole log, which no longer starts at 1.
        await #expect(throws: EventLogError.outOfRange(oldestRetained: 16)) {
            _ = try await engine.eventStream(after: 20, clientEpoch: "another")
        }
        let tail = try await loggedEvents(engine, after: 15)
        #expect(tail.map(\.seq) == Array(16...25))
    }

    @Test func eventStreamIgnoresSeqWhenEpochDiffers() async throws {
        let engine = makeEngine()
        for n in 1...3 {
            _ = await engine.submit(order("r\(n)", .buy, .limit, 150))
        }
        for clientEpoch in ["another", nil] as [String?] {
            let stream = try await engine.eventStream(after: 2, clientEpoch: clientEpoch)
            let received = await firstRecords(of: stream, count: 3).records
            #expect(received.map(\.seq) == [1, 2, 3])
        }
    }

    @Test func resetStartsNewEpochAndFinishesStreams() async throws {
        let engine = makeEngine()
        let quote = try await currentQuote(engine)
        _ = await engine.submit(order("c1", .buy, .market, 100))
        _ = await engine.submit(order("c2", .buy, .limit, 100, limit: quote.bid.satang))
        let oldEpoch = await engine.epoch
        let oldStream = try await engine.eventStream(after: 0, clientEpoch: oldEpoch)

        await engine.reset()
        let (oldRecords, ended) = await firstRecords(of: oldStream, count: 100)
        #expect(ended)
        #expect(oldRecords.count == 4)
        #expect(oldRecords.allSatisfy { $0.epoch == oldEpoch })

        let newEpoch = await engine.epoch
        #expect(newEpoch != oldEpoch)
        let account = await engine.account()
        #expect(account == AccountSnapshot(
            epoch: newEpoch, cash: defaultStartingCash, positions: [:], lastEventSeq: 0, lastLedgerSeq: 0
        ))
        let outcome = await engine.submit(order("c1", .buy, .limit, 100, limit: quote.bid.satang))
        #expect(acceptedId(outcome) == "O-000001")
        let records = try await loggedEvents(engine)
        #expect(records.map(\.seq) == [1])
        #expect(records.first?.epoch == newEpoch)
    }
}

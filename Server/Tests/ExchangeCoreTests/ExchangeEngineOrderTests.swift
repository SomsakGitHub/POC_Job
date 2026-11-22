import Testing
import TradeCore
@testable import ExchangeCore

/// Order handling: market and limit orders against the book, resting fills, cancels, duplicates and timing.
extension ExchangeEngineTests {
    @Test func marketSellFillsAgainstTheBidsAndRemovesAClosedPosition() async throws {
        let engine = makeEngine()
        _ = await engine.submit(order("buy", .buy, .market, 100))
        let quote = try await currentQuote(engine)
        let cashBefore = await engine.account().cash
        let seqBefore = await engine.account().lastEventSeq
        let id = try await submitAccepted(engine, order("sell", .sell, .market, 100))

        let sold = fills(in: try await loggedPayloads(engine, after: seqBefore))
        #expect(sold.count == 1)
        #expect(sold.first?.orderId == id && sold.first?.price == quote.bid && sold.first?.remaining == 0)
        let ledger = await engine.ledgerSnapshot()
        #expect(ledger.positions.isEmpty)
        let entry = try #require(ledger.entries.last)
        #expect(entry.side == .sell && entry.positionAfter == 0)
        let proceeds = quote.bid.satang * 100
        #expect(ledger.cash == cashBefore + proceeds - Commission.compute(notional: proceeds, bps: 15))
        #expect(ledger.invariantsHold())
    }

    @Test func sellWithoutFreeSharesIsRejectedUpFrontEvenWhenTheBidsAreEmpty() async throws {
        let engine = makeEngine(startingCash: ampleCash)
        // Three sweeps of the asks, with the book refilled in between, buy more shares than the bids hold.
        var atMs = marketStartMs
        for n in 1...3 {
            _ = await engine.submit(order("buy\(n)", .buy, .market, 10_000_000))
            atMs += 1
            _ = await engine.advance(toMs: atMs, updatesPerSymbolPerSecond: 0)
        }
        let bought = await engine.ledgerSnapshot()
        let held = try #require(bought.positions[ptt.id])
        // A limit sell of every share at the bottom of the band takes all the bids and rests with the rest.
        let floor = PriceGrid.snappedUp(TickRules.band(reference: ptt.reference).lowerBound).satang
        let seqBefore = await engine.account().lastEventSeq
        _ = await engine.submit(order("sweep", .sell, .limit, held, limit: floor))
        let swept = fills(in: try await loggedPayloads(engine, after: seqBefore))
        try #require((swept.last?.remaining ?? 0) > 0)
        let quote = try await currentQuote(engine)
        try #require(quote.bidQty == 0)
        let ledgerBefore = await engine.ledgerSnapshot()
        #expect(ledgerBefore.availableQuantity(symbolId: ptt.id) == 0)
        let outcome = await engine.submit(order("again", .sell, .market, 100))
        #expect(rejectReason(outcome) == .insufficientPosition)
        let ledgerAfter = await engine.ledgerSnapshot()
        #expect(ledgerAfter == ledgerBefore)
    }

    @Test func marketOrderAgainstAnEmptySideIsAcceptedThenCancelledAndReservesNothing() async throws {
        let engine = makeEngine(startingCash: ampleCash)
        _ = await engine.submit(order("sweep", .buy, .market, 10_000_000))
        let ledgerBefore = await engine.ledgerSnapshot()
        let seqBefore = await engine.account().lastEventSeq
        let outcome = await engine.submit(order("empty", .buy, .market, 100))
        #expect(acceptedId(outcome) == "O-000002")
        let payloads = try await loggedPayloads(engine, after: seqBefore)
        #expect(payloads == [
            .accepted(
                orderId: "O-000002", clientOrderId: "empty", symbolId: ptt.id, side: .buy, type: .market, quantity: 100,
                limitPrice: nil
            ),
            .cancelled(orderId: "O-000002", remaining: 100, reason: .noLiquidity),
        ])
        let ledgerAfter = await engine.ledgerSnapshot()
        #expect(ledgerAfter == ledgerBefore)
    }

    @Test func marketOrderIgnoresItsLimitPrice() async throws {
        let engine = makeEngine()
        let quote = try await currentQuote(engine)
        let outcome = await engine.submit(order("m", .buy, .market, 100, limit: 1))
        #expect(acceptedId(outcome) == "O-000001")
        #expect(fills(in: try await loggedPayloads(engine)).first?.price == quote.ask)
    }

    @Test func marketableLimitSweepsThenRests() async throws {
        let engine = makeEngine(startingCash: ampleCash)
        let quote = try await currentQuote(engine)
        let limit = quote.ask
        let quantity = quote.askQty + 1_000_000
        let id = try await submitAccepted(engine, order("c1", .buy, .limit, quantity, limit: limit.satang))

        let payloads = try await loggedPayloads(engine)
        let ledger = await engine.ledgerSnapshot()
        let entry = try #require(ledger.entries.first)
        #expect(payloads == [
            .accepted(
                orderId: id, clientOrderId: "c1", symbolId: ptt.id, side: .buy, type: .limit, quantity: quantity,
                limitPrice: limit
            ),
            .fill(
                orderId: id, symbolId: ptt.id, side: .buy, quantity: quote.askQty, price: limit, remaining: 1_000_000
            ),
            .ledger(entry),
        ])
        // The sweep took the best ask out of the live book.
        let after = try await currentQuote(engine)
        #expect(after.ask > limit)

        let laterFound = try await advanceUntil(engine, fromMs: marketStartMs) { !fills(in: $0).isEmpty }
        let later = try #require(laterFound)
        let restingFill = try #require(fills(in: later.payloads).first)
        #expect(restingFill.orderId == id && restingFill.price == limit)
        #expect(restingFill.remaining == 1_000_000 - restingFill.quantity)
    }

    @Test func restingOrdersShareTheBestLevel() async throws {
        let engine = makeEngine(startingCash: ampleCash)
        let limit = try await currentQuote(engine).bid.satang
        let small = try await submitAccepted(engine, order("a", .buy, .limit, 100, limit: limit))
        let large = try await submitAccepted(engine, order("b", .buy, .limit, 1_000_000, limit: limit))

        let stepFound = try await advanceUntil(engine, fromMs: marketStartMs) { !fills(in: $0).isEmpty }
        let step = try #require(stepFound)
        let shown = try await currentQuote(engine).askQty
        let stepFills = fills(in: step.payloads)
        #expect(stepFills.first?.orderId == small && stepFills.first?.quantity == 100)
        #expect(stepFills.reduce(0) { $0 + $1.quantity } == shown)
        #expect(stepFills.allSatisfy { $0.orderId == small || $0.orderId == large })
    }

    @Test func restingSellsShareTheBestBid() async throws {
        let engine = makeEngine(startingCash: ampleCash)
        _ = await engine.submit(order("buy", .buy, .market, 10_000_000))
        let bought = await engine.ledgerSnapshot()
        let held = try #require(bought.positions[ptt.id])
        let quote = try await currentQuote(engine)
        // The first sell takes the whole best bid and rests with 100 shares; the second rests with the rest. A step
        // with no trades refills the bid at the same price, so both can fill on the next call.
        let limit = quote.bid.satang
        let first = try await submitAccepted(engine, order("a", .sell, .limit, quote.bidQty + 100, limit: limit))
        let rest = held - quote.bidQty - 100
        let second = try await submitAccepted(engine, order("b", .sell, .limit, rest, limit: limit))
        let seqBefore = await engine.account().lastEventSeq
        _ = await engine.advance(toMs: marketStartMs + 1, updatesPerSymbolPerSecond: 0)
        let shown = try await currentQuote(engine)
        try #require(shown.bid == quote.bid && shown.bidQty > 100 && rest > shown.bidQty)
        let stepFills = fills(in: try await loggedPayloads(engine, after: seqBefore))
        #expect(stepFills.map(\.orderId) == [first, second])
        #expect(stepFills.map(\.quantity) == [100, shown.bidQty - 100])
    }

    @Test func restingOrdersAreServedInOrderOfAcceptance() async throws {
        let engine = makeEngine(startingCash: ampleCash)
        let quote = try await currentQuote(engine)
        let limit = quote.ask.satang
        // The first order takes the whole best ask and rests; the later ones, at the same limit, find nothing left to
        // sweep and rest too. A step with no trades refills the ask at the same price, so all of them could fill on
        // the next call, and the oldest takes everything it shows.
        var ids = [try await submitAccepted(engine, order("c0", .buy, .limit, quote.askQty + 1_000_000, limit: limit))]
        for n in 1...3 {
            ids.append(try await submitAccepted(engine, order("c\(n)", .buy, .limit, 1_000_000, limit: limit)))
        }
        for step in 1...3 {
            let seqBefore = await engine.account().lastEventSeq
            _ = await engine.advance(toMs: marketStartMs + Int64(step), updatesPerSymbolPerSecond: 0)
            let shown = try await currentQuote(engine)
            try #require(shown.ask == quote.ask && shown.askQty > 0)
            let stepFills = fills(in: try await loggedPayloads(engine, after: seqBefore))
            #expect(stepFills.map(\.orderId) == [ids[0]], "step \(step)")
        }
    }

    @Test func cancelOfAPartlyFilledOrderKeepsItsFills() async throws {
        let engine = makeEngine(startingCash: ampleCash)
        let limit = try await currentQuote(engine).bid.satang
        let id = try await submitAccepted(engine, order("c1", .buy, .limit, 1_000_000, limit: limit))
        let stepFound = try await advanceUntil(engine, fromMs: marketStartMs) { !fills(in: $0).isEmpty }
        let step = try #require(stepFound)
        let filled = try #require(fills(in: step.payloads).first).quantity

        let cancelled = await engine.cancel(orderId: id)
        #expect(cancelled)
        let lastSeq = await engine.account().lastEventSeq
        let last = try await loggedPayloads(engine, after: lastSeq - 1)
        #expect(last == [.cancelled(orderId: id, remaining: 1_000_000 - filled, reason: nil)])
        let ledger = await engine.ledgerSnapshot()
        #expect(ledger.entries.count == 1)
        #expect(ledger.positions == [ptt.id: filled])
        #expect(ledger.availableCash == ledger.cash)
        #expect(ledger.invariantsHold())
    }

    @Test func cancelOfAnUnknownFinishedOrMarketOrderIsFalse() async throws {
        let engine = makeEngine()
        let market = try await submitAccepted(engine, order("m", .buy, .market, 100))
        // Read after the market order, which may have emptied the best ask level.
        let quote = try await currentQuote(engine)
        let filledLimit = try await submitAccepted(engine, order("l", .buy, .limit, 100, limit: quote.ask.satang))
        let resting = try await submitAccepted(engine, order("r", .buy, .limit, 100, limit: quote.bid.satang))
        let cancelledResting = await engine.cancel(orderId: resting)
        #expect(cancelledResting)
        let seqBefore = await engine.account().lastEventSeq
        let ledgerBefore = await engine.ledgerSnapshot()
        for id in ["O-999999", "", market, filledLimit, resting] {
            let cancelled = await engine.cancel(orderId: id)
            #expect(!cancelled, "\(id)")
        }
        let seqAfter = await engine.account().lastEventSeq
        #expect(seqAfter == seqBefore)
        let ledgerAfter = await engine.ledgerSnapshot()
        #expect(ledgerAfter == ledgerBefore)
    }

    @Test func duplicateOfARejectedRequestReturnsTheOriginalRejection() async throws {
        let engine = makeEngine()
        let request = order("c1", .buy, .limit, 150, limit: ptt.reference.satang)
        let original = await engine.submit(request)
        #expect(rejectReason(original) == .invalidLot)
        let repeated = await engine.submit(request)
        #expect(repeated == original)
        let seq = await engine.account().lastEventSeq
        #expect(seq == 1)
    }

    @Test func invalidDuplicateAppendsOneEventAndLeavesTheOriginalInForce() async throws {
        let engine = makeEngine()
        let request = order("c1", .buy, .limit, 100, limit: ptt.reference.satang - 100)
        let original = await engine.submit(request)
        let ledgerBefore = await engine.ledgerSnapshot()
        for n in 1...2 {
            let seqBefore = await engine.account().lastEventSeq
            let outcome = await engine.submit(order("c1", .sell, .limit, 100, limit: ptt.reference.satang))
            #expect(rejectReason(outcome) == .invalidDuplicate, "attempt \(n)")
            let appended = try await loggedPayloads(engine, after: seqBefore)
            #expect(appended == [.rejected(clientOrderId: "c1", reason: .invalidDuplicate)])
        }
        let ledgerAfter = await engine.ledgerSnapshot()
        #expect(ledgerAfter == ledgerBefore)
        let again = await engine.submit(request)
        #expect(again == original)
    }

    @Test func rejectionsConsumeNoOrderId() async throws {
        let engine = makeEngine()
        let limit = ptt.reference.satang - 100
        _ = await engine.submit(order("bad1", .buy, .limit, 150, limit: limit))
        let first = await engine.submit(order("good1", .buy, .limit, 100, limit: limit))
        _ = await engine.submit(order("bad2", .buy, .limit, 1_000_000, limit: limit))
        let second = await engine.submit(order("good2", .buy, .limit, 100, limit: limit))
        #expect(acceptedId(first) == "O-000001")
        #expect(acceptedId(second) == "O-000002")
    }

    @Test func timingIsTheInjectedClockReadings() async throws {
        let clock = FakeClock()
        let engine = makeEngine(clock: clock)
        let step = clock.stepNs

        // A market order that fills once: a reading for receipt, one for `accepted`, one shared by the fill, its
        // ledger entry and its ledger event, and one for the acknowledgement.
        let t0 = clock.upcoming
        let filled = await engine.submit(order("m", .buy, .market, 100))
        #expect(timing(filled) == ServerTimingNs(recvNs: t0, ackNs: t0 + 3 * step))
        let records = try await loggedEvents(engine)
        #expect(records.map(\.tsNs) == [t0 + step, t0 + 2 * step, t0 + 2 * step])
        let ledger = await engine.ledgerSnapshot()
        let entry = try #require(ledger.entries.first)
        #expect(entry.tsNs == t0 + 2 * step)

        // A rejection: receipt, the `rejected` event, the acknowledgement.
        let t1 = clock.upcoming
        let rejected = await engine.submit(order("bad", .buy, .limit, 150))
        #expect(timing(rejected) == ServerTimingNs(recvNs: t1, ackNs: t1 + 2 * step))
        let rejectedRecord = try await loggedEvents(engine, after: 3)
        #expect(rejectedRecord.map(\.tsNs) == [t1 + step])
    }
}

import Testing
import TradeCore
@testable import ExchangeCore

/// Waits, a bounded number of times, for the engine to drop the streams that ended; returns the count it settled at.
private func settledStreamCount(_ engine: ExchangeEngine) async -> Int {
    for _ in 0..<10_000 {
        let count = await engine.liveStreamCount
        if count == 0 { return 0 }
        await Task.yield()
    }
    return await engine.liveStreamCount
}

/// The same orders, cancels and steps for any engine, returning every outcome and cancel result in order.
private func runScript(_ engine: ExchangeEngine) async -> [String] {
    var results: [String] = []
    var atMs = marketStartMs
    let bid = await engine.quotes().first?.bid.satang ?? ptt.reference.satang
    results.append("\(await engine.submit(order("a", .buy, .limit, 2_000, limit: bid)))")
    results.append("\(await engine.submit(order("b", .buy, .market, 300)))")
    results.append("\(await engine.submit(order("c", .sell, .limit, 100, limit: bid + 50)))")
    results.append("\(await engine.submit(order("d", .buy, .limit, 150, limit: bid)))")
    for step in 1...40 {
        atMs += 500
        let changed = await engine.advance(toMs: atMs, updatesPerSymbolPerSecond: 20)
        results.append("\(changed)")
        if step == 20 {
            results.append("\(await engine.cancel(orderId: "O-000001"))")
            results.append("\(await engine.submit(order("e", .sell, .market, 200)))")
        }
    }
    return results
}

/// Streams, reads, reset and determinism.
extension ExchangeEngineTests {
    @Test func everyRecordCarriesTheCurrentEpoch() async throws {
        let engine = makeEngine()
        _ = await engine.submit(order("m", .buy, .market, 100))
        _ = await engine.submit(order("bad", .buy, .limit, 150))
        let firstEpoch = await engine.epoch
        let first = try await loggedEvents(engine)
        #expect(first.count == 4)
        #expect(first.allSatisfy { $0.epoch == firstEpoch })

        await engine.reset()
        _ = await engine.submit(order("bad", .buy, .limit, 150))
        let secondEpoch = await engine.epoch
        let second = try await loggedEvents(engine)
        #expect(second.count == 1)
        #expect(second.allSatisfy { $0.epoch == secondEpoch })
        #expect(secondEpoch != firstEpoch)
    }

    @Test func epochIsNotDerivedFromTheSeedOrTheClock() async {
        let one = makeEngine(clock: FakeClock())
        let two = makeEngine(clock: FakeClock())
        let epochOne = await one.epoch
        let epochTwo = await two.epoch
        #expect(epochOne != epochTwo)
    }

    @Test func accountIsConsistentWithTheLogAndTheLedger() async throws {
        let engine = makeEngine()
        let bid = try await currentQuote(engine).bid.satang
        _ = await engine.submit(order("m", .buy, .market, 300))
        _ = await engine.submit(order("l", .buy, .limit, 200, limit: bid))
        _ = await engine.submit(order("s", .sell, .market, 100))
        _ = await engine.submit(order("bad", .buy, .limit, 150))
        let account = await engine.account()
        let ledger = await engine.ledgerSnapshot()
        let records = try await loggedEvents(engine)
        let epoch = await engine.epoch
        #expect(account.epoch == epoch)
        #expect(account.lastEventSeq == records.last?.seq)
        #expect(account.lastLedgerSeq == ledger.entries.last?.ledgerSeq)
        #expect(account.lastLedgerSeq == 2)
        #expect(account.cash == ledger.cash)
        #expect(account.positions == ledger.positions)
        #expect(account.positions == [ptt.id: 200])
    }

    @Test func transactionsPageNewestFirst() async throws {
        let engine = makeEngine(startingCash: ampleCash)
        _ = await engine.submit(order("sweep", .buy, .market, 10_000_000))
        let entries = await engine.ledgerSnapshot().entries
        try #require(entries.count >= 4)
        let count = UInt64(entries.count)

        let newest = await engine.transactions(before: nil, limit: 2)
        #expect(newest.map(\.ledgerSeq) == [count, count - 1])
        let older = await engine.transactions(before: count - 1, limit: 2)
        #expect(older.map(\.ledgerSeq) == [count - 2, count - 3])
        let all = await engine.transactions(before: nil, limit: 1_000)
        #expect(all == entries.reversed())
        let beyond = await engine.transactions(before: count + 50, limit: 1_000)
        #expect(beyond == entries.reversed())
        let oldest = await engine.transactions(before: 2, limit: 10)
        #expect(oldest.map(\.ledgerSeq) == [1])
        for (before, limit) in [(UInt64?.some(1), 10), (0, 10), (nil, 0), (nil, -1), (UInt64.max, Int.min)] {
            let page = await engine.transactions(before: before, limit: limit)
            #expect(page.isEmpty, "before \(String(describing: before)), limit \(limit)")
        }
    }

    @Test func readsPassThroughToTheMarket() async {
        let engine = makeEngine()
        var market = defaultMarket
        let symbols = await engine.symbols()
        #expect(symbols == catalogSymbols)
        let engineQuotes = await engine.quotes()
        #expect(engineQuotes == quotes(of: market))
        let candles = await engine.candles(symbolId: ptt.id, interval: .m1, limit: 50)
        #expect(candles.count == 50)
        #expect(candles == market.history(symbolId: ptt.id, interval: .m1, limit: 50))

        let changed = await engine.advance(toMs: marketStartMs + 5_000, updatesPerSymbolPerSecond: 20)
        let expected = market.advance(toMs: marketStartMs + 5_000, updatesPerSymbolPerSecond: 20)
        #expect(!changed.isEmpty)
        #expect(changed == expected)
        let after = await engine.quotes()
        #expect(after == quotes(of: market))
        let secondCandles = await engine.candles(symbolId: 3, interval: .s1, limit: 7)
        #expect(secondCandles == market.history(symbolId: 3, interval: .s1, limit: 7))
    }

    @Test func symbolsAreTheOnesTheMarketServes() async throws {
        let duplicate = SymbolInfo(
            id: ptt.id, ticker: "DUP", nameTh: "ซ้ำ", nameEn: "Duplicate", reference: Price(satang: 90_000)
        )
        let tooCheap = makeSymbol(50, reference: 10)
        let engine = makeEngine(symbols: [tooCheap, ptt, duplicate, catalogSymbols[1]])
        let symbols = await engine.symbols()
        #expect(symbols == [ptt, catalogSymbols[1]])
        let quoteIds = await engine.quotes().map(\.symbolId)
        #expect(quoteIds == [ptt.id, catalogSymbols[1].id])
        let unserved = await engine.submit(order("cheap", .buy, .market, 100, symbol: 50))
        #expect(rejectReason(unserved) == .unknownSymbol)
        // The band is the first symbol's, not the duplicate's.
        let atReference = await engine.submit(order("ref", .buy, .limit, 100, limit: ptt.reference.satang - 200))
        #expect(acceptedId(atReference) != nil)
    }

    @Test func resetClearsOrdersLedgerIdempotencyAndIdsButNotTheMarket() async throws {
        let engine = makeEngine()
        let bid = try await currentQuote(engine).bid.satang
        let resting = try await submitAccepted(engine, order("c1", .buy, .limit, 100, limit: bid))
        _ = await engine.submit(order("c2", .buy, .market, 100))
        let quotesBefore = await engine.quotes()

        await engine.reset()
        let ledger = await engine.ledgerSnapshot()
        #expect(ledger == Ledger(startingCash: defaultStartingCash, commissionBps: 15))
        let cancelled = await engine.cancel(orderId: resting)
        #expect(!cancelled)
        let quotesAfter = await engine.quotes()
        #expect(quotesAfter == quotesBefore)

        // The same client order id is new again: a new order with the first id of the epoch, not the stored outcome.
        let outcome = await engine.submit(order("c2", .buy, .limit, 100, limit: bid))
        #expect(acceptedId(outcome) == "O-000001")
        let payloads = try await loggedPayloads(engine)
        #expect(payloads.first == .accepted(
            orderId: "O-000001", clientOrderId: "c2", symbolId: ptt.id, side: .buy, type: .limit, quantity: 100,
            limitPrice: Price(satang: bid)
        ))
        // Resting orders from before the reset never fill: only the new one is left to.
        let found = try await advanceUntil(engine, fromMs: marketStartMs) { !fills(in: $0).isEmpty }
        let step = try #require(found)
        #expect(fills(in: step.payloads).map(\.orderId) == ["O-000001"])
    }

    @Test func streamsReleaseTheirContinuationWhenTheConsumerStops() async throws {
        let engine = makeEngine()
        _ = await engine.submit(order("bad", .buy, .limit, 150))
        let epoch = await engine.epoch

        // A consumer that reads one record and lets the stream go.
        do {
            let stream = try await engine.eventStream(after: 0, clientEpoch: epoch)
            let registered = await engine.liveStreamCount
            #expect(registered == 1)
            for await _ in stream { break }
        }
        let afterBreak = await settledStreamCount(engine)
        #expect(afterBreak == 0)

        // A consumer whose task is cancelled while it waits for live records.
        let stream = try await engine.eventStream(after: 1, clientEpoch: epoch)
        let registered = await engine.liveStreamCount
        #expect(registered == 1)
        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        await consumer.value
        let afterCancel = await settledStreamCount(engine)
        #expect(afterCancel == 0)
    }

    @Test func dropStreamsFinishesStreamsAndLeavesEverythingElse() async throws {
        let engine = makeEngine()
        let bid = try await currentQuote(engine).bid.satang
        let resting = try await submitAccepted(engine, order("c1", .buy, .limit, 100, limit: bid))
        let epoch = await engine.epoch
        let stream = try await engine.eventStream(after: 0, clientEpoch: epoch)
        let accountBefore = await engine.account()
        let ledgerBefore = await engine.ledgerSnapshot()

        await engine.dropStreams()
        let left = await engine.liveStreamCount
        #expect(left == 0)
        let (replayed, ended) = await firstRecords(of: stream, count: 100)
        #expect(ended)
        #expect(replayed.count == 1)
        let accountAfter = await engine.account()
        let ledgerAfter = await engine.ledgerSnapshot()
        #expect(accountAfter == accountBefore)
        #expect(ledgerAfter == ledgerBefore)
        let cancelled = await engine.cancel(orderId: resting)
        #expect(cancelled)
    }

    @Test func twoEnginesWithOneSeedProduceIdenticalEvents() async throws {
        let first = makeEngine()
        let second = makeEngine()
        let firstResults = await runScript(first)
        let secondResults = await runScript(second)
        #expect(firstResults == secondResults)
        let firstPayloads = try await loggedPayloads(first)
        let secondPayloads = try await loggedPayloads(second)
        #expect(fills(in: firstPayloads).count >= 3)
        #expect(firstPayloads == secondPayloads)
        let firstTimes = try await loggedEvents(first).map(\.tsNs)
        let secondTimes = try await loggedEvents(second).map(\.tsNs)
        #expect(firstTimes == secondTimes)
    }
}

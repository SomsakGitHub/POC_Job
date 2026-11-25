import Contracts
import Foundation
import Observation
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// The transactions list: the first page of the server's REST API merged with the fills the trading state has seen
/// live, and the rules that keep a page of one server epoch away from the ledger of another.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TransactionsModelTests {
    /// A transaction of PTT as the REST API lists it: ledger sequence `seq`, a purchase of 100 shares unless said
    /// otherwise.
    private func dto(_ seq: UInt64, side: String = "buy", price: Int64 = 3_425) -> TransactionDTO {
        TransactionDTO(
            ledgerSeq: seq, orderId: "O\(seq)", symbolId: 4, side: side, quantity: 100, price: price,
            commission: 51, cashDelta: -342_551, tsNs: 1_795_615_402_000_000_000
        )
    }

    /// A page of the transactions with these ledger sequence numbers, in the order given (the server sends the newest
    /// first).
    private func page(_ seqs: [UInt64]) -> TransactionPageDTO {
        TransactionPageDTO(items: seqs.map { dto($0) }, next: nil)
    }

    /// A trading store over a REST API that answers `answers` to the first requests for transactions, and a model of
    /// the transactions over both.
    private func make(
        _ answers: [FakeRest.TransactionAnswer]
    ) -> (rest: FakeRest, trading: TradingRig, model: TransactionsModel) {
        let rest = FakeRest(transactions: answers)
        let trading = TradingRig(rest: rest)
        return (rest, trading, TransactionsModel(rest: rest, trading: trading.store))
    }

    /// The sequence numbers of the rows the model shows, in the order it shows them.
    private func ids(_ model: TransactionsModel) -> [UInt64] {
        model.rows.map(\.id)
    }

    /// Delivers the fills with these ledger sequence numbers to the trading store as events of the server epoch
    /// `epoch`, one event each, numbered from `firstEvent`.
    private func deliverFills(
        _ seqs: [UInt64], to trading: TradingRig, firstEvent: UInt64 = 1, price: Int64 = 3_425, epoch: String = "E1"
    ) async throws {
        for (index, seq) in seqs.enumerated() {
            let event = ledgerEvent(firstEvent + UInt64(index), ledgerSeq: seq, price: price, epoch: epoch)
            try await trading.deliver(event)
        }
    }

    // MARK: What is asked for and what comes back

    @Test func loadAsksForTheFirstPageOfFifty() async {
        let (rest, _, model) = make([.page(page([3, 2, 1]))])

        await model.load()

        #expect(TransactionsModel.pageSize == 50)
        #expect(rest.transactionCalls == [FakeRest.TransactionCall(cursor: nil, limit: 50)])
        #expect(ids(model) == [3, 2, 1])
        #expect(!model.loadFailed)
    }

    @Test func aRestRowBecomesALedgerRowWithEveryFieldKept() async {
        let sale = TransactionDTO(
            ledgerSeq: 7, orderId: "O9", symbolId: 2, side: "sell", quantity: 300, price: 5_800, commission: 87,
            cashDelta: 1_739_913, tsNs: 1_795_615_402_123_456_789
        )
        let (_, _, model) = make([.page(TransactionPageDTO(items: [dto(8), sale], next: nil))])

        await model.load()

        let expected = LedgerRow(
            id: 7, orderId: "O9", symbolId: 2, side: .sell, quantity: 300, price: satang(5_800), commission: 87,
            cashDelta: 1_739_913, tsNs: 1_795_615_402_123_456_789
        )
        #expect(model.rows.last == expected)
        #expect(model.rows.first?.side == .buy)
    }

    @Test func aRowWhoseSideIsNeitherBuyNorSellIsDropped() async {
        let sides = ["buy", "hold", "", "BUY", "sell", " buy", "Sell", "short"]
        let items = sides.enumerated().map { dto(UInt64($0.offset + 1), side: $0.element) }
        let (_, _, model) = make([.page(TransactionPageDTO(items: items, next: nil))])

        await model.load()

        // Only the rows whose side is exactly "buy" or "sell" are kept: sequence numbers 1 and 5.
        #expect(sides.count == 8)
        #expect(ids(model) == [5, 1])
        #expect(model.rows.map(\.side) == [.sell, .buy])
    }

    // MARK: Merging with the live ledger

    @Test func mergeDedupesAndSorts() async throws {
        let (_, trading, model) = make([.page(page([3, 2, 1]))])
        await trading.start()
        try await deliverFills([3, 4, 5], to: trading)
        #expect(ids(model) == [5, 4, 3], "before the page is loaded the live fills are all there is")

        await model.load()

        #expect(ids(model) == [5, 4, 3, 2, 1], "ledger number 3 is in both and is shown once, newest first")
    }

    @Test func theMergeSortsByLedgerSequenceWhateverOrderThePageIsIn() async {
        let (_, _, model) = make([.page(page([2, 9, 1, 7]))])

        await model.load()

        #expect(ids(model) == [9, 7, 2, 1])
    }

    @Test func aLiveRowWinsAClash() async throws {
        let (_, trading, model) = make([.page(TransactionPageDTO(items: [dto(3, price: 3_000), dto(2)], next: nil))])
        await trading.start()
        try await deliverFills([3], to: trading, price: 3_425)

        await model.load()

        #expect(ids(model) == [3, 2])
        #expect(model.rows.first?.price == satang(3_425), "the live row, not the page's row with price 30.00")
        #expect(model.rows.last?.price == satang(3_425))
    }

    @Test func theLiveLedgerIsShownBeforeAnyPageIsLoadedAndFollowsIt() async throws {
        let (_, trading, model) = make([.page(page([2, 1]))])
        await trading.start()
        #expect(model.rows.isEmpty)
        #expect(!model.loadFailed)

        try await deliverFills([3], to: trading)
        #expect(ids(model) == [3])

        await model.load()
        try await deliverFills([4], to: trading, firstEvent: 2)

        #expect(ids(model) == [4, 3, 2, 1])
    }

    // MARK: When a load fails

    @Test func aFailedCallKeepsThePreviousRowsAndSaysSo() async {
        let (_, _, model) = make([.page(page([3, 2, 1])), .failure(URLError(.timedOut)), .page(page([5, 4]))])

        await model.load()
        #expect(ids(model) == [3, 2, 1])
        #expect(!model.loadFailed)

        await model.load()
        #expect(ids(model) == [3, 2, 1], "the rows it had stay")
        #expect(model.loadFailed)

        await model.load()
        #expect(ids(model) == [5, 4])
        #expect(!model.loadFailed, "a call that works clears the failure")
    }

    @Test func aFirstCallThatFailsLeavesTheLiveRowsAndSaysSo() async throws {
        let (_, trading, model) = make([.failure(URLError(.notConnectedToInternet))])
        await trading.start()
        try await deliverFills([2], to: trading)

        await model.load()

        #expect(ids(model) == [2])
        #expect(model.loadFailed)
    }

    // MARK: Answers that must not be applied

    @Test func anAnswerAfterAnEpochChangeIsDropped() async throws {
        let (rest, trading, model) = make([.hold, .page(page([2, 1]))])
        await trading.start()
        try await trading.deliverEpoch("E1")

        async let load: Void = model.load()
        await waitFor("the request is held") { rest.heldTransactionCount == 1 }
        try await trading.deliverEpoch("E2")
        let toldOfTheDroppedAnswer = Flag()
        withObservationTracking {
            _ = model.rows
            _ = model.loadFailed
        } onChange: {
            toldOfTheDroppedAnswer.set()
        }
        rest.releaseTransactions(call: 0, .success(page([3, 2, 1])))
        await load

        #expect(model.rows.isEmpty, "a page of the epoch the server left is never shown beside the new one")
        #expect(!model.loadFailed)
        #expect(!toldOfTheDroppedAnswer.isSet, "a dropped answer is not kept, so nobody is told of it")

        let toldOfTheAppliedAnswer = Flag()
        withObservationTracking {
            _ = model.rows
        } onChange: {
            toldOfTheAppliedAnswer.set()
        }
        await model.load()
        #expect(ids(model) == [2, 1], "the control: a request made in the new epoch is applied")
        #expect(toldOfTheAppliedAnswer.isSet)
    }

    @Test func anOlderAnswerReleasedAfterANewerOneIsDropped() async {
        let (rest, _, model) = make([.hold, .hold])

        async let first: Void = model.load()
        await waitFor("the first request is held") { rest.heldTransactionCount == 1 }
        async let second: Void = model.load()
        await waitFor("the second request is held") { rest.heldTransactionCount == 2 }

        rest.releaseTransactions(call: 1, .success(page([8, 7])))
        await second
        #expect(ids(model) == [8, 7])

        rest.releaseTransactions(call: 0, .success(page([2, 1])))
        await first
        #expect(ids(model) == [8, 7], "the older request ended last and its answer is not applied")
    }

    @Test func anOlderFailureReleasedAfterANewerAnswerChangesNothing() async {
        let (rest, _, model) = make([.hold, .hold])

        async let first: Void = model.load()
        await waitFor("the first request is held") { rest.heldTransactionCount == 1 }
        async let second: Void = model.load()
        await waitFor("the second request is held") { rest.heldTransactionCount == 2 }

        rest.releaseTransactions(call: 1, .success(page([8, 7])))
        await second
        rest.releaseTransactions(call: 0, .failure(URLError(.timedOut)))
        await first

        #expect(ids(model) == [8, 7])
        #expect(!model.loadFailed, "a failure that is no longer the newest request is not news")
    }

    @Test func cancellationAppliesNothing() async {
        let (rest, _, model) = make([.hold])
        let loading = Task { await model.load() }
        await waitFor("the request is held") { rest.heldTransactionCount == 1 }

        loading.cancel()
        rest.releaseTransactions(call: 0, .success(page([3, 2, 1])))
        await loading.value

        #expect(model.rows.isEmpty)
        #expect(!model.loadFailed)
    }

    @Test func aCancelledCallThatEndsInAnErrorIsNotAFailure() async {
        let (rest, _, model) = make([.hold])
        let loading = Task { await model.load() }
        await waitFor("the request is held") { rest.heldTransactionCount == 1 }

        loading.cancel()
        rest.releaseTransactions(call: 0, .failure(CancellationError()))
        await loading.value

        #expect(model.rows.isEmpty)
        #expect(!model.loadFailed)
    }

    // MARK: The page and the epoch

    @Test func aPageStopsBeingShownOnceTheServerStartedAnotherEpoch() async throws {
        let (_, trading, model) = make([.page(page([3, 2, 1])), .page(page([2, 1]))])
        await trading.start()
        try await trading.deliverEpoch("E1")
        await model.load()
        #expect(ids(model) == [3, 2, 1])
        try await deliverFills([4], to: trading, firstEvent: 2)
        #expect(ids(model) == [4, 3, 2, 1], "the same epoch: the page and the live fill are shown together")

        try await trading.deliverEpoch("E2")

        #expect(trading.store.state.epochChanges == 1)
        #expect(model.rows.isEmpty, "the page is of the epoch that is over, and the ledger was emptied")

        try await deliverFills([1], to: trading, firstEvent: 2, epoch: "E2")
        #expect(ids(model) == [1], "only what the new epoch has delivered")

        await model.load()
        #expect(ids(model) == [2, 1], "a page loaded in the new epoch is shown again")
    }

    @Test func theFirstEpochTheStoreSeesIsNotAChange() async throws {
        let (_, trading, model) = make([.page(page([3, 2, 1]))])
        await trading.start()
        await model.load()

        try await trading.deliverEpoch("E1")

        #expect(trading.store.state.epochChanges == 0)
        #expect(ids(model) == [3, 2, 1])
    }

    // MARK: What a view is told

    @Test func theReadersOfTheRowsAreToldWhenALiveFillArrivesAndWhenAPageIsApplied() async throws {
        let (_, trading, model) = make([.page(page([2, 1]))])
        await trading.start()
        let liveFill = Flag()
        withObservationTracking {
            _ = model.rows
        } onChange: {
            liveFill.set()
        }
        #expect(!liveFill.isSet)

        try await deliverFills([3], to: trading)
        #expect(liveFill.isSet)

        let page = Flag()
        withObservationTracking {
            _ = model.rows
        } onChange: {
            page.set()
        }
        await model.load()
        #expect(page.isSet)
    }

    @Test func theReadersOfLoadFailedAreToldWhenACallFails() async {
        let (_, _, model) = make([.failure(URLError(.timedOut))])
        let told = Flag()
        withObservationTracking {
            _ = model.loadFailed
        } onChange: {
            told.set()
        }
        #expect(!told.isSet)

        await model.load()

        #expect(told.isSet)
    }
}

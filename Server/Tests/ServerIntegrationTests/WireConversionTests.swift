import Contracts
import ExchangeCore
import GRPCCore
import Testing
import TradeCore
@testable import ExchangeServerKit

/// The order service's conversions between the engine's values and the wire messages, without a server.
@Suite("WireConversionTests")
struct WireConversionTests {
    private let epoch = "5F0C1E2A-0000-4000-8000-000000000001"

    private func record(_ payload: OrderEventPayload, seq: UInt64 = 7, tsNs: Int64 = 1_732_000_000_123_456_789)
        -> OrderEventRecord {
        OrderEventRecord(seq: seq, epoch: epoch, tsNs: tsNs, payload: payload)
    }

    private func expectHeader(_ event: Tp_OrderEvent, seq: UInt64 = 7, tsNs: Int64 = 1_732_000_000_123_456_789) {
        #expect(event.eventSeq == seq)
        #expect(event.serverEpoch == epoch)
        #expect(event.serverTsNs == tsNs)
    }

    // MARK: Order events, one test per payload case

    @Test func anAcceptedEventCopiesEveryField() throws {
        let event = Tp_OrderEvent(record: record(.accepted(
            orderId: "O-000042", clientOrderId: "c-1", symbolId: 3, side: .sell, type: .limit, quantity: 300,
            limitPrice: Price(satang: 3_425)
        )))
        expectHeader(event)
        guard case .accepted(let accepted) = event.event else {
            Issue.record("expected accepted, got \(String(describing: event.event))")
            return
        }
        #expect(accepted.orderID == "O-000042")
        #expect(accepted.clientOrderID == "c-1")
        #expect(accepted.symbolID == 3)
        #expect(accepted.side == .sell)
        #expect(accepted.type == .limit)
        #expect(accepted.quantity == 300)
        #expect(accepted.limitPrice == 3_425)
    }

    @Test func anAcceptedMarketOrderWithoutAPriceHasPriceZero() {
        let event = Tp_OrderEvent(record: record(.accepted(
            orderId: "O-000001", clientOrderId: "m", symbolId: 1, side: .buy, type: .market, quantity: 100,
            limitPrice: nil
        )))
        #expect(event.accepted.limitPrice == 0)
        #expect(event.accepted.type == .market)
        #expect(event.accepted.side == .buy)
    }

    @Test func aRejectedEventCopiesEveryField() {
        let event = Tp_OrderEvent(record: record(.rejected(clientOrderId: "c-2", reason: .outsidePriceBand), seq: 9))
        expectHeader(event, seq: 9)
        guard case .rejected(let rejected) = event.event else {
            Issue.record("expected rejected, got \(String(describing: event.event))")
            return
        }
        #expect(rejected.clientOrderID == "c-2")
        #expect(rejected.reason == .outsidePriceBand)
    }

    @Test func aFillEventCopiesEveryField() {
        let event = Tp_OrderEvent(record: record(
            .fill(orderId: "O-000005", symbolId: 4, side: .buy, quantity: 200, price: Price(satang: 15_050),
                  remaining: 800),
            tsNs: 99
        ))
        expectHeader(event, tsNs: 99)
        guard case .fill(let fill) = event.event else {
            Issue.record("expected fill, got \(String(describing: event.event))")
            return
        }
        #expect(fill.orderID == "O-000005")
        #expect(fill.symbolID == 4)
        #expect(fill.side == .buy)
        #expect(fill.quantity == 200)
        #expect(fill.price == 15_050)
        #expect(fill.remaining == 800)
    }

    @Test func aCancelledEventCopiesEveryFieldAndANilReasonIsUnspecified() {
        let byClient = Tp_OrderEvent(record: record(.cancelled(orderId: "O-000006", remaining: 400, reason: nil)))
        let noBook = Tp_OrderEvent(record: record(.cancelled(orderId: "O-000007", remaining: 100,
                                                             reason: .noLiquidity)))
        expectHeader(byClient)
        guard case .cancelled(let cancelled) = byClient.event else {
            Issue.record("expected cancelled, got \(String(describing: byClient.event))")
            return
        }
        #expect(cancelled.orderID == "O-000006")
        #expect(cancelled.remaining == 400)
        #expect(cancelled.reason == .unspecified)
        #expect(noBook.cancelled.orderID == "O-000007")
        #expect(noBook.cancelled.remaining == 100)
        #expect(noBook.cancelled.reason == .noLiquidity)
    }

    @Test func aLedgerEventCopiesEveryFieldOfTheEntry() {
        let entry = LedgerEntry(
            ledgerSeq: 12, orderId: "O-000008", symbolId: 2, side: .sell, quantity: 500, price: Price(satang: 2_150),
            commission: 1_613, cashDelta: 1_073_387, cashAfter: 98_765_432, positionAfter: 1_500, tsNs: 1_234_567
        )
        let event = Tp_OrderEvent(record: record(.ledger(entry), seq: 13))
        expectHeader(event, seq: 13)
        guard case .ledgerEntry(let wire) = event.event else {
            Issue.record("expected ledgerEntry, got \(String(describing: event.event))")
            return
        }
        #expect(wire.ledgerSeq == 12)
        #expect(wire.orderID == "O-000008")
        #expect(wire.symbolID == 2)
        #expect(wire.side == .sell)
        #expect(wire.quantity == 500)
        #expect(wire.price == 2_150)
        #expect(wire.commission == 1_613)
        #expect(wire.cashDelta == 1_073_387)
        #expect(wire.cashAfter == 98_765_432)
        #expect(wire.positionAfter == 1_500)
        #expect(wire.tsNs == 1_234_567)
    }

    // MARK: Submit requests and answers

    @Test func aSubmitRequestBecomesAnOrderRequest() throws {
        var wire = Tp_SubmitOrderRequest()
        wire.clientOrderID = "c-9"
        wire.symbolID = 5
        wire.side = .sell
        wire.type = .limit
        wire.quantity = 700
        wire.limitPrice = 4_200
        let request = try OrderRequest(wire: wire)
        #expect(request == OrderRequest(
            clientOrderId: "c-9", symbolId: 5, side: .sell, type: .limit, quantity: 700,
            limitPrice: Price(satang: 4_200)
        ))
    }

    @Test func aLimitPriceOfZeroIsNoPrice() throws {
        var wire = Tp_SubmitOrderRequest()
        wire.clientOrderID = "c-0"
        wire.side = .buy
        wire.type = .market
        let request = try OrderRequest(wire: wire)
        #expect(request.limitPrice == nil)
    }

    @Test func aClientOrderIdIsBoundedInUTF8Bytes() throws {
        func code(_ id: String) -> RPCError.Code? {
            var wire = Tp_SubmitOrderRequest()
            wire.clientOrderID = id
            wire.side = .buy
            wire.type = .market
            do {
                _ = try OrderRequest(wire: wire)
                return nil
            } catch {
                return error.code
            }
        }
        let thai = String(repeating: "ก", count: 21)  // 63 bytes
        #expect(code("") == .invalidArgument)
        #expect(code(String(repeating: "x", count: 64)) == nil)
        #expect(code(String(repeating: "x", count: 65)) == .invalidArgument)
        #expect(code(thai + "a") == nil)
        #expect(code(thai + "ab") == .invalidArgument)
    }

    @Test func anAcceptedOutcomeBecomesAnAcceptedAnswerWithItsTiming() {
        let response = Tp_SubmitOrderResponse(
            outcome: .accepted(orderId: "O-000003", timing: ServerTimingNs(recvNs: 100, ackNs: 250))
        )
        #expect(response.accepted)
        #expect(response.orderID == "O-000003")
        #expect(response.rejectReason == .unspecified)
        #expect(response.hasTiming)
        #expect(response.timing.recvNs == 100)
        #expect(response.timing.ackNs == 250)
    }

    @Test func aRejectedOutcomeBecomesARefusalWithItsReasonAndTiming() {
        let response = Tp_SubmitOrderResponse(
            outcome: .rejected(.insufficientFunds, timing: ServerTimingNs(recvNs: 300, ackNs: 310))
        )
        #expect(!response.accepted)
        #expect(response.orderID.isEmpty)
        #expect(response.rejectReason == .insufficientFunds)
        #expect(response.timing.recvNs == 300)
        #expect(response.timing.ackNs == 310)
    }

    @Test func outOfRangeNamesTheOldestRetainedEvent() {
        let error = RPCError(eventLogError: .outOfRange(oldestRetained: 4_321))
        #expect(error.code == .outOfRange)
        #expect(error.message.contains("4321"), "\(error.message)")
    }
}

import Contracts
import GRPCCore
import SwiftProtobuf
import Testing

struct RoundTripTests {
    @Test func marketFrameRoundTrip() throws {
        var first = Tp_SymbolUpdate()
        first.symbolID = 1
        first.last = 3425
        var second = Tp_SymbolUpdate()
        second.symbolID = 2
        second.last = 3425
        var frame = Tp_MarketFrame()
        frame.updates = [first, second]

        let data = try frame.serializedData()
        let decoded = try Tp_MarketFrame(serializedBytes: data)

        #expect(decoded == frame)
    }

    @Test func orderEventFillRoundTrip() throws {
        var fill = Tp_OrderFill()
        fill.quantity = 100
        fill.price = 3425
        var event = Tp_OrderEvent()
        event.eventSeq = 7
        event.serverEpoch = "e1"
        event.event = .fill(fill)

        let data = try event.serializedData()
        let decoded = try Tp_OrderEvent(serializedBytes: data)

        #expect(decoded.eventSeq == 7)
        #expect(decoded.serverEpoch == "e1")
        guard case .fill(let decodedFill)? = decoded.event else {
            Issue.record("expected the .fill case, got \(String(describing: decoded.event))")
            return
        }
        #expect(decodedFill.quantity == 100)
        #expect(decodedFill.price == 3425)
    }

    @Test func orderServiceNamespaceExists() {
        #expect(Tp_OrderService.descriptor.fullyQualifiedService == "tp.OrderService")
    }
}

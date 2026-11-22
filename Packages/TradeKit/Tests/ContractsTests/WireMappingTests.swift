import Contracts
import Testing
import TradeCore

struct WireMappingTests {
    // MARK: Side

    @Test func sideMapsBothWays() {
        #expect(Side(wire: .buy) == .buy)
        #expect(Side(wire: .sell) == .sell)
        #expect(Side.buy.wire == .buy)
        #expect(Side.sell.wire == .sell)
    }

    @Test func sideHasNoValueForUnspecifiedOrUnrecognised() {
        #expect(Side(wire: .unspecified) == nil)
        #expect(Side(wire: .UNRECOGNIZED(3)) == nil)
        #expect(Side(wire: .UNRECOGNIZED(-1)) == nil)
    }

    @Test func sideRawValuesMirrorTheProtoNumbers() {
        #expect(Int(Side.buy.rawValue) == Tp_Side.buy.rawValue)
        #expect(Int(Side.sell.rawValue) == Tp_Side.sell.rawValue)
    }

    @Test func everyKnownWireSideMapsToADistinctDomainSide() {
        let known = Tp_Side.allCases.filter { $0 != .unspecified }
        let mapped = known.compactMap { Side(wire: $0) }
        #expect(mapped.count == known.count)
        #expect(Set(mapped).count == known.count)
        #expect(mapped.map(\.wire) == known)
    }

    // MARK: OrderType

    @Test func orderTypeMapsBothWays() {
        #expect(OrderType(wire: .market) == .market)
        #expect(OrderType(wire: .limit) == .limit)
        #expect(OrderType.market.wire == .market)
        #expect(OrderType.limit.wire == .limit)
    }

    @Test func orderTypeHasNoValueForUnspecifiedOrUnrecognised() {
        #expect(OrderType(wire: .unspecified) == nil)
        #expect(OrderType(wire: .UNRECOGNIZED(3)) == nil)
        #expect(OrderType(wire: .UNRECOGNIZED(-1)) == nil)
    }

    @Test func orderTypeRawValuesMirrorTheProtoNumbers() {
        #expect(Int(OrderType.market.rawValue) == Tp_OrderType.market.rawValue)
        #expect(Int(OrderType.limit.rawValue) == Tp_OrderType.limit.rawValue)
    }

    @Test func everyKnownWireOrderTypeMapsToADistinctDomainOrderType() {
        let known = Tp_OrderType.allCases.filter { $0 != .unspecified }
        let mapped = known.compactMap { OrderType(wire: $0) }
        #expect(mapped.count == known.count)
        #expect(Set(mapped).count == known.count)
        #expect(mapped.map(\.wire) == known)
    }

    // MARK: RejectReason

    /// Every domain reason, written out, in proto order.
    private static let allReasons: [RejectReason] = [
        .invalidQuantity, .invalidLot, .invalidTick, .outsidePriceBand, .insufficientFunds,
        .insufficientPosition, .unknownSymbol, .noLiquidity, .invalidDuplicate,
    ]

    @Test(arguments: allReasons)
    func everyRejectReasonRoundTripsThroughTheWire(reason: RejectReason) {
        #expect(RejectReason(wire: reason.wire) == reason)
    }

    @Test(arguments: allReasons)
    func rejectReasonRawValuesMirrorTheProtoNumbers(reason: RejectReason) {
        #expect(Int(reason.rawValue) == reason.wire.rawValue)
    }

    @Test func rejectReasonWireValuesAreNeverUnspecified() {
        for reason in Self.allReasons {
            #expect(reason.wire != .unspecified)
            if case .UNRECOGNIZED = reason.wire {
                Issue.record("\(reason) mapped to an unrecognised wire value")
            }
        }
    }

    /// The domain list above and the proto enum cover exactly the same cases: a case added on only one side
    /// fails here instead of silently falling out of the mapping.
    @Test func everyKnownWireRejectReasonMapsToADistinctDomainReason() {
        let known = Tp_RejectReason.allCases.filter { $0 != .unspecified }
        let mapped = known.compactMap { RejectReason(wire: $0) }
        #expect(known.count == Self.allReasons.count)
        #expect(mapped.count == known.count)
        #expect(Set(mapped) == Set(Self.allReasons))
        #expect(mapped.map(\.wire) == known)
    }

    @Test func rejectReasonHasNoValueForUnspecifiedOrUnrecognised() {
        #expect(RejectReason(wire: .unspecified) == nil)
        #expect(RejectReason(wire: .UNRECOGNIZED(10)) == nil)
        #expect(RejectReason(wire: .UNRECOGNIZED(0)) == nil)
        #expect(RejectReason(wire: .UNRECOGNIZED(-1)) == nil)
        #expect(RejectReason(wire: .UNRECOGNIZED(Int.max)) == nil)
    }
}

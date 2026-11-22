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

    // MARK: Candle

    private static func candle(
        _ openTimeMs: Int64, _ open: Int64, _ high: Int64, _ low: Int64, _ close: Int64, _ volume: Int64
    ) -> Candle {
        Candle(
            openTimeMs: openTimeMs, open: Price(satang: open), high: Price(satang: high), low: Price(satang: low),
            close: Price(satang: close), volume: volume
        )
    }

    /// Every field lands in its own wire field and comes back. The six values differ, so a swapped pair would show.
    @Test func candleMapsFieldForFieldBothWays() {
        let candle = Self.candle(1_700_000_100_000, 3425, 3450, 3410, 3430, 600)

        let wire = candle.wire

        #expect(wire.openTimeMs == 1_700_000_100_000)
        #expect(wire.open == 3425)
        #expect(wire.high == 3450)
        #expect(wire.low == 3410)
        #expect(wire.close == 3430)
        #expect(wire.volume == 600)
        #expect(Candle(wire: wire) == candle)
    }

    /// A flat candle (the price never moved inside the bucket, so high == low) is an ordinary candle on the wire: the
    /// mapping neither normalises nor refuses it, in either direction.
    @Test func aFlatCandleRoundTripsThroughTheWire() {
        let flat = Self.candle(1_700_000_100_000, 3425, 3425, 3425, 3425, 100)
        #expect(flat.wire.high == flat.wire.low)
        #expect(Candle(wire: flat.wire) == flat)

        var flatWire = Tp_Candle()
        flatWire.openTimeMs = 1_700_000_100_000
        flatWire.open = 3425
        flatWire.high = 3425
        flatWire.low = 3425
        flatWire.close = 3425
        flatWire.volume = 100
        #expect(Candle(wire: flatWire) == flat)
        #expect(Candle(wire: flatWire).wire == flatWire)
    }

    /// All six fields are `int64` on the wire and `Int64` in the domain, so the mapping is total: it refuses and
    /// alters nothing, at the extremes included, and a candle that contradicts itself (high below low, negative
    /// volume) maps as it is. Judging a frame is the caller's job.
    @Test(arguments: [
        candle(.min, .min, .max, .min, 0, .max),
        candle(.max, -1, -2, 5, .max, .min),
        candle(-1, .max, .min, .max, .min, -1),
        candle(0, 0, 0, 0, 0, 0),
    ])
    func candleRoundTripsWhateverTheValues(candle: Candle) {
        #expect(Candle(wire: candle.wire) == candle)
    }

    /// A candle the sender left out of a message reads from the generated getter as an all-zero `Tp_Candle`, and the
    /// mapping has no notion of "absent": it gives an all-zero candle. Callers check `hasCandle1S` (and the like)
    /// first.
    @Test func anAllZeroWireCandleMapsToAnAllZeroCandle() {
        let zero = Self.candle(0, 0, 0, 0, 0, 0)

        #expect(Candle(wire: Tp_Candle()) == zero)
        #expect(zero.wire == Tp_Candle())

        let update = Tp_SymbolUpdate()
        #expect(!update.hasCandle1S)
        #expect(Candle(wire: update.candle1S) == zero)
    }
}

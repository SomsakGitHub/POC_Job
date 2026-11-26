import TradeCore

// The domain enums of `TradeCore` against the generated protobuf enums.
//
// `init?(wire:)` is nil for `.unspecified` (the sender did not set the field) and for `.UNRECOGNIZED` (a number this
// build does not know). Neither has a domain meaning: what to do about it (reject the request, show "unknown") is
// the caller's call. `wire` is total. The switches are exhaustive on purpose: a case added on either side fails to
// compile here instead of falling out of the mapping.

extension Side {
    public init?(wire: Tp_Side) {
        switch wire {
        case .buy: self = .buy
        case .sell: self = .sell
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    public var wire: Tp_Side {
        switch self {
        case .buy: .buy
        case .sell: .sell
        }
    }
}

extension OrderType {
    public init?(wire: Tp_OrderType) {
        switch wire {
        case .market: self = .market
        case .limit: self = .limit
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    public var wire: Tp_OrderType {
        switch self {
        case .market: .market
        case .limit: .limit
        }
    }
}

extension RejectReason {
    public init?(wire: Tp_RejectReason) {
        switch wire {
        case .invalidQuantity: self = .invalidQuantity
        case .invalidLot: self = .invalidLot
        case .invalidTick: self = .invalidTick
        case .outsidePriceBand: self = .outsidePriceBand
        case .insufficientFunds: self = .insufficientFunds
        case .insufficientPosition: self = .insufficientPosition
        case .unknownSymbol: self = .unknownSymbol
        case .noLiquidity: self = .noLiquidity
        case .invalidDuplicate: self = .invalidDuplicate
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    public var wire: Tp_RejectReason {
        switch self {
        case .invalidQuantity: .invalidQuantity
        case .invalidLot: .invalidLot
        case .invalidTick: .invalidTick
        case .outsidePriceBand: .outsidePriceBand
        case .insufficientFunds: .insufficientFunds
        case .insufficientPosition: .insufficientPosition
        case .unknownSymbol: .unknownSymbol
        case .noLiquidity: .noLiquidity
        case .invalidDuplicate: .invalidDuplicate
        }
    }
}

// A candle against the generated `Tp_Candle`.
//
// A plain field-for-field copy: prices are `int64` satang on the wire and `Price` in the domain, so every value is
// valid and the mapping is total in both directions (no `init?`). It checks nothing: a frame whose high is below its
// low maps as it is, and judging it is the caller's call. It has no notion of "absent" either. A candle field the
// sender left out of a message reads from the generated getter as an all-zero `Tp_Candle`, which maps to an all-zero
// candle; callers check `Tp_SymbolUpdate.hasCandle1S` (and the like) first.

extension Candle {
    public init(wire: Tp_Candle) {
        self.init(
            openTimeMs: wire.openTimeMs,
            open: Price(satang: wire.open),
            high: Price(satang: wire.high),
            low: Price(satang: wire.low),
            close: Price(satang: wire.close),
            volume: wire.volume
        )
    }

    public var wire: Tp_Candle {
        var message = Tp_Candle()
        message.openTimeMs = openTimeMs
        message.open = open.satang
        message.high = high.satang
        message.low = low.satang
        message.close = close.satang
        message.volume = volume
        return message
    }
}

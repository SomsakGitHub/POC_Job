/// A number of shares. Always whole shares; orders are a multiple of `TickRules.boardLot`.
public typealias Quantity = Int64

/// Which way an order trades. Raw values are the protobuf `tp.Side` numbers (0, "unspecified", has no domain value).
public enum Side: Int32, Sendable {
    case buy = 1
    case sell = 2
}

/// How an order is priced. Raw values are the protobuf `tp.OrderType` numbers (0, "unspecified", has no domain value).
public enum OrderType: Int32, Sendable {
    case market = 1
    case limit = 2
}

/// Where an order is in its life. `unknown` is for a state this build does not recognise.
public enum OrderStatus: Sendable {
    case pending
    case accepted
    case partiallyFilled
    case filled
    case cancelled
    case rejected
    case unknown
}

/// Why an order was refused. Raw values are the protobuf `tp.RejectReason` numbers (0, "unspecified", has no
/// domain value).
public enum RejectReason: Int32, Sendable {
    case invalidQuantity = 1
    case invalidLot = 2
    case invalidTick = 3
    case outsidePriceBand = 4
    case insufficientFunds = 5
    case insufficientPosition = 6
    case unknownSymbol = 7
    case noLiquidity = 8
    case invalidDuplicate = 9
}

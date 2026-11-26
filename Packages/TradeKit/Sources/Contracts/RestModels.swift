// The JSON bodies of the exchange server's REST API: the server writes them and every client reads them.
//
// Money is `Int64` satang (1 baht = 100 satang), a quantity is whole shares and a timestamp is an integer, so no
// number crosses the wire as a floating-point value, except the lab's `rateMultiplier`, which is a rate. A JSON key is
// the property's own name, so a rename here is a change of the wire format. Each type has an explicit public
// initialiser because the one Swift synthesises for a public struct is internal.

/// One tradable symbol, as `GET /v1/symbols` lists it.
public struct SymbolDTO: Codable, Sendable, Equatable, Identifiable {
    /// The id the order API and the market feed use for this symbol.
    public let id: UInt32
    /// The short ticker: "PTT".
    public let ticker: String
    /// The company name in Thai.
    public let nameTh: String
    /// The company name in English.
    public let nameEn: String
    /// The reference ("previous close") price in satang: the centre of the price band.
    public let reference: Int64
    /// The board lot in shares; an order is a whole number of lots.
    public let lot: Int64

    public init(id: UInt32, ticker: String, nameTh: String, nameEn: String, reference: Int64, lot: Int64) {
        self.id = id
        self.ticker = ticker
        self.nameTh = nameTh
        self.nameEn = nameEn
        self.reference = reference
        self.lot = lot
    }
}

/// The shares held in one symbol.
public struct PositionDTO: Codable, Sendable, Equatable {
    public let symbolId: UInt32
    /// Whole shares; always positive, because a symbol with no shares is not listed.
    public let quantity: Int64

    public init(symbolId: UInt32, quantity: Int64) {
        self.symbolId = symbolId
        self.quantity = quantity
    }
}

/// The demo account at one moment, as `GET /v1/account` answers it.
public struct AccountDTO: Codable, Sendable, Equatable {
    /// The server's epoch. A client that holds sequence numbers of another epoch must start over.
    public let epoch: String
    /// Cash in satang.
    public let cash: Int64
    /// The positions, ascending by symbol id.
    public let positions: [PositionDTO]
    /// The sequence number of the newest order event; 0 when there is none.
    public let lastEventSeq: UInt64
    /// The sequence number of the newest ledger entry (transaction); 0 when there is none.
    public let lastLedgerSeq: UInt64

    public init(epoch: String, cash: Int64, positions: [PositionDTO], lastEventSeq: UInt64, lastLedgerSeq: UInt64) {
        self.epoch = epoch
        self.cash = cash
        self.positions = positions
        self.lastEventSeq = lastEventSeq
        self.lastLedgerSeq = lastLedgerSeq
    }
}

/// One fill of the ledger, as `GET /v1/transactions` lists it. Every amount is in satang.
public struct TransactionDTO: Codable, Sendable, Equatable {
    /// The entry's place in the ledger: 1 for the first fill, then 2, 3 and so on with no gap.
    public let ledgerSeq: UInt64
    public let orderId: String
    public let symbolId: UInt32
    /// "buy" or "sell".
    public let side: String
    /// The shares in this fill.
    public let quantity: Int64
    /// The price of one share in this fill.
    public let price: Int64
    public let commission: Int64
    /// What the fill did to cash: negative for a buy, and the commission is already in it.
    public let cashDelta: Int64
    /// When the fill happened, in nanoseconds since the Unix epoch.
    public let tsNs: Int64

    public init(
        ledgerSeq: UInt64, orderId: String, symbolId: UInt32, side: String, quantity: Int64, price: Int64,
        commission: Int64, cashDelta: Int64, tsNs: Int64
    ) {
        self.ledgerSeq = ledgerSeq
        self.orderId = orderId
        self.symbolId = symbolId
        self.side = side
        self.quantity = quantity
        self.price = price
        self.commission = commission
        self.cashDelta = cashDelta
        self.tsNs = tsNs
    }
}

/// One page of transactions, newest first.
public struct TransactionPageDTO: Codable, Sendable, Equatable {
    public let items: [TransactionDTO]
    /// The cursor of the next, older page: the `ledgerSeq` of the last item, in decimal. Absent when the page ends at
    /// the oldest entry, so the last page is never followed by an empty one.
    public let next: String?

    public init(items: [TransactionDTO], next: String?) {
        self.items = items
        self.next = next
    }
}

/// One candle, as `GET /v1/candles` lists it. Prices are satang and `v` is a number of shares.
public struct CandleDTO: Codable, Sendable, Equatable {
    /// The candle's open time in milliseconds since the Unix epoch.
    public let t: Int64
    public let o: Int64
    public let h: Int64
    public let l: Int64
    public let c: Int64
    public let v: Int64

    public init(t: Int64, o: Int64, h: Int64, l: Int64, c: Int64, v: Int64) {
        self.t = t
        self.o = o
        self.h = h
        self.l = l
        self.c = c
        self.v = v
    }
}

/// The candle history of one symbol and interval, oldest first; the last candle is the one still open.
public struct CandlesResponseDTO: Codable, Sendable, Equatable {
    /// The ticker that was asked for.
    public let symbol: String
    /// "1s", "1m" or "5m".
    public let interval: String
    public let candles: [CandleDTO]

    public init(symbol: String, interval: String, candles: [CandleDTO]) {
        self.symbol = symbol
        self.interval = interval
        self.candles = candles
    }
}

/// The lab's knobs for stressing the client: how fast the market ticks and what the market feed does to its updates.
/// The server answers the values in force, which can differ from what was sent: it clamps them into its ranges.
public struct LabSettings: Codable, Sendable, Equatable {
    /// How many times the normal rate (20 updates per symbol per second) the market ticks at; 0.1 to 10.
    public var rateMultiplier: Double
    /// Stress mode: the market ticks at a fixed rate of 500 updates per symbol per second, whatever the multiplier.
    public var stress: Bool
    /// A delay added to every frame of the market feed, in milliseconds; 0 to 5,000.
    public var extraLatencyMs: Int
    /// A random delay of up to this many milliseconds added to every frame on top of the fixed one; 0 to 2,000.
    public var jitterMs: Int
    /// Whether the market feed withholds every other update, so that the client sees gaps in the sequence.
    public var dropUpdates: Bool

    public init(
        rateMultiplier: Double = 1, stress: Bool = false, extraLatencyMs: Int = 0, jitterMs: Int = 0,
        dropUpdates: Bool = false
    ) {
        self.rateMultiplier = rateMultiplier
        self.stress = stress
        self.extraLatencyMs = extraLatencyMs
        self.jitterMs = jitterMs
        self.dropUpdates = dropUpdates
    }
}

/// A change to the lab's settings: only the fields that are present change, the others keep their values. A field
/// that is nil is left out of the JSON altogether.
public struct LabPatch: Codable, Sendable, Equatable {
    public var rateMultiplier: Double?
    public var stress: Bool?
    public var extraLatencyMs: Int?
    public var jitterMs: Int?
    public var dropUpdates: Bool?

    public init(
        rateMultiplier: Double? = nil, stress: Bool? = nil, extraLatencyMs: Int? = nil, jitterMs: Int? = nil,
        dropUpdates: Bool? = nil
    ) {
        self.rateMultiplier = rateMultiplier
        self.stress = stress
        self.extraLatencyMs = extraLatencyMs
        self.jitterMs = jitterMs
        self.dropUpdates = dropUpdates
    }
}

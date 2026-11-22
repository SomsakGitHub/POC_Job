import TradeCore

/// One fill as the ledger recorded it. Every figure is in satang or whole shares, and all of it is simulated.
public struct LedgerEntry: Sendable, Equatable {
    /// The entry's place in the log: 1 for the first fill, then 2, 3 and so on with no gap.
    public let ledgerSeq: UInt64
    public let orderId: String
    public let symbolId: UInt32
    public let side: Side
    /// The shares in this fill (not in the whole order); always positive.
    public let quantity: Quantity
    /// The price of this fill, in satang per share.
    public let price: Price
    /// The commission this fill was charged, never negative. The commission of an order is worked out on all of its
    /// fills so far, so the commissions of its partial fills add up to exactly the commission on its total value.
    public let commission: Int64
    /// What the fill did to cash: `-(price * quantity + commission)` for a buy, `price * quantity - commission` for a
    /// sell.
    public let cashDelta: Int64
    public let cashAfter: Int64
    /// The position in this symbol after the fill; 0 when the fill closed it.
    public let positionAfter: Quantity
    /// When the fill happened, in nanoseconds since the Unix epoch, exactly as the caller gave it.
    public let tsNs: Int64

    public init(
        ledgerSeq: UInt64, orderId: String, symbolId: UInt32, side: Side, quantity: Quantity, price: Price,
        commission: Int64, cashDelta: Int64, cashAfter: Int64, positionAfter: Quantity, tsNs: Int64
    ) {
        self.ledgerSeq = ledgerSeq
        self.orderId = orderId
        self.symbolId = symbolId
        self.side = side
        self.quantity = quantity
        self.price = price
        self.commission = commission
        self.cashDelta = cashDelta
        self.cashAfter = cashAfter
        self.positionAfter = positionAfter
        self.tsNs = tsNs
    }
}

/// The simulated commission on a trade.
public enum Commission: Sendable {
    /// `notional * bps / 10_000` in satang, rounded half up: `(notional * bps + 5_000) / 10_000`. The product is formed
    /// in 128 bits, so it cannot overflow on the way, and a result too large for `Int64` is cut at `Int64.max`.
    /// A notional or a rate that is zero or negative has nothing to charge on, or at, and gives 0: a negative
    /// commission would pay the customer.
    public static func compute(notional: Int64, bps: Int) -> Int64 {
        guard notional > 0, bps > 0 else { return 0 }
        return Int64(clamping: (Int128(notional) * Int128(bps) + 5_000) / 10_000)
    }
}

/// What one live order has set aside. A buy sets aside cash, a sell sets aside shares.
struct Reservation: Sendable, Equatable {
    let side: Side
    let symbolId: UInt32
    /// The price the reservation was made at. A buy may not fill above it. A sell keeps it as a record only: a sell
    /// fills at any positive price, because a market sell sweeps down through the bids.
    let price: Price
    /// Shares not yet filled; positive for as long as the reservation lives.
    var remainingQuantity: Quantity
    /// The cash a buy still holds back, always 0 for a sell. It starts at `price * quantity` plus the commission on
    /// that value, and each fill takes exactly what it costs out of it.
    var reservedCash: Int64
    /// The value of the fills so far, which the commission of the next fill is worked out from.
    var filledNotional: Int64 = 0

    /// Whether `reservedCash` still pays for the worst the order can still do: every remaining share filling at the
    /// reserved price, with the commission that adds to what the fills so far were charged.
    func coversWhatIsLeft(commissionBps: Int) -> Bool {
        guard let remainingValue = price.notional(quantity: remainingQuantity),
              let total = filledNotional.adding(remainingValue)
        else { return false }
        let fee = Commission.compute(notional: total, bps: commissionBps)
            - Commission.compute(notional: filledNotional, bps: commissionBps)
        guard let needed = remainingValue.adding(fee) else { return false }
        return reservedCash >= needed
    }
}

private extension Int64 {
    /// `self + other`, or nil if the sum does not fit in an `Int64`.
    func adding(_ other: Int64) -> Int64? {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? nil : sum
    }
}

/// The demo account of the mock exchange: cash, positions, the cash and shares held back for resting orders, and the
/// log of fills. One account, in memory, in satang and whole shares. The exchange engine owns one `Ledger` and calls
/// `reserve`, `applyFill` and `release`; everything else here is read-only.
///
/// **Reservations.** An order reserves before it can fill, so two resting orders can never promise the same cash or
/// the same shares. A buy of `quantity` at `price` holds `quantity * price` plus the commission on that value; for a
/// market order the caller passes the worst price the sweep reaches and the quantity it sweeps, so the reservation
/// covers every fill. A sell holds `quantity` shares. `availableCash` is cash less what the live buys hold and
/// `availableQuantity` a position less what the live sells hold: a new order is checked against those.
///
/// **Fills.** A fill pays out of its own reservation, so a partial fill leaves `availableCash` and
/// `availableQuantity` where they were. What a buy's cheaper fills leave of its reservation is held until the last
/// share fills, and then the whole reservation ends and the surplus becomes available cash at once. A reservation also
/// ends at `release` (a cancel), when whatever it still holds becomes available.
///
/// **Commission.** The commission of a fill is the commission on the order's cumulative filled value less what its
/// earlier fills were charged, so partial fills add up to exactly the commission on the total, with no rounding drift.
///
/// **Invariants.** Cash, `availableCash` and every position are never negative; a position that returns to zero is
/// removed from `positions` rather than kept as a zero; the sum of the entries' `cashDelta` is the change in cash.
/// `invariantsHold()` checks these and more.
///
/// No operation traps or wraps for any argument, `Int64` extremes included: a call whose arithmetic would overflow is
/// refused with nothing changed.
///
/// The stored state is `internal(set)` so that tests can corrupt it and see `invariantsHold()` notice; only the
/// operations below change it otherwise.
public struct Ledger: Sendable, Equatable {
    /// The highest commission rate the ledger accepts, in basis points: 100%. Above it a sell's commission could
    /// exceed its proceeds, and cash and `availableCash` could go negative.
    static let maxCommissionBps = 10_000

    let startingCash: Int64
    let commissionBps: Int

    public internal(set) var cash: Int64
    /// Shares held per symbol. A symbol with no shares has no key.
    public internal(set) var positions: [UInt32: Quantity] = [:]
    /// Every fill, oldest first, with `ledgerSeq` counting up from 1.
    public internal(set) var entries: [LedgerEntry] = []
    /// The live reservations by order id. An order id is free again once its reservation has ended.
    var reservations: [String: Reservation] = [:]
    /// The cash held by all the live buys, kept in step with `reservations` so that `availableCash` is O(1).
    var totalReservedCash: Int64 = 0
    /// The shares held by the live sells, per symbol, kept in step with `reservations`. A symbol with none has no key.
    var reservedShares: [UInt32: Quantity] = [:]

    /// A new account. A negative `startingCash` is taken as 0 and a negative `commissionBps` as 0, and a rate above
    /// 10,000 (100%) as 10,000, so that a ledger can never start in a state its own invariants forbid.
    public init(startingCash: Int64 = 100_000_000, commissionBps: Int = 15) {
        self.startingCash = max(startingCash, 0)
        self.commissionBps = min(max(commissionBps, 0), Self.maxCommissionBps)
        cash = self.startingCash
    }

    /// Cash that no live buy has a claim on.
    public var availableCash: Int64 {
        cash - totalReservedCash
    }

    /// Shares of `symbolId` that no live sell has a claim on.
    public func availableQuantity(symbolId: UInt32) -> Quantity {
        positions[symbolId, default: 0] - reservedShares[symbolId, default: 0]
    }

    /// Sets cash or shares aside for an order. Returns false, changing nothing, for a quantity or a price that is zero
    /// or negative, an `orderId` that already has a live reservation, a buy whose cost and commission exceed
    /// `availableCash`, a sell of more than `availableQuantity`, or any amount that does not fit in an `Int64`. A
    /// sell's price must be positive but is only recorded: a sell reserves shares and never multiplies its price.
    public mutating func reserve(
        orderId: String, side: Side, symbolId: UInt32, quantity: Quantity, price: Price
    ) -> Bool {
        guard quantity > 0, price.satang > 0, reservations[orderId] == nil else { return false }
        var heldCash: Int64 = 0
        switch side {
        case .buy:
            guard let value = price.notional(quantity: quantity),
                  let held = value.adding(Commission.compute(notional: value, bps: commissionBps)),
                  held <= availableCash
            else { return false }
            heldCash = held
            totalReservedCash += held
        case .sell:
            guard quantity <= availableQuantity(symbolId: symbolId) else { return false }
            reservedShares[symbolId, default: 0] += quantity
        }
        reservations[orderId] = Reservation(
            side: side, symbolId: symbolId, price: price, remainingQuantity: quantity, reservedCash: heldCash
        )
        return true
    }

    /// Ends the reservation of `orderId`, if it has one: whatever it still holds becomes available. Releasing an order
    /// that has no reservation (unknown, never reserved, or already ended) does nothing, so it is safe to repeat.
    public mutating func release(orderId: String) {
        guard let reservation = reservations.removeValue(forKey: orderId) else { return }
        totalReservedCash -= reservation.reservedCash
        if reservation.side == .sell {
            reduceReservedShares(of: reservation.symbolId, by: reservation.remainingQuantity)
        }
    }

    /// Records one fill of a reserved order and returns its log entry, or returns nil, changing nothing, for an
    /// unknown order or one whose reservation has ended, a side or symbol that is not the reservation's, a quantity
    /// that is zero, negative or more than remains, a price that is zero or negative, a buy above the reserved price,
    /// or a result that does not fit in an `Int64`: a value, a total value, the cash or the position. A sell has no
    /// price limit beyond being positive.
    ///
    /// A buy's cash falls by the fill's cost and commission, taken out of the reservation; a sell's rises by its
    /// proceeds less its commission, and its shares leave the reservation. When the last share fills the reservation
    /// ends.
    public mutating func applyFill(
        orderId: String, symbolId: UInt32, side: Side, quantity: Quantity, price: Price, tsNs: Int64
    ) -> LedgerEntry? {
        guard var reservation = reservations[orderId],
              reservation.side == side, reservation.symbolId == symbolId,
              quantity > 0, quantity <= reservation.remainingQuantity,
              price.satang > 0, side == .sell || price <= reservation.price,
              let value = price.notional(quantity: quantity),
              let filledNotional = reservation.filledNotional.adding(value)
        else { return nil }
        let commission = Commission.compute(notional: filledNotional, bps: commissionBps)
            - Commission.compute(notional: reservation.filledNotional, bps: commissionBps)
        // 128 bits, so that what does not fit in the cash is refused and does not trap.
        let change = side == .buy ? -(Int128(value) + Int128(commission)) : Int128(value) - Int128(commission)
        let held = positions[symbolId, default: 0]
        let (positionAfter, positionOverflows) = side == .buy
            ? held.addingReportingOverflow(quantity) : held.subtractingReportingOverflow(quantity)
        guard let cashDelta = Int64(exactly: change), let cashAfter = Int64(exactly: Int128(cash) + change),
              !positionOverflows
        else { return nil }

        cash = cashAfter
        positions[symbolId] = positionAfter == 0 ? nil : positionAfter
        if side == .buy {
            // `cashDelta` is negative: the reservation pays for the fill, so cash and the reserved total fall together.
            reservation.reservedCash += cashDelta
            totalReservedCash += cashDelta
        } else {
            reduceReservedShares(of: symbolId, by: quantity)
        }
        reservation.remainingQuantity -= quantity
        reservation.filledNotional = filledNotional
        if reservation.remainingQuantity == 0 {
            totalReservedCash -= reservation.reservedCash
            reservations[orderId] = nil
        } else {
            reservations[orderId] = reservation
        }
        let entry = LedgerEntry(
            ledgerSeq: UInt64(entries.count) + 1, orderId: orderId, symbolId: symbolId, side: side,
            quantity: quantity, price: price, commission: commission, cashDelta: cashDelta, cashAfter: cashAfter,
            positionAfter: positionAfter, tsNs: tsNs
        )
        entries.append(entry)
        return entry
    }

    private mutating func reduceReservedShares(of symbolId: UInt32, by quantity: Quantity) {
        let left = reservedShares[symbolId, default: 0] - quantity
        reservedShares[symbolId] = left == 0 ? nil : left
    }

    // MARK: - Invariants

    /// Whether the ledger is sound. It checks that cash, `availableCash` and every position are not negative and no
    /// position is a stored zero; that the log explains the ledger (see `logExplainsTheLedger`); and that the
    /// reservations are consistent with the cash and shares they are said to hold. It does one pass over the entries
    /// and one over the reservations, and does not depend on the order of the dictionaries. It never traps, whatever
    /// state it is given.
    public func invariantsHold() -> Bool {
        guard cash >= 0, totalReservedCash >= 0, availableCash >= 0, positions.values.allSatisfy({ $0 > 0 }) else {
            return false
        }
        return logExplainsTheLedger() && reservationsAreSound()
    }

    /// The entries are numbered 1, 2, 3 and so on without a gap; each is positive and priced, and its `cashDelta`
    /// agrees with its own price, quantity and commission; running the log from `startingCash` gives each entry's
    /// `cashAfter` and ends at `cash`; running it from nothing gives each entry's `positionAfter` and ends at
    /// `positions`. The arithmetic is `Int64` with overflow reporting: every amount a sound log holds fits, and one
    /// that does not is a failed check, not a trap.
    private func logExplainsTheLedger() -> Bool {
        var cashSoFar = startingCash
        var positionSoFar: [UInt32: Quantity] = [:]
        var expectedSeq: UInt64 = 0
        for entry in entries {
            expectedSeq += 1
            guard entry.ledgerSeq == expectedSeq, entry.quantity > 0, entry.price.satang > 0, entry.commission >= 0,
                  let value = entry.price.notional(quantity: entry.quantity)
            else { return false }
            let isBuy = entry.side == .buy
            let (net, netOverflows) = isBuy
                ? value.addingReportingOverflow(entry.commission) : value.subtractingReportingOverflow(entry.commission)
            let (cashNow, cashOverflows) = cashSoFar.addingReportingOverflow(entry.cashDelta)
            // Storing the entry's position first lets the one lookup also return the position before it.
            let before = positionSoFar.updateValue(entry.positionAfter, forKey: entry.symbolId) ?? 0
            let (position, positionOverflows) = isBuy
                ? before.addingReportingOverflow(entry.quantity) : before.subtractingReportingOverflow(entry.quantity)
            guard !netOverflows, !cashOverflows, !positionOverflows,
                  entry.cashDelta == (isBuy ? -net : net), entry.cashAfter == cashNow,
                  position >= 0, entry.positionAfter == position
            else { return false }
            cashSoFar = cashNow
        }
        return cashSoFar == cash && positionSoFar.filter { $0.value != 0 } == positions
    }

    /// Every live reservation has shares left; a buy still covers the worst its remaining shares can cost and a sell
    /// holds no cash. The cash the reservations hold is exactly `cash - availableCash`, and the shares they hold are
    /// exactly `reservedShares` and no more than the positions.
    private func reservationsAreSound() -> Bool {
        var cashHeld: Int128 = 0
        var sharesHeld: [UInt32: Quantity] = [:]
        for reservation in reservations.values {
            guard reservation.remainingQuantity > 0 else { return false }
            switch reservation.side {
            case .buy:
                guard reservation.coversWhatIsLeft(commissionBps: commissionBps) else { return false }
                cashHeld += Int128(reservation.reservedCash)
            case .sell:
                guard reservation.reservedCash == 0,
                      let total = sharesHeld[reservation.symbolId, default: 0].adding(reservation.remainingQuantity)
                else { return false }
                sharesHeld[reservation.symbolId] = total
            }
        }
        return cashHeld == Int128(cash) - Int128(availableCash)
            && sharesHeld == reservedShares
            && sharesHeld.allSatisfy { positions[$0.key, default: 0] >= $0.value }
    }
}

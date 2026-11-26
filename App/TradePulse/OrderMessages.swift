import TradeCore

/// Every sentence the order screens say about an order or a form, written once.
///
/// The sentences for the reasons an order can be refused (`text(for:)`) are the base. The ticket, which knows more than
/// the reason alone (the price step at the typed price, the reference price and its band), adds that to the base
/// sentence of the same reason instead of writing a second wording. None of the sentences holds a case name or any
/// other word that only the code uses.
enum OrderMessages {
    // MARK: Why the exchange refuses an order

    /// The plain-English sentence for `reason`, the same wherever the reason is shown: on the ticket before an order
    /// is sent and on an order row after the exchange refused it.
    static func text(for reason: RejectReason) -> String {
        switch reason {
        case .invalidQuantity: "The quantity must be from 100 to 10,000,000 shares."
        case .invalidLot: "The quantity must be a multiple of 100 shares."
        case .invalidTick: "The price is not a valid price step."
        case .outsidePriceBand: "The price is more than 30% from the reference price."
        case .insufficientFunds: "There is not enough cash for this order."
        case .insufficientPosition: "There are not enough shares to sell."
        case .unknownSymbol: "The exchange does not know this symbol."
        case .noLiquidity: "No shares were available to fill the order."
        case .invalidDuplicate: "This order id was already used for a different order."
        }
    }

    // MARK: What the ticket says about its form

    /// Asks for a quantity when the field is empty.
    static let enterQuantity = "Enter a quantity."
    /// Says that a quantity is whole shares written with the digits 0 to 9 and nothing else.
    static let quantityDigitsOnly = "A quantity is whole shares, digits 0-9 only."
    /// Says that a quantity has more digits than any order can have, and names the largest order.
    static let quantityTooLarge = "That quantity is too large: the most one order can have is 10,000,000 shares."
    /// Asks for a limit price when the field is empty.
    static let enterPrice = "Enter a limit price."
    /// Shows the shape of a price that could not be read.
    static let priceShape = "A price looks like 34.25: digits, a dot, at most two decimals."
    /// Says that a limit price of zero is not a price.
    static let priceAboveZero = "The limit price must be above zero."

    /// The base sentence for a price that is off the step, with the step that holds at the typed price.
    static func priceStep(_ step: Price) -> String {
        "\(text(for: .invalidTick)) A price must be a multiple of \(step) at this price level."
    }

    /// The base sentence for a price outside the band, with the reference price and the two edges of the band.
    static func priceBand(reference: Price, band: ClosedRange<Price>) -> String {
        "\(text(for: .outsidePriceBand)) A limit price must be within 30% of \(reference): "
            + "\(band.lowerBound) to \(band.upperBound)."
    }

    // MARK: Why the send button is off

    /// An order is being sent already.
    static let orderInFlight = "An order is on its way. Wait for its answer before sending another."
    /// The order service is not connected.
    static let tradingDisconnected = "The order service is not connected. Orders are paused until it is back."
    /// The market data is too old to price an order on.
    static let marketStale = "Prices are out of date. Orders are paused until the market feed is back."

    // MARK: Warnings that never block

    /// The warning for a buy that costs more than the cash the app knows of.
    static func cashHint(estimate: Int64, cash: Int64) -> String {
        let worth = MoneyFormat.baht(satang: estimate)
        let held = MoneyFormat.baht(satang: cash)
        return "The estimate of \(worth) is more than the \(held) of cash this app knows of, "
            + "so the exchange may reject the order."
    }

    /// The warning for a sale of more shares than the app knows are held.
    static func positionHint(held: Quantity, ticker: String) -> String {
        "This app knows of \(ShareFormat.grouped(held)) shares of \(ticker) held, fewer than this sale, "
            + "so the exchange may reject the order."
    }

    // MARK: What an order row says

    /// What a refused order says when the exchange gave no reason this app knows.
    static let notAccepted = "The exchange did not accept this order."
    /// What an order says when the exchange has not answered it.
    static let unconfirmed =
        "The exchange has not answered this order yet. Sending it again uses the same order id, "
        + "so it cannot create a second order."
}

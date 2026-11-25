import TradeCore
import TradeNetworking

/// What one order row on screen says, worked out from the order and whether the trading connection is up.
///
/// It holds only words and flags, so the Orders tab and the ticket draw the same row from it, and a test can pin every
/// status. A list builds one of these for the rows on screen only, from inside its row closure.
struct OrderRowPresentation: Identifiable, Equatable {
    /// How a status is drawn. The colour is never the only cue: each kind also has its own image.
    enum StatusKind: Equatable {
        /// The order is on its way or resting at the exchange: sending, open or partly filled.
        case working
        /// The order is complete.
        case done
        /// The order ended with nothing to complain about: it was cancelled.
        case neutral
        /// The order may or may not exist: the exchange has not answered.
        case warning
        /// The exchange did not accept the order.
        case failed

        /// The name of the SF Symbol that stands for the kind.
        var symbolName: String {
            switch self {
            case .working: "clock"
            case .done: "checkmark.circle.fill"
            case .neutral: "minus.circle"
            case .warning: "exclamationmark.triangle.fill"
            case .failed: "xmark.octagon.fill"
            }
        }
    }

    /// The row's id: the client order id.
    let id: String
    /// The exchange's id for the order, once it has one.
    let orderId: String?
    /// The side, the ticker and the type, with the limit price of a limit order: "Buy PTT · Limit 34.25".
    let title: String
    /// The shares filled and the shares asked for: "30 / 100".
    let quantityText: String
    /// The average price of the fills, or a dash before the first fill: "avg 34.25".
    let averageText: String
    /// The status in a word.
    let statusText: String
    /// How the status is drawn.
    let statusKind: StatusKind
    /// Why the order ended as it did, or what the exchange owes the app, when there is something to say.
    let reasonText: String?
    /// Whether the order can be cancelled now: open, known to the exchange and the trading connection is up.
    let canCancel: Bool
    /// Whether the order can be sent again with its own id: the exchange has not answered it.
    let canRetry: Bool
    /// The whole row as one sentence for VoiceOver.
    let accessibilityText: String

    /// The presentation of `row`, whose symbol is `ticker`, while the trading connection is up or not.
    init(row: OrderRow, ticker: String, tradingConnected: Bool) {
        let side = row.side == .buy ? "Buy" : "Sell"
        let priced = row.limitPrice.map { " \($0)" } ?? ""
        let (status, kind) = Self.status(of: row.status)
        let reason = Self.reason(of: row)
        id = row.id
        orderId = row.orderId
        title = "\(side) \(ticker) · " + (row.type == .limit ? "Limit" + priced : "Market")
        quantityText = ShareFormat.grouped(row.filledQuantity) + " / " + ShareFormat.grouped(row.quantity)
        averageText = row.averageFillPrice.map { "avg \($0)" } ?? "—"
        statusText = status
        statusKind = kind
        reasonText = reason
        let open = row.status == .accepted || row.status == .partiallyFilled
        canCancel = open && row.orderId != nil && tradingConnected
        canRetry = row.status == .unknown
        // The spoken line: "Buy PTT, limit 34.25, 30 of 100 shares, average price 34.20, Partly filled".
        var spoken = ["\(side) \(ticker)", (row.type == .limit ? "limit" + priced : "market")]
        spoken.append("\(ShareFormat.grouped(row.filledQuantity)) of \(ShareFormat.grouped(row.quantity)) shares")
        if let average = row.averageFillPrice {
            spoken.append("average price \(average)")
        }
        spoken.append(status)
        accessibilityText = spoken.joined(separator: ", ") + (reason.map { ". " + $0 } ?? "")
    }

    /// The word and the kind of `status`.
    private static func status(of status: OrderStatus) -> (String, StatusKind) {
        switch status {
        case .pending: ("Sending", .working)
        case .accepted: ("Open", .working)
        case .partiallyFilled: ("Partly filled", .working)
        case .filled: ("Filled", .done)
        case .cancelled: ("Cancelled", .neutral)
        case .rejected: ("Rejected", .failed)
        case .unknown: ("Unconfirmed", .warning)
        }
    }

    /// What `row` says about why it ended as it did: the reason of a rejection (or a sentence that the exchange gave
    /// none), the reason a cancelled order carries when there is one, and for an order the exchange has not answered
    /// what that means. Every other status has nothing to explain, whatever reason the row holds.
    private static func reason(of row: OrderRow) -> String? {
        switch row.status {
        case .rejected: row.rejectReason.map(OrderMessages.text(for:)) ?? OrderMessages.notAccepted
        case .cancelled: row.rejectReason.map(OrderMessages.text(for:))
        case .unknown: OrderMessages.unconfirmed
        case .pending, .accepted, .partiallyFilled, .filled: nil
        }
    }
}

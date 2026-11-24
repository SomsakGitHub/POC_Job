import Contracts
import TradeCore
import TradeNetworking

/// What one row of the market list shows, worked out from a symbol and its newest snapshot.
struct MarketRowModel: Identifiable, Equatable {
    /// What a row shows in place of a price it does not have.
    private static let noPrice = "\u{2014}"

    /// The symbol's id.
    let id: UInt32
    /// The short ticker.
    let ticker: String
    /// The company name in Thai.
    let nameTh: String
    /// The last price in baht, or a dash while the feed has not mentioned the symbol.
    let lastText: String
    /// The move from the reference price as a signed percentage, or a dash without a price.
    let changeText: String
    /// Which way the price moved from the reference; nil without a price.
    let direction: PriceChange.Direction?
    /// The whole row as one sentence for VoiceOver.
    let accessibilityText: String

    /// The row of `symbol`, with the price of `snapshot` when the feed has given one.
    init(symbol: SymbolDTO, snapshot: SymbolSnapshot?) {
        id = symbol.id
        ticker = symbol.ticker
        nameTh = symbol.nameTh
        let name = "\(symbol.ticker), \(symbol.nameTh)"
        guard let snapshot else {
            lastText = Self.noPrice
            changeText = Self.noPrice
            direction = nil
            accessibilityText = "\(name), no price yet"
            return
        }
        let change = PriceChange(last: snapshot.last, reference: Price(satang: symbol.reference))
        lastText = snapshot.last.description
        changeText = change.percentText
        direction = change.direction
        accessibilityText = "\(name), \(lastText) baht, \(Self.spoken(change.direction, percentText: changeText))"
    }

    /// The move as VoiceOver should say it: which way, and by how much without the sign and the percent sign. A flat
    /// price is spoken with its size as well (0.00), so that the three read alike.
    private static func spoken(_ direction: PriceChange.Direction, percentText: String) -> String {
        let size = percentText.drop { $0 == "+" || $0 == "-" }.dropLast()
        switch direction {
        case .up: return "up \(size) percent"
        case .down: return "down \(size) percent"
        case .flat: return "unchanged \(size) percent"
        }
    }
}

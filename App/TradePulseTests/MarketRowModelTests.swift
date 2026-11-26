import Contracts
import SwiftUI
import Testing
import TradeCore
@testable import TradePulse

/// What a row of the market list shows for a symbol with or without a price, and how a direction is drawn.
@Suite(.timeLimit(.minutes(1)))
struct MarketRowModelTests {
    /// PTT, whose reference price is 34.25.
    private let ptt = sampleSymbols[0]

    @Test func withoutASnapshotTheRowShowsNoPrice() {
        let model = MarketRowModel(symbol: ptt, snapshot: nil)
        #expect(model.id == 4)
        #expect(model.ticker == "PTT")
        #expect(model.nameTh == "ปตท.")
        #expect(model.lastText == "\u{2014}")
        #expect(model.changeText == "\u{2014}")
        #expect(model.direction == nil)
        #expect(model.accessibilityText == "PTT, ปตท., no price yet")
    }

    @Test func aPriceAboveTheReferenceIsUp() {
        let model = MarketRowModel(symbol: ptt, snapshot: snapshot(symbol: 4, last: 3_450))
        #expect(model.lastText == "34.50")
        #expect(model.changeText == "+0.73%")
        #expect(model.direction == .up)
        #expect(model.accessibilityText == "PTT, ปตท., 34.50 baht, up 0.73 percent")
    }

    @Test func aPriceBelowTheReferenceIsDown() {
        let model = MarketRowModel(symbol: ptt, snapshot: snapshot(symbol: 4, last: 3_400))
        #expect(model.lastText == "34.00")
        #expect(model.changeText == "-0.73%")
        #expect(model.direction == .down)
        #expect(model.accessibilityText == "PTT, ปตท., 34.00 baht, down 0.73 percent")
    }

    @Test func aPriceAtTheReferenceIsFlat() {
        let model = MarketRowModel(symbol: ptt, snapshot: snapshot(symbol: 4, last: 3_425))
        #expect(model.lastText == "34.25")
        #expect(model.changeText == "0.00%")
        #expect(model.direction == .flat)
        #expect(model.accessibilityText == "PTT, ปตท., 34.25 baht, unchanged 0.00 percent")
    }

    @Test func aReferenceOfZeroReadsFlatWhateverThePrice() {
        let symbol = SymbolDTO(id: 7, ticker: "NEW", nameTh: "ใหม่", nameEn: "New", reference: 0, lot: 100)
        let model = MarketRowModel(symbol: symbol, snapshot: snapshot(symbol: 7, last: 1_000))
        // There is nothing to measure against, and the whole price must not show up as a gain.
        #expect(model.lastText == "10.00")
        #expect(model.changeText == "0.00%")
        #expect(model.direction == .flat)
    }

    @Test func aMoveTooSmallToShowReadsFlatSoTheArrowAgreesWithTheText() {
        let symbol = SymbolDTO(id: 8, ticker: "BIG", nameTh: "ใหญ่", nameEn: "Big", reference: 100_000, lot: 100)
        let model = MarketRowModel(symbol: symbol, snapshot: snapshot(symbol: 8, last: 100_001))
        #expect(model.changeText == "0.00%")
        #expect(model.direction == .flat)
    }

    @Test func theRowIsTheSymbolItIsMadeFor() {
        let other = sampleSymbols[1]
        let model = MarketRowModel(symbol: other, snapshot: snapshot(symbol: 2, last: 5_800))
        #expect(model.id == 2)
        #expect(model.ticker == "AOT")
        #expect(model.nameTh == "ท่าอากาศยานไทย")
        #expect(model.changeText == "0.00%")
    }

    @Test func rowsOfTheSameSymbolAndPriceAreEqualAndAMovedPriceIsNot() {
        let first = MarketRowModel(symbol: ptt, snapshot: snapshot(symbol: 4, last: 3_450))
        let same = MarketRowModel(symbol: ptt, snapshot: snapshot(symbol: 4, last: 3_450))
        let moved = MarketRowModel(symbol: ptt, snapshot: snapshot(symbol: 4, last: 3_451))
        #expect(first == same)
        #expect(first != moved)
        #expect(first != MarketRowModel(symbol: ptt, snapshot: nil))
    }

    // MARK: Direction

    @Test func eachDirectionIsADifferentShapeAndColour() {
        let up = DirectionStyle(.up)
        let down = DirectionStyle(.down)
        let flat = DirectionStyle(.flat)
        #expect(up.symbolName == "arrowtriangle.up.fill")
        #expect(up.color == .green)
        #expect(down.symbolName == "arrowtriangle.down.fill")
        #expect(down.color == .red)
        #expect(flat.symbolName == "minus")
        #expect(flat.color == .secondary)
        // The shapes differ on their own, so that the direction does not depend on seeing colour.
        #expect(Set([up.symbolName, down.symbolName, flat.symbolName]).count == 3)
    }

    @Test func aRowWithNoPriceIsDrawnAsFlat() {
        #expect(DirectionStyle(nil) == DirectionStyle(.flat))
    }
}

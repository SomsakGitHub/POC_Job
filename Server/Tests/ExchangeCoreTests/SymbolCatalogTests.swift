import Testing
import TradeCore
@testable import ExchangeCore

private func requireSendable<T: Sendable>(_: T.Type) {}

struct SymbolCatalogTests {
    private let symbols = SymbolCatalog.defaultSymbols

    @Test func hasTwelveSymbolsWithIdsOneThroughTwelveInOrder() {
        #expect(symbols.count == 12)
        #expect(symbols.map(\.id) == Array(1...12))
        #expect(symbols.first?.ticker == "PTT")
    }

    /// PTT and AOT are in the catalog: the app opens PTT by name (`--open-symbol PTT`) and the tests of that launch argument use it.
    @Test func tickersAreUniqueUppercaseLatinAndIncludePTTAndAOT() {
        let tickers = symbols.map(\.ticker)

        #expect(Set(tickers).count == tickers.count)
        #expect(tickers.contains("PTT"))
        #expect(tickers.contains("AOT"))
        for ticker in tickers {
            #expect((1...6).contains(ticker.count), "\(ticker)")
            #expect(ticker.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }, "\(ticker)")
        }
    }

    /// This app names no bank brand of its own: one particular bank, and any of its brands, is named nowhere in it, and a
    /// search of the sources for that name must find nothing. So the words are spelled in pieces here and never as one
    /// literal. No
    /// field of any symbol may carry one: not as a ticker, and not inside an English or a Thai name. The Latin
    /// spellings are matched case-insensitively.
    @Test func noFieldNamesTheForbiddenBank() {
        let forbiddenLatin = ["kasi" + "korn", "k" + "bank", "k" + "securities"]
        // The Thai spelling of the same name, written as its five code points for the same reason.
        let forbiddenThai = ["\u{0E01}\u{0E2A}\u{0E34}\u{0E01}\u{0E23}"]

        for symbol in symbols {
            let latin = [symbol.ticker, symbol.nameEn, symbol.nameTh].map { $0.lowercased() }
            for field in latin {
                for word in forbiddenLatin {
                    #expect(!field.contains(word), "\(symbol.ticker): \(field) contains \(word)")
                }
            }
            for field in [symbol.ticker, symbol.nameEn, symbol.nameTh] {
                for word in forbiddenThai {
                    #expect(!field.contains(word), "\(symbol.ticker): \(field) contains \(word)")
                }
            }
        }
    }

    /// A Thai name is real Thai script: non-empty, at least one Thai letter, and no Latin letter anywhere in it.
    @Test func thaiNamesAreNonEmptyThaiScript() {
        let thaiBlock = 0x0E00...0x0E7F

        for symbol in symbols {
            let scalars = symbol.nameTh.unicodeScalars
            #expect(!symbol.nameTh.isEmpty, "\(symbol.ticker)")
            #expect(scalars.contains { thaiBlock.contains(Int($0.value)) }, "\(symbol.ticker): \(symbol.nameTh)")
            #expect(
                !scalars.contains { ("A"..."Z").contains($0) || ("a"..."z").contains($0) },
                "\(symbol.ticker): \(symbol.nameTh) mixes in Latin letters"
            )
        }
    }

    @Test func englishNamesAreNonEmpty() {
        for symbol in symbols {
            #expect(!symbol.nameEn.isEmpty, "\(symbol.ticker)")
        }
    }

    /// The reference prices are invented, positive and themselves on a tick: a reference that is not a valid price
    /// would make the first quote of the day look off the grid.
    @Test func referencePricesArePositiveAndOnTick() {
        for symbol in symbols {
            #expect(symbol.reference.satang > 0, "\(symbol.ticker)")
            #expect(TickRules.isOnTick(symbol.reference), "\(symbol.ticker): \(symbol.reference)")
        }
    }

    /// The twelve prices are spread over several tick tiers (and the market has to cope with each of them).
    @Test func referencePricesSpanSeveralTickSizes() {
        let tickSizes = Set(symbols.map { TickRules.tickSize(at: $0.reference).satang })

        #expect(tickSizes.count >= 4, "\(tickSizes.sorted())")
    }

    /// At least one price band straddles a tick-size change, so a walk through the band has to cross it.
    @Test func atLeastOneBandCrossesATickSizeChange() {
        let crossing = symbols.filter { symbol in
            let band = TickRules.band(reference: symbol.reference)
            return TickRules.tickSize(at: band.lowerBound) != TickRules.tickSize(at: band.upperBound)
        }

        #expect(!crossing.isEmpty)
    }

    @Test func symbolInfoIsEquatableAndSendable() {
        let ptt = symbols[0]
        let same = SymbolInfo(
            id: ptt.id, ticker: ptt.ticker, nameTh: ptt.nameTh, nameEn: ptt.nameEn, reference: ptt.reference
        )

        #expect(ptt == same)
        #expect(ptt != symbols[1])
        requireSendable(SymbolInfo.self)
    }
}

import Contracts
import Testing
@testable import TradePulse

/// The launch argument that opens one symbol's detail screen as the app starts: which ticker it names, which symbol
/// that is, and that the screen is pushed once.
@Suite(.timeLimit(.minutes(1)))
struct OpenSymbolRequestTests {
    // MARK: Reading the arguments

    @Test func theFlagWithAValueNamesTheTicker() {
        #expect(MarketListView.openSymbolRequest(in: ["TradePulse", "--open-symbol", "PTT"]) == "PTT")
        #expect(MarketListView.openSymbolRequest(in: ["TradePulse", "-a", "b", "--open-symbol", "AOT", "--c"]) == "AOT")
    }

    @Test func theFlagLastHasNoValue() {
        #expect(MarketListView.openSymbolRequest(in: ["TradePulse", "--open-symbol"]) == nil)
        #expect(MarketListView.openSymbolRequest(in: ["--open-symbol"]) == nil)
    }

    @Test func theFlagTwiceTheFirstWins() {
        let arguments = ["TradePulse", "--open-symbol", "AOT", "--open-symbol", "PTT"]
        #expect(MarketListView.openSymbolRequest(in: arguments) == "AOT")
    }

    @Test func aTickerInLowerCaseIsGivenAsItWas() {
        #expect(MarketListView.openSymbolRequest(in: ["TradePulse", "--open-symbol", "ptt"]) == "ptt")
    }

    @Test func noFlagNoRequest() {
        #expect(MarketListView.openSymbolRequest(in: []) == nil)
        #expect(MarketListView.openSymbolRequest(in: ["TradePulse"]) == nil)
        #expect(MarketListView.openSymbolRequest(in: ["TradePulse", "PTT"]) == nil)
        // Near misses are other flags.
        #expect(MarketListView.openSymbolRequest(in: ["TradePulse", "--open-symbols", "PTT"]) == nil)
        #expect(MarketListView.openSymbolRequest(in: ["TradePulse", "--open", "PTT"]) == nil)
        #expect(MarketListView.openSymbolRequest(in: ["TradePulse", "open-symbol", "PTT"]) == nil)
    }

    @Test func anEmptyValueIsNoRequest() {
        #expect(MarketListView.openSymbolRequest(in: ["TradePulse", "--open-symbol", ""]) == nil)
    }

    // MARK: Finding the symbol and pushing once

    @Test func theSymbolIsFoundWhateverTheCaseOfTheTicker() {
        let tickers = ["PTT", "ptt", "Ptt", "pTT"]
        #expect(tickers.count == 4)
        for ticker in tickers {
            var request = LaunchRequest(arguments: ["TradePulse", "--open-symbol", ticker])
            let id = request.take(from: sampleSymbols)
            #expect(id == 4, "\(ticker)")
        }
        var other = LaunchRequest(arguments: ["TradePulse", "--open-symbol", "cpall"])
        let cpall = other.take(from: sampleSymbols)
        #expect(cpall == 9)
    }

    @Test func nothingIsPushedBeforeTheSymbolsHaveLoadedAndTheRequestWaits() {
        var request = LaunchRequest(arguments: ["TradePulse", "--open-symbol", "AOT"])
        let early = request.take(from: [])
        let earlyAgain = request.take(from: [])
        let loaded = request.take(from: sampleSymbols)
        #expect(early == nil)
        #expect(earlyAgain == nil)
        #expect(loaded == 2)
    }

    @Test func theScreenIsPushedOnceAndNotAgainWhenTheUserComesBack() {
        var request = LaunchRequest(arguments: ["TradePulse", "--open-symbol", "AOT"])
        let first = request.take(from: sampleSymbols)
        let second = request.take(from: sampleSymbols)
        let third = request.take(from: sampleSymbols)
        #expect(first == 2)
        #expect(second == nil)
        #expect(third == nil)
    }

    @Test func anUnknownTickerDoesNothingAndDoesNotTryAgain() {
        var request = LaunchRequest(arguments: ["TradePulse", "--open-symbol", "ZZZ"])
        let first = request.take(from: sampleSymbols)
        #expect(first == nil)
        // A list that has the ticker later does not bring the request back.
        let zzz = SymbolDTO(id: 77, ticker: "ZZZ", nameTh: "ทดสอบ", nameEn: "Test", reference: 100, lot: 100)
        let later = request.take(from: sampleSymbols + [zzz])
        #expect(later == nil)

        // Control: a request for the same ticker is carried out when the list has it the first time.
        var found = LaunchRequest(arguments: ["TradePulse", "--open-symbol", "ZZZ"])
        let id = found.take(from: sampleSymbols + [zzz])
        #expect(id == 77)
    }

    @Test func noRequestNeverPushes() {
        var request = LaunchRequest(arguments: ["TradePulse"])
        let early = request.take(from: [])
        let loaded = request.take(from: sampleSymbols)
        var missing = LaunchRequest(arguments: ["TradePulse", "--open-symbol"])
        let noValue = missing.take(from: sampleSymbols)
        #expect(early == nil)
        #expect(loaded == nil)
        #expect(noValue == nil)

        // Control: the same list with the flag and a value does push.
        var asked = LaunchRequest(arguments: ["TradePulse", "--open-symbol", "PTT"])
        let id = asked.take(from: sampleSymbols)
        #expect(id == 4)
    }
}

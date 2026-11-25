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
            #expect(request.take(from: sampleSymbols) == 4, "\(ticker)")
        }
        var other = LaunchRequest(arguments: ["TradePulse", "--open-symbol", "cpall"])
        #expect(other.take(from: sampleSymbols) == 9)
    }

    @Test func nothingIsPushedBeforeTheSymbolsHaveLoadedAndTheRequestWaits() {
        var request = LaunchRequest(arguments: ["TradePulse", "--open-symbol", "AOT"])
        #expect(request.take(from: []) == nil)
        #expect(request.take(from: []) == nil)
        #expect(request.take(from: sampleSymbols) == 2)
    }

    @Test func theScreenIsPushedOnceAndNotAgainWhenTheUserComesBack() {
        var request = LaunchRequest(arguments: ["TradePulse", "--open-symbol", "AOT"])
        #expect(request.take(from: sampleSymbols) == 2)
        #expect(request.take(from: sampleSymbols) == nil)
        #expect(request.take(from: sampleSymbols) == nil)
    }

    @Test func anUnknownTickerDoesNothingAndDoesNotTryAgain() {
        var request = LaunchRequest(arguments: ["TradePulse", "--open-symbol", "ZZZ"])
        #expect(request.take(from: sampleSymbols) == nil)
        // A list that has the ticker later does not bring the request back.
        let zzz = SymbolDTO(id: 77, ticker: "ZZZ", nameTh: "ทดสอบ", nameEn: "Test", reference: 100, lot: 100)
        #expect(request.take(from: sampleSymbols + [zzz]) == nil)

        // Control: a request for the same ticker is carried out when the list has it the first time.
        var found = LaunchRequest(arguments: ["TradePulse", "--open-symbol", "ZZZ"])
        #expect(found.take(from: sampleSymbols + [zzz]) == 77)
    }

    @Test func noRequestNeverPushes() {
        var request = LaunchRequest(arguments: ["TradePulse"])
        #expect(request.take(from: []) == nil)
        #expect(request.take(from: sampleSymbols) == nil)
        var missing = LaunchRequest(arguments: ["TradePulse", "--open-symbol"])
        #expect(missing.take(from: sampleSymbols) == nil)

        // Control: the same list with the flag and a value does push.
        var asked = LaunchRequest(arguments: ["TradePulse", "--open-symbol", "PTT"])
        #expect(asked.take(from: sampleSymbols) == 4)
    }
}

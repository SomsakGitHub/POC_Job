import Foundation
import Testing
@testable import TradeNetworking

/// The JSON text of `text` as a dictionary, or nil if it is not a JSON object.
private func object(_ text: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
}

/// The control messages the market client sends, read back as JSON: exactly the keys the server reads, with the
/// values given, whatever characters a ticker holds.
@Suite struct FeedControlTests {
    @Test func subscribeHasOpAndSymbols() throws {
        let json = try #require(object(FeedControl.subscribe(["PTT", "AOT"])))
        #expect(Set(json.keys) == ["op", "symbols"])
        #expect(json["op"] as? String == "subscribe")
        #expect(json["symbols"] as? [String] == ["PTT", "AOT"])
    }

    @Test func unsubscribeHasOpAndSymbols() throws {
        let json = try #require(object(FeedControl.unsubscribe(["CPALL"])))
        #expect(Set(json.keys) == ["op", "symbols"])
        #expect(json["op"] as? String == "unsubscribe")
        #expect(json["symbols"] as? [String] == ["CPALL"])
    }

    @Test func pingHasOpAndClientNs() throws {
        let json = try #require(object(FeedControl.ping(clientNs: 1_732_000_000_123_456_789)))
        #expect(Set(json.keys) == ["op", "clientNs"])
        #expect(json["op"] as? String == "ping")
        #expect((json["clientNs"] as? NSNumber)?.int64Value == 1_732_000_000_123_456_789)
    }

    @Test func resyncHasOpAndSymbol() throws {
        let json = try #require(object(FeedControl.resync("PTT")))
        #expect(Set(json.keys) == ["op", "symbol"])
        #expect(json["op"] as? String == "resync")
        #expect(json["symbol"] as? String == "PTT")
    }

    /// A ticker with a quote, a backslash and a non-ASCII letter stays one string: the JSON is encoded, not
    /// concatenated.
    @Test func awkwardTickersStayInsideTheirStrings() throws {
        let ticker = #"P"T\T,"x":1 ไทย"#
        let resync = try #require(object(FeedControl.resync(ticker)))
        let subscribe = try #require(object(FeedControl.subscribe([ticker])))
        #expect(Set(resync.keys) == ["op", "symbol"])
        #expect(resync["symbol"] as? String == ticker)
        #expect(subscribe["symbols"] as? [String] == [ticker])
    }
}

/// The replies the market client reads: a pong and an error decode; anything else is `.unknown` and never a trap.
@Suite struct FeedReplyTests {
    @Test func pongDecodes() {
        let reply = FeedReply(text: #"{"clientNs":12,"op":"pong","serverNs":34}"#)
        #expect(reply == .pong(clientNs: 12, serverNs: 34))
    }

    @Test func errorDecodes() {
        let reply = FeedReply(text: #"{"message":"unknown symbols: NOPE","op":"error"}"#)
        #expect(reply == .error("unknown symbols: NOPE"))
    }

    /// Keys the client does not read are ignored, as the server ignores them.
    @Test func extraKeysAreIgnored() {
        let reply = FeedReply(text: #"{"op":"pong","clientNs":-5,"serverNs":7,"extra":[1,2]}"#)
        #expect(reply == .pong(clientNs: -5, serverNs: 7))
    }

    @Test(arguments: [
        "",
        "not json",
        #"{"op":"pong","clientNs":12"#,
        #"{"op":"pong","clientNs":"12","serverNs":34}"#,
        #"{"op":"pong","clientNs":12}"#,
        #"{"op":"pong","clientNs":1.5,"serverNs":34}"#,
        #"{"op":"error"}"#,
        #"{"op":"error","message":5}"#,
        #"{"op":"hello","message":"hi"}"#,
        #"{"op":7}"#,
        #"{"clientNs":12,"serverNs":34}"#,
        #"["op","pong"]"#,
        #"{"op":"pong","clientNs":99999999999999999999,"serverNs":1}"#,
        "null",
    ])
    func anythingElseIsUnknown(text: String) {
        #expect(FeedReply(text: text) == .unknown)
    }
}

/// The resync limiter: one resync per symbol per window on a monotonic clock, symbols independent, nothing queued.
@Suite struct ResyncLimiterTests {
    private let start = ContinuousClock.now

    @Test func twoGapsInsideTheWindowSendOne() {
        var limiter = ResyncLimiter()
        let first = limiter.admit(1, at: start)
        let second = limiter.admit(1, at: start + .milliseconds(999))
        #expect(first)
        #expect(!second)
    }

    /// A gap a whole window after the last resync sends again; the refused one in between does not move the window.
    @Test func aGapAfterTheWindowSendsAnother() {
        var limiter = ResyncLimiter()
        let first = limiter.admit(1, at: start)
        let refused = limiter.admit(1, at: start + .milliseconds(600))
        let again = limiter.admit(1, at: start + .seconds(1))
        let tooSoon = limiter.admit(1, at: start + .milliseconds(1_500))
        let third = limiter.admit(1, at: start + .milliseconds(2_100))
        #expect([first, refused, again, tooSoon, third] == [true, false, true, false, true])
    }

    @Test func symbolsAreLimitedIndependently() {
        var limiter = ResyncLimiter()
        let one = limiter.admit(1, at: start)
        let two = limiter.admit(2, at: start + .milliseconds(10))
        let oneAgain = limiter.admit(1, at: start + .milliseconds(20))
        let twoAgain = limiter.admit(2, at: start + .milliseconds(30))
        #expect([one, two, oneAgain, twoAgain] == [true, true, false, false])
    }

    @Test func theWindowIsOneSecond() {
        var limiter = ResyncLimiter()
        _ = limiter.admit(3, at: start)
        let justBefore = limiter.admit(3, at: start + .seconds(1) - .nanoseconds(1))
        let at = limiter.admit(3, at: start + .seconds(1))
        #expect(!justBefore)
        #expect(at)
    }
}

/// When the pings of one connection go out: eight rounds 50 ms apart from the start, then one every 30 s.
@Suite struct PingScheduleTests {
    @Test func eightRoundsThenEveryThirtySeconds() {
        let delays = (0..<11).map { PingSchedule.delay(before: $0) }
        let expected: [Duration] = [.zero] + Array(repeating: .milliseconds(50), count: 7)
            + Array(repeating: .seconds(30), count: 3)
        #expect(delays == expected)
    }
}

/// The request that opens a feed connection.
@Suite struct FeedRequestTests {
    private let config = ClientConfig(host: "127.0.0.1", restPort: 4_321)

    @Test func requestTargetsTheFeedWithATenSecondTimeout() {
        let request = WebSocketMarketDataClient.makeRequest(config: config)
        #expect(request.url?.absoluteString == "ws://127.0.0.1:4321/ws/market")
        #expect(request.timeoutInterval == 10)
    }

    @Test func aTokenIsSentAsABearerHeader() {
        var config = config
        config.authToken = "s3cret"
        let request = WebSocketMarketDataClient.makeRequest(config: config)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
    }

    @Test(arguments: [nil, ""] as [String?])
    func noTokenNoHeader(token: String?) {
        var config = config
        config.authToken = token
        let request = WebSocketMarketDataClient.makeRequest(config: config)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.allHTTPHeaderFields?.isEmpty ?? true)
    }
}

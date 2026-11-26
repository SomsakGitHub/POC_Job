import Foundation
import Testing
import TradeNetworking
@testable import TradePulse

/// The notice for a server address that the config could not use. `ClientConfig` falls back to the default address,
/// 127.0.0.1 on port 18080, for a host or port that makes no URL, so a mistyped host would otherwise talk to the local
/// server without a word.
@Suite(.timeLimit(.minutes(1)))
struct ConfigNoticeTests {
    @Test func theDefaultConfigHasNoNotice() {
        #expect(AppEnvironment.configNotice(for: ClientConfig()) == nil)
    }

    @Test(arguments: [
        "localhost", "LOCALHOST", "[::1]", "127.0.0.1", "10.0.0.5", "exchange.example.com", "Exchange.Example.COM",
    ])
    func aHostThatIsUsedAsGivenHasNoNotice(host: String) {
        #expect(AppEnvironment.configNotice(for: ClientConfig(host: host)) == nil)
    }

    @Test(arguments: [1, 80, 8_080, 65_535])
    func aPortThatIsUsedAsGivenHasNoNotice(port: Int) {
        #expect(AppEnvironment.configNotice(for: ClientConfig(restPort: port)) == nil)
    }

    @Test(arguments: ["bad host", "", " ", "a/b", "a?b", "::1", "host:80"])
    func aHostThatMakesNoUrlGetsANoticeThatNamesTheDefaultAddress(host: String) {
        let notice = AppEnvironment.configNotice(for: ClientConfig(host: host))
        #expect(notice?.contains("127.0.0.1") == true)
        #expect(notice?.contains("18080") == true)
    }

    @Test(arguments: [70_000, 65_536, 0, -1])
    func aPortThatMakesNoUrlGetsANoticeThatNamesTheDefaultAddress(port: Int) {
        let notice = AppEnvironment.configNotice(for: ClientConfig(restPort: port))
        #expect(notice?.contains("127.0.0.1") == true)
        #expect(notice?.contains("18080") == true)
    }

    @Test func aGoodHostWithABadPortIsNoticedThroughThePortAlone() {
        // The host reads the same as the one in use, so only the port can give this away.
        let notice = AppEnvironment.configNotice(for: ClientConfig(host: "127.0.0.1", restPort: 70_000))
        #expect(notice?.contains("18080") == true)
    }

    @Test func aBadHostWithAGoodPortIsNoticedThroughTheHostAlone() {
        // The port reads the same as the one in use, so only the host can give this away.
        let notice = AppEnvironment.configNotice(for: ClientConfig(host: "bad host", restPort: 18_080))
        #expect(notice?.contains("127.0.0.1") == true)
    }

    @Test func aBadHostWithAnotherGoodPortNamesTheAddressInUseNotTheOneAskedFor() {
        let notice = AppEnvironment.configNotice(for: ClientConfig(host: "bad host", restPort: 9_000))
        #expect(notice?.contains("127.0.0.1") == true)
        #expect(notice?.contains("18080") == true)
        #expect(notice?.contains("9000") == false)
    }

    @Test func theNoticeIsOneLine() {
        let notice = AppEnvironment.configNotice(for: ClientConfig(host: "bad host"))
        #expect(notice != nil)
        #expect(notice?.contains("\n") == false)
    }

    // MARK: What the system does with the host

    @Test func anAddressInBracketsReadsWithoutThemInTheUrl() {
        // The reason the brackets of the configured host are removed before it is compared.
        #expect(ClientConfig(host: "[::1]").restBase.host == "::1")
        #expect(ClientConfig(host: "[::1]").restBase.port == 18_080)
    }
}

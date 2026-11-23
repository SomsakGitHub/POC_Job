import Foundation
import Testing
import TradeNetworking

private final class AuthHeaderStub: StubProtocol {
    static let shared = StubLedger()

    override class var ledger: StubLedger { shared }
}

/// The token header: set exactly when the config has a token that is not empty, on every call, and nowhere else.
///
/// Serialized because every test of the suite answers through the one stub class `AuthHeaderStub`, whose script and
/// ledger are shared: two tests at once would overwrite each other's answer and requests.
@Suite("RestAuthHeaderTests", .serialized)
struct RestAuthHeaderTests {
    private static let account = #"{"epoch":"E1","cash":1,"positions":[],"lastEventSeq":0,"lastLedgerSeq":0}"#

    @Test func authTokenHeaderAttachedWhenSet() async throws {
        let rig = StubRig(AuthHeaderStub.self, answer: .json(Self.account), config: ClientConfig(authToken: "s3cret"))
        defer { rig.finish() }
        _ = try await rig.client.account()
        let seen = try #require(rig.requests.first)
        #expect(rig.requests.count == 1)
        #expect(seen.header("Authorization") == "Bearer s3cret")
    }

    @Test func noAuthHeaderWhenNil() async throws {
        let rig = StubRig(AuthHeaderStub.self, answer: .json(Self.account), config: ClientConfig(authToken: nil))
        defer { rig.finish() }
        _ = try await rig.client.account()
        let seen = try #require(rig.requests.first)
        #expect(rig.requests.count == 1)
        #expect(seen.header("Authorization") == nil)
        #expect(seen.request.allHTTPHeaderFields?.keys.contains { $0.lowercased() == "authorization" } != true)
    }

    /// An empty token counts as none: no header, not a bare "Bearer ".
    @Test func anEmptyTokenSendsNoHeader() async throws {
        let rig = StubRig(AuthHeaderStub.self, answer: .json(Self.account), config: ClientConfig(authToken: ""))
        defer { rig.finish() }
        _ = try await rig.client.account()
        let seen = try #require(rig.requests.first)
        #expect(rig.requests.count == 1)
        #expect(seen.header("Authorization") == nil)

        // Positive control: the same call with a token does send it.
        let withToken = StubRig(AuthHeaderStub.self, answer: .json(Self.account), config: ClientConfig(authToken: "t"))
        defer { withToken.finish() }
        _ = try await withToken.client.account()
        #expect(withToken.requests.first?.header("Authorization") == "Bearer t")
    }

    /// Every call of the API carries the header, not only the ones that need it today.
    @Test(arguments: EndpointCase.all)
    func everyCallCarriesTheToken(endpoint: EndpointCase) async throws {
        let rig = StubRig(AuthHeaderStub.self, answer: endpoint.answer, config: ClientConfig(authToken: "tok"))
        defer { rig.finish() }
        try await endpoint.call(rig.client)
        let seen = try #require(rig.requests.first)
        #expect(rig.requests.count == 1)
        #expect(seen.header("Authorization") == "Bearer tok")
    }

    @Test(arguments: EndpointCase.all)
    func noCallCarriesAHeaderWithoutAToken(endpoint: EndpointCase) async throws {
        let rig = StubRig(AuthHeaderStub.self, answer: endpoint.answer, config: ClientConfig())
        defer { rig.finish() }
        try await endpoint.call(rig.client)
        let seen = try #require(rig.requests.first)
        #expect(rig.requests.count == 1)
        #expect(seen.header("Authorization") == nil)
    }

    /// The token travels in the header as it was given, and never in the URL.
    @Test func theTokenTravelsInTheHeaderOnly() async throws {
        let token = "a b&c=d/e+f%g"
        let rig = StubRig(AuthHeaderStub.self, answer: .json(Self.account), config: ClientConfig(authToken: token))
        defer { rig.finish() }
        _ = try await rig.client.account()
        let seen = try #require(rig.requests.first)
        #expect(seen.header("Authorization") == "Bearer " + token)
        let url = seen.request.url?.absoluteString ?? ""
        #expect(url == "http://127.0.0.1:18080/v1/account")
        #expect(!url.contains("Bearer"))
    }
}

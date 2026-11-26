import Foundation
import Testing
import TradeNetworking

/// Where the client finds the server: the defaults, what the environment overrides, and the two URLs built from it.
@Suite("ClientConfigTests")
struct ClientConfigTests {
    private static let defaultRestBase = "http://127.0.0.1:18080"
    private static let defaultWebSocketURL = "ws://127.0.0.1:18080/ws/market"

    // MARK: The environment

    @Test func defaultsPointAtTheLocalServer() {
        let config = ClientConfig()
        #expect(config.host == "127.0.0.1")
        #expect(config.restPort == 18080)
        #expect(config.grpcPort == 18051)
        #expect(config.authToken == nil)
    }

    @Test func fromEnvironmentReadsHostPortsAndToken() {
        let onlyTheHost = ClientConfig.fromEnvironment(["TRADEPULSE_HOST": "10.0.0.5"])
        #expect(onlyTheHost.host == "10.0.0.5")
        // Every variable that is not set keeps its default.
        #expect(onlyTheHost.restPort == 18080)
        #expect(onlyTheHost.grpcPort == 18051)
        #expect(onlyTheHost.authToken == nil)

        let everything = ClientConfig.fromEnvironment([
            "TRADEPULSE_HOST": "exchange.local",
            "TRADEPULSE_REST_PORT": "9000",
            "TRADEPULSE_GRPC_PORT": "9001",
            "TRADEPULSE_TOKEN": "s3cret",
            "SOMETHING_ELSE": "ignored",
        ])
        #expect(everything.host == "exchange.local")
        #expect(everything.restPort == 9000)
        #expect(everything.grpcPort == 9001)
        #expect(everything.authToken == "s3cret")

        // The two ports are read from their own variables.
        let ports = ClientConfig.fromEnvironment(["TRADEPULSE_REST_PORT": "1234"])
        #expect(ports.restPort == 1234)
        #expect(ports.grpcPort == 18051)
        let grpcOnly = ClientConfig.fromEnvironment(["TRADEPULSE_GRPC_PORT": "4321"])
        #expect(grpcOnly.restPort == 18080)
        #expect(grpcOnly.grpcPort == 4321)
    }

    @Test func anEmptyEnvironmentIsTheDefaultConfig() {
        #expect(ClientConfig.fromEnvironment([:]) == ClientConfig())
    }

    @Test func emptyValuesKeepTheDefaults() {
        let config = ClientConfig.fromEnvironment([
            "TRADEPULSE_HOST": "", "TRADEPULSE_REST_PORT": "", "TRADEPULSE_GRPC_PORT": "", "TRADEPULSE_TOKEN": "",
        ])
        #expect(config == ClientConfig())
        #expect(config.authToken == nil)
    }

    /// A port that is not a number or not a TCP port keeps that field's default and does not trap.
    @Test(arguments: [
        "abc", "0", "-1", "65536", "70000", "99999999999999999999", " 8080", "8080 ", "80.5", "0x1F90", "8080a", "١٢٣",
    ])
    func invalidPortsKeepTheDefaults(text: String) {
        let config = ClientConfig.fromEnvironment(["TRADEPULSE_REST_PORT": text, "TRADEPULSE_GRPC_PORT": text])
        #expect(config.restPort == 18080)
        #expect(config.grpcPort == 18051)
    }

    /// The first and the last port number are valid.
    @Test(arguments: [1, 65535])
    func theEdgePortsAreAccepted(port: Int) {
        let config = ClientConfig.fromEnvironment([
            "TRADEPULSE_REST_PORT": String(port), "TRADEPULSE_GRPC_PORT": String(port),
        ])
        #expect(config.restPort == port)
        #expect(config.grpcPort == port)
    }

    /// A bad port in one variable does not disturb the others.
    @Test func eachVariableIsJudgedOnItsOwn() {
        let config = ClientConfig.fromEnvironment([
            "TRADEPULSE_HOST": "10.0.0.5", "TRADEPULSE_REST_PORT": "nope", "TRADEPULSE_GRPC_PORT": "9001",
            "TRADEPULSE_TOKEN": "t",
        ])
        #expect(config.host == "10.0.0.5")
        #expect(config.restPort == 18080)
        #expect(config.grpcPort == 9001)
        #expect(config.authToken == "t")
    }

    /// The token is kept exactly as given, spaces and all: only an empty one means "none".
    @Test func tokenIsStoredAsGiven() {
        for token in [" padded token ", "ทดสอบ", "a.b-c_d", " "] {
            let config = ClientConfig.fromEnvironment(["TRADEPULSE_TOKEN": token])
            #expect(config.authToken == token)
        }
        #expect(ClientConfig(authToken: "kept as is").authToken == "kept as is")
        #expect(ClientConfig(authToken: "").authToken == "")
    }

    // MARK: The URLs

    @Test func urlsFollowHostAndRestPort() {
        let defaults = ClientConfig()
        #expect(defaults.restBase.absoluteString == Self.defaultRestBase)
        #expect(defaults.webSocketURL.absoluteString == Self.defaultWebSocketURL)

        let config = ClientConfig(host: "10.0.0.5", restPort: 9000, grpcPort: 9001)
        #expect(config.restBase.absoluteString == "http://10.0.0.5:9000")
        #expect(config.webSocketURL.absoluteString == "ws://10.0.0.5:9000/ws/market")
        #expect(config.restBase.scheme == "http")
        #expect(config.restBase.path.isEmpty)
        #expect(config.webSocketURL.scheme == "ws")
        #expect(config.webSocketURL.path == "/ws/market")
    }

    /// The gRPC port and the token are no part of either URL.
    @Test func otherFieldsDoNotChangeTheUrls() {
        let config = ClientConfig(grpcPort: -5, authToken: "token")
        #expect(config.restBase.absoluteString == Self.defaultRestBase)
        #expect(config.webSocketURL.absoluteString == Self.defaultWebSocketURL)
    }

    @Test func hostNamesAndAddressesAreAccepted() {
        for host in ["localhost", "exchange.example.com", "192.168.1.20", "xn--12cc"] {
            let config = ClientConfig(host: host, restPort: 1)
            #expect(config.restBase.absoluteString == "http://\(host):1", "\(host)")
            #expect(config.webSocketURL.absoluteString == "ws://\(host):1/ws/market", "\(host)")
        }
        // An IPv6 literal is written in brackets, as in any URL.
        let v6 = ClientConfig(host: "[::1]", restPort: 8080)
        #expect(v6.restBase.absoluteString == "http://[::1]:8080")
        #expect(v6.webSocketURL.absoluteString == "ws://[::1]:8080/ws/market")
    }

    /// A host that does not make a valid URL gives the default config's URLs, and nothing traps.
    @Test(arguments: [
        "", "bad host", " ", "a b", "::1", "host/with/slash", "a?b", "a#b", "user@host", "host:80", "a\nb",
    ])
    func aHostThatMakesNoUrlFallsBackToTheDefaultUrls(host: String) {
        let config = ClientConfig(host: host, restPort: 9000)
        #expect(config.restBase == ClientConfig().restBase)
        #expect(config.webSocketURL == ClientConfig().webSocketURL)
        #expect(config.restBase.absoluteString == Self.defaultRestBase)
        #expect(config.webSocketURL.absoluteString == Self.defaultWebSocketURL)
    }

    /// A port that is no TCP port gives the default config's URLs too. A negative one must not reach `URLComponents`,
    /// which traps on it.
    @Test(arguments: [0, -1, 65536, 70000, Int.max, Int.min])
    func aPortOutsideTheRangeFallsBackToTheDefaultUrls(port: Int) {
        let config = ClientConfig(host: "10.0.0.5", restPort: port)
        #expect(config.restBase.absoluteString == Self.defaultRestBase)
        #expect(config.webSocketURL.absoluteString == Self.defaultWebSocketURL)
    }

    /// Positive control for the two tests above: a valid host and port are not replaced by the default.
    @Test func aValidHostAndPortAreNotReplaced() {
        let config = ClientConfig(host: "10.0.0.5", restPort: 65535)
        #expect(config.restBase.absoluteString == "http://10.0.0.5:65535")
        #expect(config.webSocketURL.absoluteString == "ws://10.0.0.5:65535/ws/market")
    }

    /// The config is a plain value: changing a field changes the URLs built from it afterwards.
    @Test func urlsAreBuiltFromTheCurrentFields() {
        var config = ClientConfig()
        config.host = "10.1.2.3"
        config.restPort = 7000
        #expect(config.restBase.absoluteString == "http://10.1.2.3:7000")
        config.restPort = -1
        #expect(config.restBase.absoluteString == Self.defaultRestBase)
    }
}

import Foundation

/// Where the client finds the exchange server and how it identifies itself: a host, the port of the REST API and the
/// market feed, the port of the gRPC order service and an optional token.
///
/// The REST API and the market feed's WebSocket share one port; gRPC has a port of its own. The defaults are the ones
/// the server starts with, so a client and a server started with no options find each other.
public struct ClientConfig: Sendable, Equatable {
    /// The host name or address of the server. An IPv6 address is written in brackets, as in a URL: `[::1]`.
    public var host: String
    /// The port of the REST API and of the market feed's WebSocket.
    public var restPort: Int
    /// The port of the gRPC order service.
    public var grpcPort: Int
    /// The token every client sends as `authorization: Bearer <token>`; nil or empty means none, and then no header is
    /// sent. The exchange server in this repository ignores it: it is there so that a server that does check a token
    /// gets one without any client changing. Stored as it was given.
    public var authToken: String?

    /// A config for the server at `host`. Every parameter defaults to what the server starts with, so `ClientConfig()`
    /// finds a server that was started with no options. Nothing is checked here: a host or port that makes no URL is
    /// dealt with when the URLs are built (see `restBase`).
    public init(host: String = "127.0.0.1", restPort: Int = 18080, grpcPort: Int = 18051, authToken: String? = nil) {
        self.host = host
        self.restPort = restPort
        self.grpcPort = grpcPort
        self.authToken = authToken
    }

    /// The base of every REST URL: `http://<host>:<restPort>`.
    ///
    /// Built with `URLComponents`, and it never traps. A host or a port that does not make a valid URL (an empty host,
    /// one with a space or a slash in it, an IPv6 address without its brackets, a port that is not in 1...65535)
    /// gives the URL of the default config instead.
    public var restBase: URL {
        Self.url(scheme: "http", host: host, port: restPort, path: "") ?? Self.defaultURL(scheme: "http", path: "")
    }

    /// The URL of the market feed: `ws://<host>:<restPort>/ws/market`.
    ///
    /// Built like `restBase`, and with the same fallback: the default config's URL for a host or port that does not
    /// make a valid one.
    public var webSocketURL: URL {
        Self.url(scheme: "ws", host: host, port: restPort, path: "/ws/market")
            ?? Self.defaultURL(scheme: "ws", path: "/ws/market")
    }

    /// The config the environment describes: `TRADEPULSE_HOST`, `TRADEPULSE_REST_PORT`, `TRADEPULSE_GRPC_PORT` and
    /// `TRADEPULSE_TOKEN`. A variable that is not set, is empty or is not valid (a port that is not a number in
    /// 1...65535) leaves its field at the default; none of them can make this trap. An empty token is no token.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ClientConfig {
        var config = ClientConfig()
        if let host = env["TRADEPULSE_HOST"], !host.isEmpty {
            config.host = host
        }
        if let port = port(from: env["TRADEPULSE_REST_PORT"]) {
            config.restPort = port
        }
        if let port = port(from: env["TRADEPULSE_GRPC_PORT"]) {
            config.grpcPort = port
        }
        if let token = env["TRADEPULSE_TOKEN"], !token.isEmpty {
            config.authToken = token
        }
        return config
    }

    /// The TCP ports a client can connect to.
    private static let portRange = 1...65535

    private static func port(from text: String?) -> Int? {
        guard let text, let port = Int(text), portRange.contains(port) else { return nil }
        return port
    }

    /// `scheme://host:port` followed by `path`, or nil if `host` and `port` do not make a URL.
    ///
    /// The checks come before `URLComponents` because it is not enough on its own: it traps on a negative port and
    /// takes a port of 70000 or an empty host for a valid one.
    private static func url(scheme: String, host: String, port: Int, path: String) -> URL? {
        guard !host.isEmpty, portRange.contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = path
        return components.url
    }

    /// The URL of the default config, which is what a config that makes no URL of its own gets.
    private static func defaultURL(scheme: String, path: String) -> URL {
        let defaults = ClientConfig()
        let made = url(scheme: scheme, host: defaults.host, port: defaults.restPort, path: path)
        // The defaults are a plain IPv4 address and a valid port, which always make a URL. The root URL is only
        // there so that no input at all can make this trap.
        return made ?? URL(fileURLWithPath: "/")
    }
}

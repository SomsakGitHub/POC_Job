/// Listening addresses and simulation seed for the exchange server.
public struct ServerConfig: Sendable {
    public var host = "127.0.0.1"
    /// REST + WebSocket port; `0` binds an ephemeral port.
    public var restPort = 18080
    /// gRPC port; `0` binds an ephemeral port.
    public var grpcPort = 18051
    public var seed: UInt64 = 42

    public init() {}
}

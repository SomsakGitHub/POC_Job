/// Listening addresses, simulation seed and ledger settings for the exchange server. The executable builds one from
/// its command line with `init(arguments:)`.
public struct ServerConfig: Sendable, Equatable {
    public var host = "127.0.0.1"
    /// REST + WebSocket port; `0` binds an ephemeral port.
    public var restPort = 18080
    /// gRPC port; `0` binds an ephemeral port.
    public var grpcPort = 18051
    public var seed: UInt64 = 42
    /// How many order events the engine keeps for a client that reconnects and asks for what it missed. A client that
    /// asks for an event older than the oldest one kept has to reload its state instead.
    public var eventLogCapacity = 10_000
    /// The commission charged on every fill, in basis points of its value: 15 is 0.15%.
    public var commissionBps = 15

    /// The defaults: both servers on 127.0.0.1, REST on 18080 and gRPC on 18051, seed 42, 10,000 events kept and a
    /// commission of 15 basis points.
    public init() {}
}

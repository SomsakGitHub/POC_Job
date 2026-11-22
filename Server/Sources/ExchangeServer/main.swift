import ExchangeServerKit

// Usage: ExchangeServer [--rest-port N] [--grpc-port N] [--seed N]
var config = ServerConfig()
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    guard let value = arguments.popFirst() else {
        fatalError("missing value for \(flag)")
    }
    switch flag {
    case "--rest-port":
        guard let port = Int(value) else { fatalError("invalid --rest-port: \(value)") }
        config.restPort = port
    case "--grpc-port":
        guard let port = Int(value) else { fatalError("invalid --grpc-port: \(value)") }
        config.grpcPort = port
    case "--seed":
        guard let seed = UInt64(value) else { fatalError("invalid --seed: \(value)") }
        config.seed = seed
    default:
        fatalError("unknown flag \(flag); usage: ExchangeServer [--rest-port N] [--grpc-port N] [--seed N]")
    }
}

let app = ExchangeServerApp(config: config)
Task {
    let ports = await app.waitUntilListening()
    guard ports.rest != 0, ports.grpc != 0 else { return }  // run() ended before listening; it reports the error
    print("ExchangeServer listening on \(config.host): REST+WebSocket \(ports.rest), gRPC \(ports.grpc)")
}
try await app.run()

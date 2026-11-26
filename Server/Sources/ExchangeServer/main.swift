import ExchangeServerKit
import Foundation

// The exchange server executable. Usage: see `ServerCommandLine.usage`.
//
// Stdout carries one line only, `listening rest=<p> grpc=<p>`, once both servers are listening; scripts wait for it.
// It is written straight to the file descriptor, so it is never held in a buffer when stdout is a pipe or a file.
// Usage errors and failures go to stderr. Exit status: 0 after `--help`, 2 for a usage error, 1 when the servers
// stopped (or never came up) because of an error.

func writeLine(_ line: String, to handle: FileHandle) {
    handle.write(Data((line + "\n").utf8))
}

/// Runs both servers until they stop; prints the listening line once both are bound. Exits with status 1 when `run()`
/// fails or ends without both servers having been bound.
func serve(_ config: ServerConfig) async {
    let app = ExchangeServerApp(config: config)
    Task {
        let ports = await app.waitUntilListening()
        // 0 means run() ended before that server was listening; the code below reports it.
        guard ports.rest != 0, ports.grpc != 0 else { return }
        writeLine(ServerCommandLine.listeningLine(ports), to: .standardOutput)
    }
    do {
        try await app.run()
    } catch {
        writeLine("ExchangeServer: \(error)", to: .standardError)
        exit(ServerCommandLine.serversDidNotStartStatus)
    }
    let ports = await app.waitUntilListening()
    if ports.rest == 0 || ports.grpc == 0 {
        writeLine("ExchangeServer: the servers stopped before both were listening", to: .standardError)
        exit(ServerCommandLine.serversDidNotStartStatus)
    }
}

let plan = ServerCommandLine.plan(arguments: Array(CommandLine.arguments.dropFirst()))
switch plan {
case .help:
    writeLine(ServerCommandLine.usage, to: .standardOutput)
case .usageError(let message):
    writeLine("ExchangeServer: \(message)", to: .standardError)
    writeLine(ServerCommandLine.usage, to: .standardError)
case .run(let config):
    await serve(config)
}
if let status = plan.exitStatus {
    exit(status)
}

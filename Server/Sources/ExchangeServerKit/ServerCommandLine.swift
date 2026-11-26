/// Why the executable's command line could not be turned into a `ServerConfig`. Every case but `helpRequested` is a
/// mistake of the caller, and its `message` names the flag at fault.
public enum ServerArgumentError: Error, Equatable {
    /// `--help` or `-h`: not a mistake. The caller prints the usage text and stops.
    case helpRequested
    /// An argument in a flag's place that is not one of the flags.
    case unknownFlag(String)
    /// A flag that is the last argument, so it has no value.
    case missingValue(flag: String)
    /// A value that is not plain decimal digits, or a number outside the flag's range.
    case invalidValue(flag: String, value: String)

    /// One line for a person: what was wrong and, for a bad value, what the flag takes.
    public var message: String {
        switch self {
        case .helpRequested:
            "help requested"
        case .unknownFlag(let flag):
            "unknown flag \"\(flag)\""
        case .missingValue(let flag):
            "\(flag) needs a value"
        case .invalidValue(let flag, let value):
            "\(flag): invalid value \"\(value)\", expected \(ValueFlag(rawValue: flag)?.expected ?? "a number")"
        }
    }
}

extension ServerConfig {
    /// The defaults, changed by `arguments` (the command line without the program name), read left to right.
    ///
    /// Each flag takes exactly one value: `--rest-port N` and `--grpc-port N` (0 to 65535; 0 binds an ephemeral port),
    /// `--seed N` (a `UInt64`), `--event-log-capacity N` (at least 1) and `--commission-bps N` (0 to 10000). A value
    /// is plain decimal digits, nothing else. A flag given twice takes its later value. `--help` or `-h` stops the
    /// parse with `.helpRequested`. Never traps: every bad input is a thrown error.
    public init(arguments: [String]) throws(ServerArgumentError) {
        self.init()
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            if argument == "--help" || argument == "-h" { throw .helpRequested }
            guard let flag = ValueFlag(rawValue: argument) else { throw .unknownFlag(argument) }
            guard let value = remaining.popFirst() else { throw .missingValue(flag: argument) }
            guard flag.apply(value, to: &self) else { throw .invalidValue(flag: argument, value: value) }
        }
    }
}

/// The flags that take a value, with their ranges.
private enum ValueFlag: String {
    case restPort = "--rest-port"
    case grpcPort = "--grpc-port"
    case seed = "--seed"
    case eventLogCapacity = "--event-log-capacity"
    case commissionBps = "--commission-bps"

    /// What the flag takes, for an error message.
    var expected: String {
        switch self {
        case .restPort, .grpcPort: "a port from 0 to 65535"
        case .seed: "a number from 0 to 18446744073709551615"
        case .eventLogCapacity: "a number of at least 1"
        case .commissionBps: "basis points from 0 to 10000"
        }
    }

    /// Sets the flag's setting in `config` from `text`; false, with `config` unchanged, when `text` is not a valid
    /// value for the flag.
    func apply(_ text: String, to config: inout ServerConfig) -> Bool {
        // Only ASCII digits: `Int` and `UInt64` would also take a leading sign.
        guard !text.isEmpty, text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            return false
        }
        switch self {
        case .restPort, .grpcPort:
            guard let port = Int(text), (0...65_535).contains(port) else { return false }
            if self == .restPort { config.restPort = port } else { config.grpcPort = port }
        case .seed:
            guard let seed = UInt64(text) else { return false }
            config.seed = seed
        case .eventLogCapacity:
            guard let capacity = Int(text), capacity >= 1 else { return false }
            config.eventLogCapacity = capacity
        case .commissionBps:
            guard let bps = Int(text), (0...10_000).contains(bps) else { return false }
            config.commissionBps = bps
        }
        return true
    }
}

/// What the executable does with its command line, and the lines it prints.
public enum ServerCommandLine {
    /// The usage text, one line.
    public static let usage =
        "usage: ExchangeServer [--rest-port N] [--grpc-port N] [--seed N] [--event-log-capacity N] [--commission-bps N]"

    /// The exit status when `run()` ends before both servers are listening (a port in use, for example).
    public static let serversDidNotStartStatus: Int32 = 1

    /// The one line the executable prints to stdout once both servers are listening, with the ports they bound.
    /// Scripts wait for it and read the ports from it, so its form is fixed: `listening rest=<p> grpc=<p>`.
    public static func listeningLine(_ ports: BoundPorts) -> String {
        "listening rest=\(ports.rest) grpc=\(ports.grpc)"
    }

    /// What to do: run with a configuration, print the usage, or report a usage error.
    public enum Plan: Equatable {
        /// Run both servers with this configuration.
        case run(ServerConfig)
        /// Print `usage` to stdout and exit with status 0.
        case help
        /// Print the message and `usage` to stderr and exit with status 2.
        case usageError(String)

        /// The status to exit with at once: 0 for `.help`, 2 for `.usageError`, nil for `.run`.
        public var exitStatus: Int32? {
            switch self {
            case .run: nil
            case .help: 0
            case .usageError: 2
            }
        }
    }

    /// The plan for `arguments`, the command line without the program name.
    public static func plan(arguments: [String]) -> Plan {
        do {
            return .run(try ServerConfig(arguments: arguments))
        } catch .helpRequested {
            return .help
        } catch {
            return .usageError(error.message)
        }
    }
}

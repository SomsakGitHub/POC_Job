import Testing
@testable import ExchangeServerKit

/// The executable's command line, parsed without starting anything.
@Suite("ServerCommandLineTests")
struct ServerCommandLineTests {
    private let valueFlags = ["--rest-port", "--grpc-port", "--seed", "--event-log-capacity", "--commission-bps"]

    /// The error `arguments` gives, or nil (and a recorded issue) when they parse.
    private func parseError(_ arguments: [String]) -> ServerArgumentError? {
        do {
            _ = try ServerConfig(arguments: arguments)
            Issue.record("\(arguments) parsed; an error was expected")
            return nil
        } catch {
            return error
        }
    }

    @Test func noArgumentsGiveTheDefaultConfiguration() throws {
        let config = try ServerConfig(arguments: [])
        #expect(config == ServerConfig())
    }

    @Test func everyFlagSetsItsSetting() throws {
        let config = try ServerConfig(arguments: [
            "--rest-port", "8181", "--grpc-port", "9191", "--seed", "18446744073709551615",
            "--event-log-capacity", "25", "--commission-bps", "40",
        ])
        var expected = ServerConfig()
        expected.restPort = 8181
        expected.grpcPort = 9191
        expected.seed = .max
        expected.eventLogCapacity = 25
        expected.commissionBps = 40
        #expect(config == expected)
    }

    @Test func aLaterFlagOverridesAnEarlierOne() throws {
        let config = try ServerConfig(arguments: [
            "--rest-port", "1", "--grpc-port", "2", "--seed", "3", "--event-log-capacity", "4", "--commission-bps", "5",
            "--commission-bps", "50", "--event-log-capacity", "40", "--seed", "30", "--grpc-port", "20",
            "--rest-port", "10",
        ])
        #expect(config.restPort == 10)
        #expect(config.grpcPort == 20)
        #expect(config.seed == 30)
        #expect(config.eventLogCapacity == 40)
        #expect(config.commissionBps == 50)
    }

    @Test func theEdgesOfEveryRangeAreAccepted() throws {
        let low = try ServerConfig(arguments: [
            "--rest-port", "0", "--grpc-port", "0", "--seed", "0", "--event-log-capacity", "1", "--commission-bps", "0",
        ])
        let high = try ServerConfig(arguments: [
            "--rest-port", "65535", "--grpc-port", "65535", "--commission-bps", "10000",
            "--event-log-capacity", "9223372036854775807",
        ])
        #expect([low.restPort, low.grpcPort, low.eventLogCapacity, low.commissionBps] == [0, 0, 1, 0])
        #expect(low.seed == 0)
        #expect([high.restPort, high.grpcPort, high.commissionBps] == [65_535, 65_535, 10_000])
        #expect(high.eventLogCapacity == .max)
    }

    @Test func anUnknownFlagIsAnErrorThatNamesIt() {
        for flag in ["--host", "--rest_port", "-p", "8080", "--REST-PORT", ""] {
            let error = parseError([flag, "1"])
            #expect(error == .unknownFlag(flag))
            #expect(error?.message.contains("\"\(flag)\"") == true, "\(String(describing: error?.message))")
        }
        // A good flag first does not excuse a bad one after it.
        #expect(parseError(["--seed", "1", "--verbose"]) == .unknownFlag("--verbose"))
    }

    @Test func aFlagWithoutAValueIsAnErrorThatNamesIt() {
        for flag in valueFlags {
            let error = parseError(["--seed", "1", flag])
            #expect(error == .missingValue(flag: flag))
            #expect(error?.message.contains(flag) == true, "\(String(describing: error?.message))")
        }
    }

    /// A value is plain decimal digits: no sign, no space, no other base, nothing after the number.
    @Test func aValueThatIsNotPlainDigitsIsAnErrorThatNamesTheFlag() {
        for value in ["", "+5", "-1", " 5", "5 ", "5x", "0x10", "1e3", "1_000", "١٢", "abc", "--grpc-port"] {
            for flag in valueFlags {
                let error = parseError([flag, value])
                #expect(error == .invalidValue(flag: flag, value: value), "\(flag) \"\(value)\"")
                #expect(error?.message.contains(flag) == true, "\(String(describing: error?.message))")
            }
        }
    }

    @Test func aValueOutsideItsRangeIsAnErrorThatNamesTheFlag() {
        let cases: [(String, String)] = [
            ("--rest-port", "65536"), ("--grpc-port", "70000"), ("--grpc-port", "99999999999999999999"),
            ("--seed", "18446744073709551616"), ("--event-log-capacity", "0"),
            ("--event-log-capacity", "9223372036854775808"), ("--commission-bps", "10001"),
        ]
        for (flag, value) in cases {
            let error = parseError([flag, value])
            #expect(error == .invalidValue(flag: flag, value: value), "\(flag) \(value)")
            #expect(error?.message.contains(flag) == true, "\(String(describing: error?.message))")
            #expect(error?.message.contains(value) == true, "\(String(describing: error?.message))")
        }
    }

    @Test func helpIsAskedForWithEitherSpelling() {
        #expect(parseError(["--help"]) == .helpRequested)
        #expect(parseError(["-h"]) == .helpRequested)
        #expect(parseError(["--seed", "1", "--help"]) == .helpRequested)
    }

    @Test func helpPrintsTheUsageAndSucceeds() {
        let plan = ServerCommandLine.plan(arguments: ["-h"])
        #expect(plan == .help)
        #expect(plan.exitStatus == 0)
        for flag in valueFlags {
            #expect(ServerCommandLine.usage.contains(flag))
        }
        #expect(!ServerCommandLine.usage.contains("\n"))
    }

    @Test func aUsageErrorExitsWithStatusTwoAndSaysWhatWasWrong() {
        let plan = ServerCommandLine.plan(arguments: ["--grpc-port", "70000"])
        #expect(plan == .usageError(ServerArgumentError.invalidValue(flag: "--grpc-port", value: "70000").message))
        #expect(plan.exitStatus == 2)
        #expect(ServerCommandLine.plan(arguments: ["--host", "x"]).exitStatus == 2)
        #expect(ServerCommandLine.plan(arguments: ["--seed"]).exitStatus == 2)
    }

    @Test func goodArgumentsPlanARunWithThatConfiguration() throws {
        let plan = ServerCommandLine.plan(arguments: ["--rest-port", "0", "--grpc-port", "0"])
        #expect(plan == .run(.ephemeral))
        #expect(plan.exitStatus == nil)
    }

    @Test func theListeningLineNamesBothBoundPorts() {
        let line = ServerCommandLine.listeningLine(BoundPorts(rest: 18080, grpc: 51234))
        #expect(line == "listening rest=18080 grpc=51234")
    }
}

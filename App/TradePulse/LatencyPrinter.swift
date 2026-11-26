import Darwin
import Foundation
import TradeCore

/// Prints the latency line the measurement script reads: one line of JSON on standard output every five seconds, for as
/// long as the app runs, when it was launched with `--print-latency`.
///
/// The first line comes five seconds after the launch, and it comes when the server is down too: every metric is then
/// empty, with counts of 0 and nulls. A line is made at the moment it is written, so it says what the app measured
/// then. The waits, the clock and the writer are seams, so a test can run the loop without waiting and see every line.
struct LatencyPrinter: Sendable {
    /// The launch argument that asks for the lines.
    static let argument = "--print-latency"
    /// How long the printer waits between two lines.
    private static let interval = Duration.seconds(5)

    /// The recorder whose six metrics are in every line.
    private let latency: LatencyRecorder
    /// The pump whose frame and hitch counts are in every line.
    private let pump: FramePump
    /// How the printer waits.
    private let sleep: @Sendable (Duration) async throws -> Void
    /// The time of the line, in milliseconds since the Unix epoch.
    private let nowMs: @Sendable () -> Int64
    /// What a finished line, with its newline, is handed to.
    private let write: @Sendable (String) -> Void

    /// A printer of the lines of `latency` and `pump`. By default it waits with `Task.sleep`, reads the wall clock and
    /// writes to standard output, flushed, one line at a time.
    init(
        latency: LatencyRecorder, pump: FramePump,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        nowMs: @escaping @Sendable () -> Int64 = { WallClock.nowNs() / 1_000_000 },
        write: @escaping @Sendable (String) -> Void = { LatencyPrinter.write($0) }
    ) {
        self.latency = latency
        self.pump = pump
        self.sleep = sleep
        self.nowMs = nowMs
        self.write = write
    }

    // MARK: Whether to print

    /// Whether `arguments` ask for the lines: they hold the argument `--print-latency` exactly, wherever it stands. A
    /// longer name that starts with it, one with a value glued to it and any other spelling do not ask.
    static func wantsLatencyLines(in arguments: [String]) -> Bool {
        arguments.contains(argument)
    }

    /// Whether the app starts printing: when `arguments` ask for it and the process is not the host of a unit-test run,
    /// which would write the lines into the output of the tests.
    static func shouldStart(arguments: [String], isRunningUnitTests: Bool) -> Bool {
        !isRunningUnitTests && wantsLatencyLines(in: arguments)
    }

    // MARK: The loop

    /// Waits five seconds and writes a line, over and over, until the task is cancelled. A wait that ends in an error
    /// ends the loop, and so does a cancellation that comes during a wait: no line is written after it.
    @MainActor func run() async {
        while !Task.isCancelled {
            do {
                try await sleep(Self.interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let line = LatencyReporter.jsonLine(
                timestampMs: nowMs(), metrics: latency.snapshot(), frames: pump.frames, hitches: pump.hitches
            )
            write(line + "\n")
        }
    }

    // MARK: Writing

    /// Writes `text` to `handle` at once: straight to the file descriptor, with no buffer of the app's own. A pipe is
    /// buffered by the library that writes to it, and a line that waits in a buffer is a line that the script on the
    /// other end of the pipe does not see for as long as the buffer takes to fill.
    ///
    /// A pipe whose reader is gone must not end the app: the descriptor is told not to raise `SIGPIPE`, so the write
    /// fails with an error instead. It answers whether all of `text` was written.
    @discardableResult
    static func write(_ text: String, to handle: FileHandle = .standardOutput) -> Bool {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try handle.write(contentsOf: Data(text.utf8))
            return true
        } catch {
            return false
        }
    }
}

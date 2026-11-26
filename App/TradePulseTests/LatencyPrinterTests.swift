import Darwin
import Foundation
import Synchronization
import Testing
import TradeCore
@testable import TradePulse

/// `(arguments, wanted)`: the arguments the app was launched with and whether they ask for the latency lines.
private let argumentCases: [([String], Bool)] = [
    (["--print-latency"], true),
    (["/path/to/TradePulse", "--print-latency"], true),
    (["/path/to/TradePulse", "--open-symbol", "PTT", "--print-latency"], true),
    // What stands next to the argument does not matter.
    (["--print-latency", "PTT"], true), (["PTT", "--print-latency", "--open-symbol", "AOT"], true),
    ([], false), (["/path/to/TradePulse"], false), (["--open-symbol", "PTT"], false),
    // Only the exact argument counts: no prefix, no longer name, no value glued to it, no other spelling.
    (["--print-latency-x"], false), (["--print-latencyx"], false), (["--print-latency=1"], false),
    (["--print-lat"], false), (["print-latency"], false), (["-print-latency"], false), (["--Print-Latency"], false),
    (["x--print-latency"], false), ([" --print-latency"], false), (["--print-latency "], false),
]

/// What a writer was given, in order.
final class WrittenLines: Sendable {
    /// The strings written so far.
    private let strings = Mutex<[String]>([])

    /// Keeps `text`.
    func add(_ text: String) {
        strings.withLock { $0.append(text) }
    }

    /// Everything written, in order.
    var all: [String] { strings.withLock { $0 } }
}

/// The line the app prints every five seconds: when it is printed, what is in it, and that it leaves the app one line
/// at a time. The waits and the clock are doubles, so no test waits for five seconds.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LatencyPrinterTests {
    /// What a line says once it is read back as JSON.
    private struct Line {
        /// The time stamp in milliseconds.
        let t: Int64
        /// The frames counted.
        let frames: Int
        /// The hitches counted.
        let hitches: Int
        /// The summaries by metric name.
        let metrics: [String: [String: Any]]
    }

    /// The JSON in `written`, without the newline that ends it, or a record of why it is not.
    private func parse(_ written: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Line {
        let object = try JSONSerialization.jsonObject(with: Data(written.utf8))
        let top = try #require(object as? [String: Any], "a JSON object", sourceLocation: sourceLocation)
        let metrics = try #require(
            top["metrics"] as? [String: [String: Any]], "the metrics", sourceLocation: sourceLocation
        )
        return Line(
            t: try #require((top["t"] as? NSNumber)?.int64Value, "t", sourceLocation: sourceLocation),
            frames: try #require((top["frames"] as? NSNumber)?.intValue, "frames", sourceLocation: sourceLocation),
            hitches: try #require((top["hitches"] as? NSNumber)?.intValue, "hitches", sourceLocation: sourceLocation),
            metrics: metrics
        )
    }

    // MARK: When the lines are printed

    @Test(arguments: argumentCases)
    func theLinesAreWantedOnlyByTheExactArgument(launch: [String], wanted: Bool) {
        #expect(LatencyPrinter.wantsLatencyLines(in: launch) == wanted)
    }

    @Test func theAppStartsPrintingOnlyWhenAskedAndNeverInAUnitTestHost() {
        let asked = ["/path/to/TradePulse", "--print-latency"]
        let notAsked = ["/path/to/TradePulse"]

        #expect(LatencyPrinter.shouldStart(arguments: asked, isRunningUnitTests: false))
        #expect(!LatencyPrinter.shouldStart(arguments: asked, isRunningUnitTests: true))
        #expect(!LatencyPrinter.shouldStart(arguments: notAsked, isRunningUnitTests: false))
        #expect(!LatencyPrinter.shouldStart(arguments: notAsked, isRunningUnitTests: true))
    }

    // MARK: The loop

    @Test func oneLineIsWrittenAfterEveryWaitAndEveryWaitIsFiveSeconds() async {
        let rig = PumpRig()
        let log = EventLog()
        let written = WrittenLines()
        let sleeper = CountingSleeper(endsOnCall: 4, onCall: { log.add("wait \($0)") })
        let printer = LatencyPrinter(
            latency: rig.latency, pump: rig.pump, sleep: { try await sleeper.sleep($0) }, nowMs: { 1_700_000_000_000 },
            write: { log.add("write"); written.add($0) }
        )

        await printer.run()

        #expect(log.entries == ["wait 1", "write", "wait 2", "write", "wait 3", "write", "wait 4"])
        #expect(written.all.count == 3)
        #expect(sleeper.durations == Array(repeating: Duration.seconds(5), count: 4))
    }

    @Test func nothingIsWrittenBeforeTheFirstWaitIsOver() async {
        let rig = PumpRig()
        let written = WrittenLines()
        let sleeper = CountingSleeper(endsOnCall: 1)
        let printer = LatencyPrinter(
            latency: rig.latency, pump: rig.pump, sleep: { try await sleeper.sleep($0) }, nowMs: { 1 },
            write: { written.add($0) }
        )

        await printer.run()

        #expect(sleeper.durations == [.seconds(5)])
        #expect(written.all.isEmpty)
    }

    @Test func eachWrittenStringIsOneLineEndingInASingleNewlineAndParsesAsJson() async throws {
        let rig = PumpRig()
        let written = WrittenLines()
        let sleeper = CountingSleeper(endsOnCall: 3)
        let printer = LatencyPrinter(
            latency: rig.latency, pump: rig.pump, sleep: { try await sleeper.sleep($0) },
            nowMs: { 1_700_000_000_123 }, write: { written.add($0) }
        )

        await printer.run()

        let lines = written.all
        #expect(lines.count == 2)
        for text in lines {
            #expect(text.hasSuffix("\n"), "\(text)")
            #expect(text.filter { $0 == "\n" }.count == 1, "\(text)")
            let parsed = try parse(String(text.dropLast()))
            #expect(parsed.metrics.count == 6)
            #expect(parsed.t == 1_700_000_000_123)
        }
    }

    @Test func aLineIsMadeAtTheMomentItIsWritten() async throws {
        let rig = PumpRig()
        let clock = ManualClock(1_700_000_000_000)
        let written = WrittenLines()
        let sleeper = CountingSleeper(endsOnCall: 4)
        rig.step(at: 1.0)
        let latency = rig.latency
        let printer = LatencyPrinter(
            latency: latency, pump: rig.pump,
            sleep: { duration in
                // What happens during the wait: five seconds go by, one more latency is measured and one more frame
                // is shown, in a display frame that came 100 ms after the one before, which is a hitch.
                try await sleeper.sleep(duration)
                clock.set(clock.read() + 5_000)
                latency.record(.tickToApp, nanos: 1_500_000)
                await MainActor.run { rig.step(at: 1.0 + Double(clock.read() - 1_700_000_000_000) / 50_000) }
            },
            nowMs: { clock.read() }, write: { written.add($0) }
        )

        await printer.run()

        let parsed = try written.all.map { try parse(String($0.dropLast())) }
        #expect(parsed.map(\.t) == [1_700_000_005_000, 1_700_000_010_000, 1_700_000_015_000])
        #expect(parsed.map(\.frames) == [1, 2, 3])
        #expect(parsed.map(\.hitches) == [1, 2, 3])
        let counts = parsed.map { ($0.metrics["tickToApp"]?["count"] as? NSNumber)?.intValue }
        #expect(counts == [1, 2, 3])
    }

    @Test func aServerThatIsDownStillGivesLinesWithEveryMetricEmpty() async throws {
        let rig = PumpRig()
        let written = WrittenLines()
        let sleeper = CountingSleeper(endsOnCall: 2)
        let printer = LatencyPrinter(
            latency: rig.latency, pump: rig.pump, sleep: { try await sleeper.sleep($0) }, nowMs: { 42 },
            write: { written.add($0) }
        )

        await printer.run()

        let text = try #require(written.all.first, "one line was written")
        let parsed = try parse(String(text.dropLast()))
        #expect(written.all.count == 1)
        #expect(parsed.metrics.count == 6)
        for (name, summary) in parsed.metrics {
            #expect((summary["count"] as? NSNumber)?.intValue == 0, "\(name)")
            for key in ["p50Ns", "p95Ns", "p99Ns"] {
                #expect(summary[key] is NSNull, "\(name).\(key)")
            }
        }
        #expect(parsed.frames == 0)
        #expect(parsed.hitches == 0)
    }

    @Test func cancellingTheTaskEndsTheLoopWithoutAFurtherLine() async {
        let rig = PumpRig()
        let written = WrittenLines()
        let sleeper = FakeSleeper(.holdUntilReleased)
        let printer = LatencyPrinter(
            latency: rig.latency, pump: rig.pump, sleep: { try await sleeper.sleep($0) }, nowMs: { 7 },
            write: { written.add($0) }
        )
        let loop = Task { @MainActor in await printer.run() }
        await waitFor("the first wait") { sleeper.requested == 1 }
        let beforeTheFirstWaitEnds = written.all.count

        // The control: a wait that ends is followed by a line, and then by another wait.
        sleeper.release()
        await waitFor("the second wait") { sleeper.requested == 2 }
        let afterTheFirstWait = written.all.count

        loop.cancel()
        await loop.value

        #expect(beforeTheFirstWaitEnds == 0)
        #expect(afterTheFirstWait == 1)
        #expect(written.all.count == 1)
        #expect(sleeper.requested == 2)
    }

    @Test func aWaitThatFailsEndsTheLoopWithoutALine() async {
        let rig = PumpRig()
        let written = WrittenLines()
        let sleeper = FakeSleeper(.throwError(TestFailure()))
        let printer = LatencyPrinter(
            latency: rig.latency, pump: rig.pump, sleep: { try await sleeper.sleep($0) }, nowMs: { 7 },
            write: { written.add($0) }
        )

        await printer.run()

        #expect(sleeper.requested == 1)
        #expect(written.all.isEmpty)
    }

    // MARK: The default writer

    /// Makes reading from `handle` return at once when there is nothing to read.
    private func makeNonBlocking(_ handle: FileHandle) {
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
    }

    /// Everything that is in the pipe `handle` reads from right now, without waiting for more.
    private func available(in handle: FileHandle) -> String {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = read(handle.fileDescriptor, &buffer, buffer.count)
        return String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)
    }

    @Test func theDefaultWriterSendsEachLineAtOnceAndNotWhenABufferIsFull() {
        let pipe = Pipe()
        makeNonBlocking(pipe.fileHandleForReading)

        let first = LatencyPrinter.write("{\"a\":1}\n", to: pipe.fileHandleForWriting)
        let afterTheFirst = available(in: pipe.fileHandleForReading)
        let second = LatencyPrinter.write("{\"a\":2}\n", to: pipe.fileHandleForWriting)
        let afterTheSecond = available(in: pipe.fileHandleForReading)
        let nothingMore = available(in: pipe.fileHandleForReading)

        #expect(first)
        #expect(second)
        #expect(afterTheFirst == "{\"a\":1}\n")
        #expect(afterTheSecond == "{\"a\":2}\n")
        #expect(nothingMore.isEmpty)
    }

    @Test func aReaderThatIsGoneEndsTheWriteAndNotTheApp() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        // A process that does not ignore SIGPIPE is ended by the first write to a pipe nobody reads.
        let before = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, before) }

        let wrote = LatencyPrinter.write("{\"a\":1}\n", to: pipe.fileHandleForWriting)

        #expect(!wrote)
    }
}

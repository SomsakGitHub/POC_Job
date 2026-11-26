import Foundation
import Testing
import TradeCore
@testable import TradePulse

/// The line the app prints for the measurement script: one line of JSON with the six latency metrics, the frames and
/// the hitches. The line is built by hand, so that the order of the keys is the same in every line and nothing but
/// integers is written.
@Suite(.timeLimit(.minutes(1)))
struct LatencyReporterTests {
    /// Six summaries that differ in every field, so that a number written under the wrong key is caught.
    private let sample: [LatencyMetric: PercentileSummary] = [
        .tickToApp: PercentileSummary(count: 1_000, p50Ns: 1_500_000, p95Ns: 3_000_000, p99Ns: 4_500_000, clamped: 2),
        .tickToApplied: PercentileSummary(count: 999, p50Ns: 1_600_000, p95Ns: 3_100_000, p99Ns: 4_600_000, clamped: 0),
        .tickToRender: PercentileSummary(
            count: 998, p50Ns: 17_000_000, p95Ns: 33_000_000, p99Ns: 50_000_000, clamped: 7
        ),
        .orderSubmitToAck: PercentileSummary(
            count: 3, p50Ns: 9_000_000, p95Ns: 12_000_000, p99Ns: 12_500_000, clamped: 0
        ),
        .orderServerProcessing: PercentileSummary(count: 3, p50Ns: 800_000, p95Ns: 900_000, p99Ns: 950_000, clamped: 1),
        .orderSubmitToFill: PercentileSummary(count: 0, p50Ns: nil, p95Ns: nil, p99Ns: nil, clamped: 0),
    ]

    /// The line for `sample` at 1700000000123 ms with 3,600 frames and 4 hitches, written out in full.
    private let sampleLine = """
        {"t":1700000000123,"metrics":{\
        "tickToApp":{"count":1000,"p50Ns":1500000,"p95Ns":3000000,"p99Ns":4500000,"clamped":2},\
        "tickToApplied":{"count":999,"p50Ns":1600000,"p95Ns":3100000,"p99Ns":4600000,"clamped":0},\
        "tickToRender":{"count":998,"p50Ns":17000000,"p95Ns":33000000,"p99Ns":50000000,"clamped":7},\
        "orderSubmitToAck":{"count":3,"p50Ns":9000000,"p95Ns":12000000,"p99Ns":12500000,"clamped":0},\
        "orderServerProcessing":{"count":3,"p50Ns":800000,"p95Ns":900000,"p99Ns":950000,"clamped":1},\
        "orderSubmitToFill":{"count":0,"p50Ns":null,"p95Ns":null,"p99Ns":null,"clamped":0}},\
        "frames":3600,"hitches":4}
        """

    /// What a line says, read back with a JSON parser.
    private struct Parsed {
        /// The timestamp in milliseconds.
        let t: Int64
        /// The metrics by their raw value, each as the parser read it.
        let metrics: [String: [String: Any]]
        /// The frames counted.
        let frames: Int
        /// The hitches counted.
        let hitches: Int
    }

    /// Reads `line` as the JSON it has to be, or records why it is not.
    private func parse(_ line: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Parsed {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        let top = try #require(object as? [String: Any], "the line is a JSON object", sourceLocation: sourceLocation)
        let metrics = try #require(
            top["metrics"] as? [String: [String: Any]], "the metrics are an object of objects",
            sourceLocation: sourceLocation
        )
        return Parsed(
            t: try #require((top["t"] as? NSNumber)?.int64Value, "t is a number", sourceLocation: sourceLocation),
            metrics: metrics,
            frames: try #require(
                (top["frames"] as? NSNumber)?.intValue, "frames is a number", sourceLocation: sourceLocation
            ),
            hitches: try #require(
                (top["hitches"] as? NSNumber)?.intValue, "hitches is a number", sourceLocation: sourceLocation
            )
        )
    }

    // MARK: What the line must hold

    @Test func jsonLineContainsAllSixMetricsAndNoNegatives() throws {
        // A negative percentile is in the input on purpose: it must come out as null.
        var metrics = sample
        metrics[.tickToApp] = PercentileSummary(count: 4, p50Ns: -5, p95Ns: 3_000_000, p99Ns: Int64.min, clamped: 4)
        let line = LatencyReporter.jsonLine(timestampMs: 1_700_000_000_123, metrics: metrics, frames: 3_600, hitches: 4)
        let parsed = try parse(line)

        #expect(parsed.metrics.count == 6)
        #expect(Set(parsed.metrics.keys) == Set(LatencyMetric.allCases.map(\.rawValue)))
        var checked = 0
        for (name, object) in parsed.metrics {
            for key in ["p50Ns", "p95Ns", "p99Ns"] {
                let value = try #require(object[key], "\(name) has \(key)")
                if value is NSNull { continue }
                let number = try #require((value as? NSNumber)?.int64Value, "\(name).\(key) is a number or null")
                #expect(number >= 0, "\(name).\(key) is \(number)")
                checked += 1
            }
        }
        // The negative ones were not counted: 18 percentiles, 2 negative, 3 empty ones.
        #expect(checked == 13)
        #expect(!line.contains("-"))
        #expect(parsed.t == 1_700_000_000_123)
        #expect(parsed.frames == 3_600)
        #expect(parsed.hitches == 4)
    }

    @Test func emptyMetricsAreNull() throws {
        let line = LatencyReporter.jsonLine(timestampMs: 5, metrics: [:], frames: 0, hitches: 0)
        let parsed = try parse(line)

        #expect(parsed.metrics.count == 6)
        for metric in LatencyMetric.allCases {
            let object = try #require(parsed.metrics[metric.rawValue], "\(metric.rawValue) is there")
            #expect((object["count"] as? NSNumber)?.intValue == 0)
            #expect((object["clamped"] as? NSNumber)?.intValue == 0)
            for key in ["p50Ns", "p95Ns", "p99Ns"] {
                #expect(object[key] is NSNull, "\(metric.rawValue).\(key) is null")
            }
        }
    }

    // MARK: The exact line

    @Test func theLineForAFixedInputIsExactlyThisString() {
        let line = LatencyReporter.jsonLine(timestampMs: 1_700_000_000_123, metrics: sample, frames: 3_600, hitches: 4)
        #expect(line == sampleLine)
    }

    @Test func theMetricsComeInTheOrderOfTheMetricList() throws {
        let line = LatencyReporter.jsonLine(timestampMs: 1, metrics: sample, frames: 1, hitches: 1)
        let positions = LatencyMetric.allCases.map { metric in line.range(of: "\"\(metric.rawValue)\":")?.lowerBound }
        let found = try positions.map { try #require($0, "every metric is in the line") }
        #expect(found.count == 6)
        #expect(found == found.sorted())

        let names = LatencyMetric.allCases.map(\.rawValue)
        #expect(names == [
            "tickToApp", "tickToApplied", "tickToRender", "orderSubmitToAck", "orderServerProcessing",
            "orderSubmitToFill",
        ])
        // The fields of one metric are in a fixed order too.
        let fields = ["\"count\":", "\"p50Ns\":", "\"p95Ns\":", "\"p99Ns\":", "\"clamped\":"]
        let first = try #require(line.range(of: "\"tickToApp\":{"), "the first metric is there")
        let inFirst = String(line[first.lowerBound...])
        let offsets = try fields.map { field in
            try #require(inFirst.range(of: field)?.lowerBound, "\(field) is there")
        }
        #expect(offsets == offsets.sorted())
        #expect(line.hasPrefix("{\"t\":1,\"metrics\":{"))
        #expect(line.hasSuffix("},\"frames\":1,\"hitches\":1}"))
    }

    // MARK: Missing and out of range

    @Test func aMetricMissingFromTheDictionaryReadsAsAnEmptySummary() throws {
        var metrics = sample
        metrics.removeValue(forKey: .tickToApplied)
        metrics.removeValue(forKey: .orderSubmitToFill)
        let line = LatencyReporter.jsonLine(timestampMs: 9, metrics: metrics, frames: 2, hitches: 1)

        let empty = "{\"count\":0,\"p50Ns\":null,\"p95Ns\":null,\"p99Ns\":null,\"clamped\":0}"
        let parsed = try parse(line)
        #expect(line.contains("\"tickToApplied\":" + empty))
        #expect(line.contains("\"orderSubmitToFill\":" + empty))
        #expect(parsed.metrics.count == 6)
        // The ones that were given are untouched, so that "missing" is not "everything empty".
        #expect(line.contains("\"tickToApp\":{\"count\":1000,"))
    }

    @Test func aNegativePercentileIsWrittenAsNullAndNoMinusSignAppears() {
        let summary = PercentileSummary(count: 7, p50Ns: -1, p95Ns: Int64.min, p99Ns: -9_000, clamped: 7)
        let line = LatencyReporter.jsonLine(timestampMs: 3, metrics: [.tickToRender: summary], frames: 1, hitches: 0)
        let expected = "\"tickToRender\":{\"count\":7,\"p50Ns\":null,\"p95Ns\":null,\"p99Ns\":null,\"clamped\":7}"
        #expect(line.contains(expected))
        #expect(!line.contains("-"))
    }

    @Test func aPercentileOfZeroIsAZeroAndNotNull() {
        // Zero is a measurement (a latency below the clock's resolution), and only a missing or negative one is null.
        let summary = PercentileSummary(count: 2, p50Ns: 0, p95Ns: 0, p99Ns: 1, clamped: 0)
        let line = LatencyReporter.jsonLine(timestampMs: 3, metrics: [.tickToApp: summary], frames: 1, hitches: 0)
        #expect(line.contains("\"tickToApp\":{\"count\":2,\"p50Ns\":0,\"p95Ns\":0,\"p99Ns\":1,\"clamped\":0}"))
    }

    @Test func theLargestNumbersAreWrittenInFullAndParseBack() throws {
        let big = PercentileSummary(
            count: Int.max, p50Ns: Int64.max, p95Ns: Int64.max - 1, p99Ns: 10_000_000_000, clamped: Int.max
        )
        let line = LatencyReporter.jsonLine(
            timestampMs: Int64.max, metrics: [.tickToApp: big], frames: Int.max, hitches: Int.max
        )

        #expect(line.hasPrefix("{\"t\":9223372036854775807,"))
        #expect(line.contains(
            "\"tickToApp\":{\"count\":9223372036854775807,\"p50Ns\":9223372036854775807,"
                + "\"p95Ns\":9223372036854775806,\"p99Ns\":10000000000,\"clamped\":9223372036854775807}"
        ))
        #expect(line.hasSuffix("\"frames\":9223372036854775807,\"hitches\":9223372036854775807}"))
        // No exponent and no grouping, whatever the locale of the device: a comma never sits between two digits.
        #expect(!line.lowercased().contains("e+"))
        #expect(line.firstMatch(of: #/[0-9],[0-9]/#) == nil)
        let parsed = try parse(line)
        #expect(parsed.t == Int64.max)
        #expect(parsed.frames == Int.max)
        let object = try #require(parsed.metrics["tickToApp"])
        #expect((object["p50Ns"] as? NSNumber)?.int64Value == Int64.max)
    }

    // MARK: Shape

    @Test func theLineIsOneLineThatParsesIntoSixMetricObjects() throws {
        let line = LatencyReporter.jsonLine(timestampMs: 1_700_000_000_123, metrics: sample, frames: 3_600, hitches: 4)
        #expect(!line.contains("\n"))
        #expect(!line.contains("\r"))
        #expect(!line.contains(" "))
        let parsed = try parse(line)
        #expect(parsed.metrics.count == 6)
        for metric in LatencyMetric.allCases {
            let object = try #require(parsed.metrics[metric.rawValue])
            #expect(Set(object.keys) == ["count", "p50Ns", "p95Ns", "p99Ns", "clamped"])
        }
        // The same input gives the same line, so a script can compare lines.
        let again = LatencyReporter.jsonLine(timestampMs: 1_700_000_000_123, metrics: sample, frames: 3_600, hitches: 4)
        #expect(line == again)
    }
}

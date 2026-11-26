import Contracts
import Testing
import TradeCore
import TradeNetworking
@testable import TradePulse

/// `(state, words)`: a connection state and what the Lab says of it.
private let connectionCases: [(ConnectionState, String)] = [
    (.connected, "Connected"), (.connecting, "Connecting\u{2026}"),
    (.reconnecting(attempt: 2), "Reconnecting, attempt 2"), (.reconnecting(attempt: 12), "Reconnecting, attempt 12"),
    (.stopped, "Stopped"),
]

/// `(status, words)`: what a probe of the REST API found and the row that says so.
private let restCases: [(RestStatus, String)] = [
    (.unknown, "REST: checking\u{2026}"), (.reachable(rttNs: 3_210_000), "REST: reachable, 3.21 ms"),
    (.reachable(rttNs: 0), "REST: reachable, 0 ns"), (.reachable(rttNs: 1_234_567_890), "REST: reachable, 1.23 s"),
    (.unreachable, "REST: unreachable"),
]

/// `(rate, words)`: the rate multiplier as the Lab writes it.
private let rateCases: [(Double, String)] = [
    (1, "1.0\u{00D7}"), (0.5, "0.5\u{00D7}"), (2.5, "2.5\u{00D7}"), (4.5, "4.5\u{00D7}"), (0.1, "0.1\u{00D7}"),
    (10, "10.0\u{00D7}"), (0.25, "0.3\u{00D7}"), (0.24, "0.2\u{00D7}"), (0, "0.0\u{00D7}"), (123.45, "123.5\u{00D7}"),
    (.nan, "\u{2014}"), (.infinity, "\u{2014}"), (-1, "\u{2014}"), (1e30, "\u{2014}"),
]

/// `(count, words)`: a count of samples or events with a comma between groups of three digits.
private let countCases: [(Int, String)] = [
    (0, "0"), (7, "7"), (999, "999"), (1_000, "1,000"), (12_345, "12,345"), (1_234_567, "1,234,567"),
    (Int.max, "9,223,372,036,854,775,807"), (-1_234, "-1,234"),
]

/// The words and the arithmetic of the Lab screen that need no screen: the rows of the latency table, the texts of the
/// connections and of the account check, the choices of a segmented control, the rate and the count of gaps. The
/// frame counters are in `FrameStatisticsTests`.
@Suite(.timeLimit(.minutes(1)))
struct LabFormattingTests {
    /// What an empty metric summarises to.
    private let empty = PercentileSummary(count: 0, p50Ns: nil, p95Ns: nil, p99Ns: nil, clamped: 0)
    /// A summary whose four numbers differ, so that a figure under the wrong column is caught.
    private let busy = PercentileSummary(
        count: 1_234_567, p50Ns: 1_500_000, p95Ns: 33_000_000, p99Ns: 123_450_000, clamped: 0
    )
    /// The dash that stands for a number nobody measured.
    private let dash = "\u{2014}"

    // MARK: The six rows

    @Test func theSixRowsAreInTheOrderOfTheMetricListWithTheirTitles() {
        let rows = LatencyTableRow.rows(from: [:])

        #expect(rows.map(\.metric) == LatencyMetric.allCases)
        #expect(
            rows.map(\.title) == [
                "Tick \u{2192} app", "Tick \u{2192} applied", "Tick \u{2192} screen", "Order \u{2192} ack",
                "Server processing", "Order \u{2192} fill",
            ]
        )
        #expect(rows.map(\.id) == LatencyMetric.allCases.map(\.rawValue))
        #expect(Set(rows.map(\.id)).count == 6)
    }

    @Test func theSpokenTitlesHaveNoArrowsAndNoAbbreviations() {
        let rows = LatencyTableRow.rows(from: [:])

        #expect(
            rows.map(\.spokenTitle) == [
                "Tick to app", "Tick to applied", "Tick to screen", "Order to acknowledgement", "Server processing",
                "Order to fill",
            ]
        )
    }

    @Test func eachRowCarriesTheSummaryOfItsOwnMetric() {
        var snapshot: [LatencyMetric: PercentileSummary] = [:]
        for (index, metric) in LatencyMetric.allCases.enumerated() {
            let step = Int64(index + 1)
            snapshot[metric] = PercentileSummary(
                count: index + 1, p50Ns: step * 1_000_000, p95Ns: step * 2_000_000, p99Ns: step * 3_000_000,
                clamped: index
            )
        }
        let rows = LatencyTableRow.rows(from: snapshot)

        #expect(rows.count == 6)
        for row in rows {
            #expect(row.summary == snapshot[row.metric], "\(row.metric)")
        }
    }

    @Test func aMetricThatIsNotInTheSnapshotIsAnEmptyRow() {
        let rows = LatencyTableRow.rows(from: [.tickToApp: busy])

        #expect(rows.count == 6)
        #expect(rows.first?.summary == busy)
        for row in rows.dropFirst() {
            #expect(row.summary == empty, "\(row.metric)")
        }
    }

    @Test func aRowWithValuesShowsThemUnderTheirOwnColumns() {
        let row = LatencyTableRow(metric: .tickToRender, summary: busy)

        #expect(row.countText == "1,234,567")
        #expect(row.p50Text == "1.50 ms")
        #expect(row.p95Text == "33.00 ms")
        #expect(row.p99Text == "123.45 ms")
        #expect(row.clampedText == nil)
    }

    @Test func anEmptyRowIsADashEverywhereAndHasNoClampedText() {
        let row = LatencyTableRow(metric: .orderSubmitToFill, summary: empty)

        #expect([row.countText, row.p50Text, row.p95Text, row.p99Text] == [dash, dash, dash, dash])
        #expect(row.clampedText == nil)
    }

    @Test func aRowWithClampedSamplesSaysSoAndNeverHidesIt() {
        let few = PercentileSummary(count: 998, p50Ns: 17_000_000, p95Ns: 33_000_000, p99Ns: 50_000_000, clamped: 7)
        let many = PercentileSummary(
            count: 998, p50Ns: 17_000_000, p95Ns: 33_000_000, p99Ns: 50_000_000, clamped: 12_345
        )

        #expect(LatencyTableRow(metric: .tickToRender, summary: few).clampedText == "clamped 7")
        #expect(LatencyTableRow(metric: .tickToRender, summary: many).clampedText == "clamped 12,345")
        // The control: the same numbers with nothing clamped have no such text.
        let none = PercentileSummary(count: 998, p50Ns: 17_000_000, p95Ns: 33_000_000, p99Ns: 50_000_000, clamped: 0)
        #expect(LatencyTableRow(metric: .tickToRender, summary: none).clampedText == nil)
    }

    @Test func aNegativePercentileIsADashAndNeverAMinusSign() {
        let odd = PercentileSummary(count: 3, p50Ns: -5, p95Ns: Int64.min, p99Ns: 1_500_000, clamped: 0)
        let row = LatencyTableRow(metric: .tickToApp, summary: odd)

        #expect(row.p50Text == dash)
        #expect(row.p95Text == dash)
        #expect(row.p99Text == "1.50 ms")
        #expect(!row.accessibilityText.contains("-"))
    }

    @Test func theSpokenRowNamesTheMetricAndSaysEachNumberInWords() {
        let row = LatencyTableRow(
            metric: .tickToRender,
            summary: PercentileSummary(count: 998, p50Ns: 17_000_000, p95Ns: 33_000_000, p99Ns: 50_000_000, clamped: 7)
        )

        #expect(
            row.accessibilityText == "Tick to screen: 998 samples, median 17.00 ms, 95th percentile 33.00 ms, "
                + "99th percentile 50.00 ms, 7 clamped"
        )
    }

    @Test func theSpokenRowSaysOneSampleInTheSingularAndLeavesOutAClampedCountOfZero() {
        let row = LatencyTableRow(
            metric: .orderSubmitToAck,
            summary: PercentileSummary(count: 1, p50Ns: 9_000_000, p95Ns: 9_000_000, p99Ns: 9_000_000, clamped: 0)
        )

        #expect(
            row.accessibilityText == "Order to acknowledgement: 1 sample, median 9.00 ms, 95th percentile 9.00 ms, "
                + "99th percentile 9.00 ms"
        )
    }

    @Test func theSpokenEmptyRowSaysThereAreNoSamples() {
        let row = LatencyTableRow(metric: .orderSubmitToFill, summary: empty)

        #expect(row.accessibilityText == "Order to fill: no samples")
    }

    // MARK: Counts

    @Test(arguments: countCases)
    func aCountIsWrittenInGroupsOfThreeDigits(count: Int, text: String) {
        #expect(CountText.grouped(count) == text)
    }

    // MARK: Connections

    @Test(arguments: connectionCases)
    func theConnectionTextsArePlainWords(state: ConnectionState, text: String) {
        #expect(ConnectionText.text(for: state) == text)
    }

    @Test func everyConnectionStateHasItsOwnText() {
        let texts = connectionCases.map { ConnectionText.text(for: $0.0) }

        #expect(texts.count == 5)
        #expect(Set(texts).count == 5)
    }

    @Test(arguments: restCases)
    func theRestRowSaysWhatTheProbeFound(status: RestStatus, text: String) {
        #expect(RestStatusText.text(for: status) == text)
    }

    // MARK: Account check

    @Test func theAccountCheckTextsSayWhatIsKnown() {
        #expect(AccountCheckText.text(for: .consistent) == "Consistent")
        #expect(
            AccountCheckText.text(for: .inFlight) == "In flight: events still arriving or an order is unanswered"
        )
        #expect(
            AccountCheckText.text(for: .drift("cash: app 1 satang, server 2 satang"))
                == "Drift: cash: app 1 satang, server 2 satang"
        )
    }

    // MARK: Choices

    @Test func theChoicesAlwaysContainTheCurrentServerValue() {
        #expect(LabChoices.choices([0, 50, 200], including: 50) == [0, 50, 200])
        #expect(LabChoices.choices([0, 50, 200], including: 75) == [0, 50, 75, 200])
        #expect(LabChoices.choices([0, 50, 200], including: 5_000) == [0, 50, 200, 5_000])
        #expect(LabChoices.choices([0, 20], including: 7) == [0, 7, 20])
        #expect(LabChoices.choices([0, 20], including: 1_999) == [0, 20, 1_999])
    }

    @Test func theChoicesAreSortedAndHaveNoDuplicate() {
        #expect(LabChoices.choices([0, 50, 200], including: 0) == [0, 50, 200])
        #expect(LabChoices.choices([200, 0, 50, 50], including: 200) == [0, 50, 200])
        #expect(LabChoices.choices([], including: 3) == [3])
    }

    // MARK: Rate

    @Test(arguments: rateCases)
    func theRateIsWrittenWithOneDecimalAndTheTimesSign(rate: Double, text: String) {
        #expect(RateText.text(for: rate) == text)
    }

    // MARK: Gaps

    /// The symbols and the snapshots the gaps are counted over: PTT has 2 gaps, AOT has 5 and CPALL has no snapshot.
    private func gapLookup(_ id: UInt32) -> SymbolSnapshot? {
        switch id {
        case 4: snapshot(symbol: 4, last: 3_425, gaps: 2)
        case 2: snapshot(symbol: 2, last: 5_800, gaps: 5)
        default: nil
        }
    }

    @Test func theGapsOfAllSymbolsAreAddedUp() {
        #expect(GapCount.total(of: sampleSymbols, snapshot: gapLookup) == 7)
        // The control: only the symbols given are looked at, and a symbol without a snapshot adds nothing.
        #expect(GapCount.total(of: [sampleSymbols[0]], snapshot: gapLookup) == 2)
        #expect(GapCount.total(of: [sampleSymbols[2]], snapshot: gapLookup) == 0)
        #expect(GapCount.total(of: [], snapshot: gapLookup) == 0)
    }

    @Test func theGapsAreLookedUpByTheIdOfEachSymbol() {
        var asked: [UInt32] = []
        let total = GapCount.total(of: sampleSymbols) { id in
            asked.append(id)
            return nil
        }

        #expect(total == 0)
        #expect(asked == [4, 2, 9])
    }

    @Test func aCountOfGapsTooBigToAddDoesNotTrap() {
        let huge = GapCount.total(of: sampleSymbols) { id in
            id == 9 ? nil : snapshot(symbol: id, last: 3_425, gaps: Int.max)
        }

        #expect(huge == Int.max)
    }

    @Test func theGapRowSaysWhichGapsItCounts() {
        #expect(GapCount.text(for: 0) == "Sequence gaps seen on this connection: 0")
        #expect(GapCount.text(for: 1_234) == "Sequence gaps seen on this connection: 1,234")
    }

    // MARK: Words

    @Test func theMessagesAreTheOnesTheScreenPromises() {
        #expect(LabMessages.settingsUnavailable == "Lab settings unavailable: is the server running?")
        #expect(LabMessages.couldNotReachTheServer == "Could not reach the server")
        let all = [
            LabMessages.settingsUnavailable, LabMessages.couldNotReachTheServer, LabMessages.couldNotChangeTheSetting,
            LabMessages.couldNotDropTheConnections, LabMessages.couldNotResetTheAccount,
        ]
        #expect(Set(all).count == 5)
        #expect(!all.contains { $0.isEmpty })
    }

    @Test func theResetDialogSaysTheServerDoesItForTheSimulatedAccountAndThatItCannotBeUndone() {
        let message = LabLabels.resetAccountMessage
        let lowered = message.lowercased()

        #expect(
            message == "The server resets the simulated account to its starting cash and forgets every order. "
                + "This cannot be undone."
        )
        #expect(lowered.contains("the server resets"), "it happens on the server")
        #expect(lowered.contains("simulated account"), "it is the simulated account")
        #expect(lowered.contains("cannot be undone"), "there is no way back")
        #expect(message.split(separator: ". ").count == 2, "two plain sentences")
        #expect(message.hasSuffix("."))
        for forbidden in ["stall", "freez", "froze", "heartbeat"] {
            #expect(!lowered.contains(forbidden), "\"\(message)\" says \(forbidden)")
        }
    }

    @Test func theDropUpdatesWordsTalkAboutGapsAndNeverAboutAStall() {
        #expect(LabLabels.dropUpdates == "Drop updates (creates gaps)")
        let words = [
            LabLabels.dropUpdates, LabLabels.dropUpdatesHint, GapCount.text(for: 3), LabLabels.gapsRowHint,
        ]

        #expect(LabLabels.dropUpdatesHint.lowercased().contains("gap"))
        #expect(words.allSatisfy { !$0.isEmpty })
        for word in words {
            let lowered = word.lowercased()
            for forbidden in ["stall", "freez", "froze", "heartbeat", "silent"] {
                #expect(!lowered.contains(forbidden), "\"\(word)\" says \(forbidden)")
            }
        }
    }
}

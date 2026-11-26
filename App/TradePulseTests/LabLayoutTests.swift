import SwiftUI
import Testing
import TradeCore
@testable import TradePulse

/// Whether the figures of the Lab stay whole at the largest text size and stay compact at the default one. A layout is
/// judged by the height it asks for: when narrowing the column makes a view taller, something in it was broken, and
/// when offering it less height makes it shorter, something in it was cut. Each judgement has a control: the same
/// figures in a first-draft layout are broken or cut, so the test can tell a good layout from a bad one.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LabLayoutTests {
    /// A metric with figures as large as the app will measure: hundreds of thousands of samples, a 99th percentile of
    /// three digits of milliseconds, and clamped samples by the thousand.
    private let large = PercentileSummary(
        count: 123_456, p50Ns: 17_000_000, p95Ns: 33_000_000, p99Ns: 123_450_000, clamped: 12_345
    )
    /// The same figures with nothing clamped.
    private let largeUnclamped = PercentileSummary(
        count: 123_456, p50Ns: 17_000_000, p95Ns: 33_000_000, p99Ns: 123_450_000, clamped: 0
    )

    /// The six rows of the table with `summary` in each of them.
    private func rows(_ summary: PercentileSummary) -> [LatencyTableRow] {
        LatencyMetric.allCases.map { LatencyTableRow(metric: $0, summary: summary) }
    }

    /// The table of six rows as the Lab lays it out in a scroll view: with the margin of the screen around it.
    private func table(_ summary: PercentileSummary, rows count: Int = 6) -> some View {
        LatencyHUD(rows: Array(rows(summary).prefix(count))).padding(.horizontal, LayoutRig.margin)
    }

    /// One row as a first draft would lay it out: everything on one line, whatever the width and the text size.
    private func naiveRow(_ row: LatencyTableRow) -> some View {
        HStack {
            Text(row.title).font(.footnote)
            Text(row.countText)
            Text(row.p50Text)
            Text(row.p95Text)
            Text(row.p99Text)
            if let clamped = row.clampedText {
                Text(clamped)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, LayoutRig.margin)
    }

    /// The height of one line of the text the table is set in.
    private func lineHeight(at size: DynamicTypeSize) -> CGFloat {
        LayoutRig.height(of: Text("Ag").font(.footnote), at: size, width: LayoutRig.contentWidth)
    }

    // MARK: The largest text size

    @Test func aRowWithLargeFiguresIsNotBrokenAtTheLargestTextSize() {
        let row = LatencyTableRow(metric: .tickToRender, summary: large)
        let naive = naiveRow(row)

        let wide = LayoutRig.height(of: table(large, rows: 1), at: .accessibility5, width: 500)
        let narrow = LayoutRig.height(of: table(large, rows: 1), at: .accessibility5, width: LayoutRig.screenWidth)
        let naiveWide = LayoutRig.height(of: naive, at: .accessibility5, width: 500)
        let naiveNarrow = LayoutRig.height(of: naive, at: .accessibility5, width: LayoutRig.screenWidth)
        let regular = LayoutRig.height(of: table(large, rows: 1), at: .large, width: LayoutRig.screenWidth)

        #expect(naiveNarrow > naiveWide + 1, "the control: the first draft is \(naiveWide) pt, then \(naiveNarrow) pt")
        #expect(regular > 20, "the control: the table has height at the regular size, \(regular) pt")
        #expect(wide > 3 * regular, "the largest size is another layout: \(regular) pt and \(wide) pt")
        #expect(narrow <= wide + 1, "in a wide column the row is \(wide) pt tall, in a narrow one \(narrow) pt")
    }

    @Test func theTableIsNeverCutAtTheLargestTextSizeWhateverHeightIsOffered() {
        let plain = Text("Server processing 123,456 123.45 ms").font(.footnote)
        let plainNeeds = LayoutRig.height(of: plain, at: .accessibility5, width: LayoutRig.contentWidth)
        let plainTook = LayoutRig.height(
            of: plain, at: .accessibility5, width: LayoutRig.contentWidth, offeredHeight: plainNeeds / 2
        )
        #expect(plainTook < plainNeeds, "the control: a plain text offered half its height is cut, \(plainTook) pt")

        let needed = LayoutRig.height(of: table(large), at: .accessibility5, width: LayoutRig.screenWidth)
        #expect(needed > 600, "the control: six rows are tall at the largest size, \(needed) pt")
        for share: CGFloat in [0.5, 1, 1.2, 1.5] {
            let took = LayoutRig.height(
                of: table(large), at: .accessibility5, width: LayoutRig.screenWidth, offeredHeight: needed * share
            )
            #expect(abs(took - needed) < 1, "the table needs \(needed) pt, took \(took) pt of \(needed * share)")
        }
    }

    @Test func theLargestTextSizeGivesEachMetricAGroupAndNotATableSqueezedIntoTheColumn() {
        let line = lineHeight(at: .accessibility5)
        let regularLine = lineHeight(at: .large)
        let regular = LayoutRig.height(of: table(largeUnclamped), at: .large, width: LayoutRig.screenWidth)

        // The control: a table is a heading and a line for each of the six metrics, about eight lines.
        #expect(regular < 10 * regularLine, "the control: the table is \(regular) pt, a line is \(regularLine) pt")
        // Squeezed into the column at the largest size, the same table would still be about eight lines of that size,
        // its names cut and its figures shrunk. A group for each metric has a line for its name and a line or two for
        // each of its figures, which is about four times as many.
        for summary in [largeUnclamped, large] {
            let largest = LayoutRig.height(of: table(summary), at: .accessibility5, width: LayoutRig.screenWidth)
            #expect(largest > 20 * line, "\(largest) pt is \(largest / line) lines of \(line) pt, and not twenty")
        }
    }

    // MARK: The default text size

    @Test func theTableIsOneLinePerMetricAtTheDefaultTextSize() {
        let one = LayoutRig.height(of: table(largeUnclamped, rows: 1), at: .large, width: LayoutRig.screenWidth)
        let six = LayoutRig.height(of: table(largeUnclamped), at: .large, width: LayoutRig.screenWidth)
        let sixWide = LayoutRig.height(of: table(largeUnclamped), at: .large, width: 1_000)
        let perRow = (six - one) / 5
        let line = lineHeight(at: .large)

        // The control: a first draft that sets a metric, its figures and its clamped count in one row does not fit.
        let naive = naiveRow(LatencyTableRow(metric: .orderServerProcessing, summary: large))
        let naiveNarrow = LayoutRig.height(of: naive, at: .large, width: LayoutRig.screenWidth)
        let naiveWide = LayoutRig.height(of: naive, at: .large, width: 1_000)

        #expect(naiveNarrow > naiveWide + 1, "the control: the first draft is \(naiveWide) pt, then \(naiveNarrow) pt")
        #expect(line > 10, "the control: a line of the table's text is \(line) pt")
        #expect(perRow > 0.8 * line, "the control: a row has a line's height at least, \(perRow) pt of \(line) pt")
        #expect(perRow < 1.8 * line, "a row is one line: \(perRow) pt where a line is \(line) pt")
        #expect(six <= sixWide + 1, "nothing is broken in a narrow column: \(sixWide) pt wide, \(six) pt narrow")
    }

    @Test func aRowWithClampedSamplesTakesOneMoreLineAndIsStillWhole() {
        let without = LayoutRig.height(of: table(largeUnclamped, rows: 1), at: .large, width: LayoutRig.screenWidth)
        let with = LayoutRig.height(of: table(large, rows: 1), at: .large, width: LayoutRig.screenWidth)
        let withWide = LayoutRig.height(of: table(large, rows: 1), at: .large, width: 1_000)
        let line = lineHeight(at: .large)

        #expect(with > without + 0.5 * line, "the clamped count is on the row: \(without) pt and then \(with) pt")
        #expect(with < without + 2 * line, "and it takes one more line, not two: \(without) pt and then \(with) pt")
        #expect(with <= withWide + 1, "nothing is broken in a narrow column: \(withWide) pt wide, \(with) pt narrow")
    }

    @Test func aLabelAndItsFigureShareALineWhileTheyFitAndStackWhenTheyDoNot() {
        let title = "Hitches"
        let value = "123 hitches (4.5%)"
        let row = LabValueRow(title: title, value: value).padding(.horizontal, LayoutRig.margin)
        // What the row is made of, each on a line of its own with the whole width.
        let label = Text(title).font(.subheadline).padding(.horizontal, LayoutRig.margin)
        let figure = Text(value).font(.subheadline.monospacedDigit()).padding(.horizontal, LayoutRig.margin)
        // A first draft: the label above the figure, whatever the text size.
        let naive = VStack(alignment: .leading) {
            Text(title)
            Text(value)
        }
        .font(.subheadline.monospacedDigit())
        .padding(.horizontal, LayoutRig.margin)

        let width = LayoutRig.screenWidth
        let labelAtRegular = LayoutRig.height(of: label, at: .large, width: width)
        let labelAtLargest = LayoutRig.height(of: label, at: .accessibility5, width: width)
        let figureAtLargest = LayoutRig.height(of: figure, at: .accessibility5, width: width)
        let atRegular = LayoutRig.height(of: row, at: .large, width: width)
        let atLargest = LayoutRig.height(of: row, at: .accessibility5, width: width)
        let naiveAtRegular = LayoutRig.height(of: naive, at: .large, width: width)

        #expect(labelAtRegular > 10, "the control: a line of the row's text is \(labelAtRegular) pt")
        #expect(labelAtLargest > labelAtRegular, "the control: the text is larger at the largest size")
        #expect(
            naiveAtRegular > 1.7 * labelAtRegular,
            "the control: a first draft that stacks them always takes two lines, \(naiveAtRegular) pt"
        )
        #expect(
            atRegular < 1.3 * labelAtRegular,
            "one line at the regular size: \(atRegular) pt of \(labelAtRegular) pt"
        )
        let parts = "the label is \(labelAtLargest) pt and the figure \(figureAtLargest) pt"
        #expect(
            atLargest > labelAtLargest + 0.8 * figureAtLargest,
            "stacked at the largest size: \(atLargest) pt, \(parts)"
        )
        #expect(
            atLargest <= labelAtLargest + figureAtLargest + 4,
            "the figure has the whole width: \(atLargest) pt, \(parts)"
        )
    }

    @Test func aLabelledValueIsNeverCutWhateverHeightIsOffered() {
        let values = [
            ("Frames per second", "59.8 fps"), ("Hitches", "1,234 hitches (1.2%)"),
            ("Chart draw", "p50 123.45 ms, p99 999.99 ms, clamped 12,345"), ("Rate multiplier", "10.0\u{00D7}"),
        ]
        #expect(values.count == 4)
        for (title, value) in values {
            let row = LabValueRow(title: title, value: value).padding(.horizontal, LayoutRig.margin)
            let needed = LayoutRig.height(of: row, at: .accessibility5, width: LayoutRig.screenWidth)
            #expect(needed > 100, "the control: \(title) is tall at the largest size, \(needed) pt")
            for share: CGFloat in [0.5, 1, 1.5] {
                let took = LayoutRig.height(
                    of: row, at: .accessibility5, width: LayoutRig.screenWidth, offeredHeight: needed * share
                )
                #expect(abs(took - needed) < 1, "\(title) needs \(needed) pt, took \(took) pt of \(needed * share)")
            }
        }
    }

    @Test func aLineOfWordsWithItsSymbolIsNeverCutWhateverHeightIsOffered() {
        let drift = "cash differs by 1,234,567 satang and a position of 12,345 shares differs as well"
        let sentences = [
            "Trading: Reconnecting, attempt 12", "REST: reachable, 123.45 ms", LabMessages.settingsUnavailable,
            AccountCheckText.text(for: .drift(drift)),
        ]
        #expect(sentences.count == 4)

        let plain = Text(sentences[0]).font(.subheadline).padding(.horizontal, LayoutRig.margin)
        let plainNeeds = LayoutRig.height(of: plain, at: .accessibility5, width: LayoutRig.screenWidth)
        let plainTook = LayoutRig.height(
            of: plain, at: .accessibility5, width: LayoutRig.screenWidth, offeredHeight: plainNeeds / 2
        )
        #expect(plainTook < plainNeeds, "the control: a plain text offered half its height is cut, \(plainTook) pt")

        let symbol = "exclamationmark.triangle"
        let oneLine = LayoutRig.height(
            of: StatusRow(text: "OK", symbol: symbol).padding(.horizontal, LayoutRig.margin),
            at: .accessibility5, width: LayoutRig.screenWidth
        )
        #expect(oneLine > 20, "the control: a line of the largest size has height, \(oneLine) pt")

        for sentence in sentences {
            let line = StatusRow(text: sentence, symbol: symbol).padding(.horizontal, LayoutRig.margin)
            let needed = LayoutRig.height(of: line, at: .accessibility5, width: LayoutRig.screenWidth)
            #expect(needed > 1.5 * oneLine, "the control: \(sentence) takes lines at the largest size, \(needed) pt")
            for share: CGFloat in [0.5, 1, 1.5] {
                let took = LayoutRig.height(
                    of: line, at: .accessibility5, width: LayoutRig.screenWidth, offeredHeight: needed * share
                )
                #expect(abs(took - needed) < 1, "\(sentence) needs \(needed) pt, took \(took) pt of \(needed * share)")
            }
        }
    }

    @Test func theControlsAreNeverCutWhateverHeightIsOffered() {
        let rig = LabRig()
        let controls = LabControlsSection(model: rig.model).padding(.horizontal, LayoutRig.margin)

        let atRegular = LayoutRig.height(of: controls, at: .large, width: LayoutRig.screenWidth)
        let needed = LayoutRig.height(of: controls, at: .accessibility5, width: LayoutRig.screenWidth)

        #expect(atRegular > 200, "the control: the controls have height at the regular size, \(atRegular) pt")
        #expect(needed > 2 * atRegular, "the largest size is another layout: \(atRegular) pt and \(needed) pt")
        for share: CGFloat in [0.5, 1, 1.5] {
            let took = LayoutRig.height(
                of: controls, at: .accessibility5, width: LayoutRig.screenWidth, offeredHeight: needed * share
            )
            #expect(abs(took - needed) < 1, "the controls need \(needed) pt, took \(took) pt of \(needed * share)")
        }
    }
}

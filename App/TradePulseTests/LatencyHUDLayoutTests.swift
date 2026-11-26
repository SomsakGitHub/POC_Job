import SwiftUI
import Testing
import TradeCore
@testable import TradePulse

/// The shape of the latency table: the table at the regular text size and below, on every phone the app runs on, and
/// the groups above it, whatever the figures are. A layout is judged by the height it asks for. The table is a heading
/// and a line for each of six metrics and the groups are six groups of five lines, so a height says which of the two
/// was laid out. The matrix is every width from the narrowest phone to the widest, the text sizes around the change of
/// shape, and figures from "no samples" to the widest the formatter writes. A shape that is chosen from how wide the
/// figures on show are changes from one set of figures to the next, and the control, a naive layout that chooses it so,
/// does. What a height cannot tell is read from a drawing of the table: the templates that size the columns must not
/// show, and a figure that is longer than its column must shrink and not be cut.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LatencyHUDLayoutTests {
    // MARK: What is measured

    /// One set of figures, in each of the six rows, and what it is called.
    private typealias Figures = (name: String, summary: PercentileSummary)

    /// The widths of the screens of the phones the app runs on, from the narrowest to the widest, in points.
    private static let widths: [CGFloat] = [375, 390, 393, 402, 420, 430, 440]
    /// The text sizes up to the regular one, at which the table is shown.
    private static let tableSizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large]
    /// The text sizes just above the regular one, at which the groups are shown. The accessibility sizes are measured
    /// with the rest of the Lab.
    private static let groupSizes: [DynamicTypeSize] = [.xLarge, .xxLarge, .xxxLarge]

    /// Nothing measured yet: a dash in every figure.
    private static let noSamples: Figures = (
        "no samples yet", PercentileSummary(count: 0, p50Ns: nil, p95Ns: nil, p99Ns: nil, clamped: 0)
    )
    /// Figures of a few thousand samples that took a few milliseconds.
    private static let typical: Figures = (
        "typical", PercentileSummary(count: 4_821, p50Ns: 3_210_000, p95Ns: 8_740_000, p99Ns: 16_500_000, clamped: 0)
    )
    /// Figures of a server that holds every answer back for 200 ms.
    private static let slow: Figures = (
        "200 ms of injected latency",
        PercentileSummary(count: 12_345, p50Ns: 201_500_000, p95Ns: 212_000_000, p99Ns: 245_300_000, clamped: 0)
    )
    /// A count of more digits than the column of a count is as wide as.
    private static let sevenDigits: Figures = (
        "a seven-digit count",
        PercentileSummary(count: 1_234_567, p50Ns: 3_210_000, p95Ns: 8_740_000, p99Ns: 16_500_000, clamped: 0)
    )
    /// The widest figures a metric shows under ten seconds, which is as long as a sample is kept.
    private static let widest: Figures = (
        "the widest figures under ten seconds",
        PercentileSummary(count: 1_234_567, p50Ns: 888_880_000, p95Ns: 999_990_000, p99Ns: 999_990_000, clamped: 0)
    )
    /// The widest figures, and as many clamped samples as there are samples.
    private static let widestClamped: Figures = (
        "the widest figures with clamped samples",
        PercentileSummary(
            count: 1_234_567, p50Ns: 888_880_000, p95Ns: 999_990_000, p99Ns: 999_990_000, clamped: 1_234_567
        )
    )
    /// The widest text the formatter can write, which no sample of the app comes near.
    private static let extreme: Figures = (
        "the widest text the formatter writes",
        PercentileSummary(count: 1_234_567, p50Ns: Int64.max, p95Ns: Int64.max, p99Ns: Int64.max, clamped: 0)
    )
    /// Every set of figures there is, from the narrowest to the widest.
    private static let everyFigures: [Figures] = [
        noSamples, typical, slow, sevenDigits, widest, widestClamped, extreme,
    ]

    /// The six rows of the table with `summary` in each of them.
    private func rows(_ figures: Figures) -> [LatencyTableRow] {
        LatencyMetric.allCases.map { LatencyTableRow(metric: $0, summary: figures.summary) }
    }

    /// The height `view` takes in a screen `width` points wide, with the margin the Lab leaves, at `size`.
    private func height(of view: some View, at size: DynamicTypeSize, width: CGFloat) -> CGFloat {
        LayoutRig.height(of: view.padding(.horizontal, LayoutRig.margin), at: size, width: width)
    }

    /// The height under which a layout in a screen `width` points wide is a table and over which it is the groups: the
    /// middle between the table at the regular size and the groups at the next size up, with the same figures.
    private func boundary(width: CGFloat) -> CGFloat {
        let hud = LatencyHUD(rows: rows(Self.typical))
        let table = height(of: hud, at: .large, width: width)
        let groups = height(of: hud, at: .xLarge, width: width)
        #expect(table < 0.5 * groups, "the control: the table is \(table) pt and the groups are \(groups) pt")
        return (table + groups) / 2
    }

    /// The width of `text` in one line of `font` at `size`.
    private func natural(_ text: String, _ font: Font, at size: DynamicTypeSize) -> CGFloat {
        LayoutRig.width(of: Text(text).font(font).fixedSize(), at: size)
    }

    // MARK: The rule

    @Test func theShapeIsTheTableUpToTheRegularTextSizeAndTheGroupsAboveIt() {
        let tables: [DynamicTypeSize] = [.xSmall, .small, .medium, .large]
        let groups: [DynamicTypeSize] = [
            .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility2, .accessibility3, .accessibility4,
            .accessibility5,
        ]

        #expect(tables.count + groups.count == DynamicTypeSize.allCases.count, "every text size has a shape")
        #expect(tables.allSatisfy { LatencyHUD.shape(at: $0) == .table })
        #expect(groups.allSatisfy { LatencyHUD.shape(at: $0) == .groups })
    }

    // MARK: Whatever the figures and the width

    @Test func theTableIsWhatIsLaidOutAtTheRegularTextSizeAndBelowOnEveryPhoneWhateverTheFigures() {
        var measured = 0
        for width in Self.widths {
            let boundary = boundary(width: width)
            for size in Self.tableSizes {
                for figures in Self.everyFigures {
                    let tall = height(of: LatencyHUD(rows: rows(figures)), at: size, width: width)
                    #expect(tall < boundary, "\(figures.name), \(size), \(width) pt: \(tall) pt, not under \(boundary)")
                    measured += 1
                }
            }
        }
        #expect(measured == Self.widths.count * Self.tableSizes.count * Self.everyFigures.count)
    }

    @Test func theGroupsAreWhatIsLaidOutAboveTheRegularTextSizeOnEveryPhoneWhateverTheFigures() {
        var measured = 0
        for width in Self.widths {
            let boundary = boundary(width: width)
            for size in Self.groupSizes {
                for figures in Self.everyFigures {
                    let tall = height(of: LatencyHUD(rows: rows(figures)), at: size, width: width)
                    #expect(tall > boundary, "\(figures.name), \(size), \(width) pt: \(tall) pt, not over \(boundary)")
                    measured += 1
                }
            }
        }
        #expect(measured == Self.widths.count * Self.groupSizes.count * Self.everyFigures.count)
    }

    @Test func aTableThatTakesItsShapeFromTheFiguresOnShowFlipsWhereTheRealOneDoesNot() {
        let width: CGFloat = 402
        let boundary = boundary(width: width)
        func shape(of view: some View, at size: DynamicTypeSize) -> LatencyHUD.Shape {
            height(of: view, at: size, width: width) < boundary ? .table : .groups
        }
        func naive(_ figures: Figures, at size: DynamicTypeSize) -> LatencyHUD.Shape {
            shape(of: NaiveTable(rows: rows(figures)), at: size)
        }
        func real(_ figures: Figures, at size: DynamicTypeSize) -> LatencyHUD.Shape {
            shape(of: LatencyHUD(rows: rows(figures)), at: size)
        }

        // At the regular size the naive layout holds the table until a figure is too wide for the width of the screen.
        #expect(naive(Self.typical, at: .large) == .table, "the control: typical figures fit beside the names")
        #expect(naive(Self.widest, at: .large) == .groups, "the control: the widest figures do not at \(width) pt")
        #expect(real(Self.typical, at: .large) == .table)
        #expect(real(Self.widest, at: .large) == .table)
        // One size up it holds the table until figures that are wide enough arrive.
        #expect(naive(Self.noSamples, at: .xLarge) == .table, "the control: dashes fit")
        #expect(naive(Self.slow, at: .xLarge) == .groups, "the control: the figures of a slow server do not")
        #expect(real(Self.noSamples, at: .xLarge) == .groups)
        #expect(real(Self.slow, at: .xLarge) == .groups)
        #expect(real(Self.typical, at: .xLarge) == .groups)
    }

    @Test func aTableShapedByItsFiguresFlipsAtTheWidthWhereTheyStopFittingBesideTheNamesAndTheRealTableNeverDoes() {
        // The widest figures fit beside the names on the phones from 420 pt and not on the narrower ones: where the
        // control changes its shape is where the real table must not.
        var naive: [CGFloat: LatencyHUD.Shape] = [:]
        var real: [CGFloat: LatencyHUD.Shape] = [:]
        let widestRows = rows(Self.widest)
        for width in Self.widths {
            let boundary = boundary(width: width)
            naive[width] = height(of: NaiveTable(rows: widestRows), at: .large, width: width) < boundary
                ? .table : .groups
            real[width] = height(of: LatencyHUD(rows: widestRows), at: .large, width: width) < boundary
                ? .table : .groups
        }

        #expect(Self.widths.filter { naive[$0] == .groups } == [375, 390, 393, 402], "\(naive)")
        #expect(Self.widths.filter { naive[$0] == .table } == [420, 430, 440], "the control: \(naive)")
        #expect(Self.widths.filter { real[$0] == .table } == Self.widths, "the real table at every width: \(real)")
    }

    // MARK: How it looks

    @Test func theTableOnThePhonesWideEnoughForTheNamesLooksAsItDidWithTypicalFigures() {
        let typicalRows = rows(Self.typical)
        for width: CGFloat in [393, 402, 420, 430, 440] {
            let before = height(of: NaiveTable(rows: typicalRows), at: .large, width: width)
            let now = height(of: LatencyHUD(rows: typicalRows), at: .large, width: width)
            #expect(abs(before - now) < 1, "\(width) pt: the naive layout was \(before) pt and the table is \(now) pt")
        }
    }

    @Test func theGroupsLookAsTheyDoInATableShapedByItsFiguresWhereThatTableShowsThem() {
        let slowRows = rows(Self.slow)
        let boundary = boundary(width: 402)
        for size in [DynamicTypeSize.xLarge, .xxLarge] {
            let before = height(of: NaiveTable(rows: slowRows), at: size, width: 402)
            let now = height(of: LatencyHUD(rows: slowRows), at: size, width: 402)
            #expect(before > boundary, "the control: the naive layout showed the groups at \(size), \(before) pt")
            #expect(abs(before - now) < 1, "\(size): the naive layout was \(before) pt and the groups are \(now) pt")
        }
    }

    @Test func theNarrowestPhoneCostsTheTableOnlyTheLinesOfNamesThatWrapWhateverTheFigures() {
        let line = LayoutRig.height(of: Text("Ag").font(.caption), at: .large, width: 400)
        let widestPhone = height(of: LatencyHUD(rows: rows(Self.noSamples)), at: .large, width: 440)
        let narrowestPhone = height(of: LatencyHUD(rows: rows(Self.noSamples)), at: .large, width: 375)
        #expect(line > 10, "the control: a line of the names is \(line) pt")
        #expect(
            narrowestPhone > widestPhone + 0.5 * line,
            "the longest name wraps on the narrowest phone: \(narrowestPhone) pt, \(widestPhone) pt at 440 pt"
        )

        for width in Self.widths {
            let noSamples = height(of: LatencyHUD(rows: rows(Self.noSamples)), at: .large, width: width)
            #expect(noSamples >= widestPhone - 0.5, "\(width) pt: \(noSamples) pt and \(widestPhone) pt at 440 pt")
            #expect(noSamples < widestPhone + 2.5 * line, "\(width) pt: the names wrap, \(noSamples) pt")
            // A figure is laid over its template, so whatever it says its row is as tall as the row of dashes is.
            for figures in [Self.typical, Self.slow, Self.sevenDigits, Self.widest, Self.extreme] {
                let figuresHeight = height(of: LatencyHUD(rows: rows(figures)), at: .large, width: width)
                #expect(
                    abs(figuresHeight - noSamples) < 1,
                    "\(figures.name) at \(width) pt: \(figuresHeight) pt, and \(noSamples) pt with dashes"
                )
            }
        }
    }

    // MARK: Whole figures and whole names

    @Test func everyFigureTheFormatterWritesFitsItsColumnAtTheSmallestScaleTheTextAllows() {
        var checked = 0
        for size in Self.tableSizes {
            let figureFont = Font.caption.monospacedDigit()
            let count = natural(LatencyHUD.countTemplate, figureFont, at: size)
            let latency = natural(LatencyHUD.percentileTemplate, figureFont, at: size)
            for figures in Self.everyFigures {
                for row in rows(figures) {
                    let columns = [
                        (row.countText, count), (row.p50Text, latency), (row.p95Text, latency),
                        (row.p99Text, latency),
                    ]
                    for (text, column) in columns {
                        let scale = min(1, column / natural(text, figureFont, at: size))
                        #expect(scale >= 0.5, "\(text) at \(size) needs \(scale) of its size to fit \(column) pt")
                        checked += 1
                    }
                }
            }
            // The control: the widest text in the column of a count would be cut.
            let tooWide = natural(LatencyFormat.string(ns: Int64.max), figureFont, at: size)
            #expect(count / tooWide < 0.5, "the control: the widest latency does not fit a count's column at \(size)")
        }
        #expect(checked == Self.tableSizes.count * Self.everyFigures.count * 6 * 4)
    }

    @Test func theColumnsAreAsWideAsTheWidestFigureThatMeansSomethingAndNoHeadingIsWider() {
        let figureFont = Font.caption.monospacedDigit()
        let headingFont = Font.caption2.weight(.semibold)
        let latencies: [Int64] = [
            0, 1, 950, 999_990, 1_234_567, 888_880_000, 999_990_000, 999_995_000, 5_000_000_000, 10_000_000_000,
        ]
        for size in Self.tableSizes {
            let count = natural(LatencyHUD.countTemplate, figureFont, at: size)
            let latency = natural(LatencyHUD.percentileTemplate, figureFont, at: size)
            for nanos in latencies {
                let text = LatencyFormat.string(ns: nanos)
                #expect(natural(text, figureFont, at: size) <= latency + 0.01, "\(text) at \(size)")
            }
            #expect(natural(CountText.grouped(888_888), figureFont, at: size) <= count + 0.01, "a count at \(size)")
            for heading in ["Count", "p50", "p95", "p99"] {
                let column = heading == "Count" ? count : latency
                #expect(natural(heading, headingFont, at: size) <= column, "the heading \(heading) at \(size)")
            }
        }
    }

    @Test func everyNameFitsItsColumnWholeOnTheNarrowestPhoneWhereTheLongerOnesWrap() {
        let figureFont = Font.caption.monospacedDigit()
        let nameFont = Font.caption
        let clampedFont = Font.caption2.monospacedDigit()
        let titles = LatencyMetric.allCases.map { LatencyTableRow(metric: $0, summary: Self.typical.summary).title }
        let words = titles.flatMap { $0.split(separator: " ").map(String.init) }
        let clamped = rows(Self.widestClamped).compactMap(\.clampedText)
        #expect(words.count > titles.count, "the control: some names are of more than one word")
        #expect(!clamped.isEmpty)

        let narrowest = Self.widths[0]
        for size in Self.tableSizes {
            let count = natural(LatencyHUD.countTemplate, figureFont, at: size)
            let latency = natural(LatencyHUD.percentileTemplate, figureFont, at: size)
            let columns = count + 3 * latency + 4 * LatencyHUD.columnSpacing
            let name = narrowest - 2 * LayoutRig.margin - columns
            let longestWord = words.map { natural($0, nameFont, at: size) }.max() ?? 0
            let widestTitle = titles.map { natural($0, nameFont, at: size) }.max() ?? 0
            let widestClamped = clamped.map { natural($0, clampedFont, at: size) }.max() ?? 0

            #expect(longestWord <= name, "at \(size) the name column is \(name) pt, a word is \(longestWord) pt")
            #expect(widestClamped * 0.5 <= name, "at \(size) a clamped count needs more than half of \(name) pt")
            if size == .large {
                #expect(widestTitle > name, "the control: at the regular size the longest name wraps on 375 pt")
            }
            // The control: the widest latency in every column would leave the names no room for their longest word.
            let tooWide = natural(LatencyFormat.string(ns: Int64.max), figureFont, at: size)
            let withTooWide = narrowest - 2 * LayoutRig.margin - 4 * tooWide - 4 * LatencyHUD.columnSpacing
            #expect(withTooWide < longestWord, "the control: \(withTooWide) pt would be left for the names")
        }
    }

    // MARK: How the figures are drawn

    /// How tall the lines of ink are, in points, that the six rows leave in the last column of `view`, from the top
    /// down. `view` is drawn on the screen of the Lab at the regular size, and the column is as wide as the template of
    /// a latency. A row of digits leaves a line as tall as a digit and a row of dashes a much shorter one.
    private func linesOfInkInTheLastColumn(of view: some View) throws -> [CGFloat] {
        let screen = view.padding(.horizontal, LayoutRig.margin).frame(maxWidth: .infinity, alignment: .leading)
        let drawing = try #require(
            LayoutRig.draw(screen, size: CGSize(width: LayoutRig.screenWidth, height: 230), safeAreaTop: 0),
            "there is a window to draw in"
        )
        let right = try #require(drawing.picture.rightEdgeOfInk(), "something was drawn")
        let column = natural(LatencyHUD.percentileTemplate, .caption.monospacedDigit(), at: .large)
        // The heading of the table, when there is one, is over the six rows.
        return Array(drawing.picture.linesOfInk(from: right - column, to: right).suffix(6))
    }

    @Test func theTemplatesThatSizeTheColumnsAreNeverDrawn() throws {
        let digits = try linesOfInkInTheLastColumn(of: LatencyHUD(rows: rows(Self.typical)))
        let dashes = try linesOfInkInTheLastColumn(of: LatencyHUD(rows: rows(Self.noSamples)))

        let digit = try #require(digits.min())
        #expect(digits.count == 6, "the control: a line of ink for each row of figures, \(digits)")
        #expect(digit > 6, "the control: a digit is \(digit) pt tall")
        #expect(dashes.count == 6, "a line of ink for each row of dashes: \(dashes)")
        #expect(dashes.allSatisfy { $0 < 0.5 * digit }, "a dash is not as tall as a digit, \(digit) pt: \(dashes)")
    }

    @Test func aFigureLongerThanItsColumnShrinksInsideItAndIsNeitherCutNorBroken() throws {
        let fits = try linesOfInkInTheLastColumn(of: LatencyHUD(rows: rows(Self.typical)))
        let shrunk = try linesOfInkInTheLastColumn(of: LatencyHUD(rows: rows(Self.extreme)))
        let cut = try linesOfInkInTheLastColumn(of: UnlimitedFigures(rows: rows(Self.extreme)))

        let digit = try #require(fits.min())
        #expect(fits.count == 6 && digit > 6, "the control: a figure that fits is \(fits) pt tall")
        #expect(shrunk.count == 6, "a line of ink for each row: \(shrunk)")
        #expect(shrunk.allSatisfy { $0 < 0.75 * digit }, "the digits shrink to fit, from \(digit) pt: \(shrunk)")
        #expect(cut.count == 6, "the control: a line of ink for each row, \(cut)")
        #expect(cut.allSatisfy { $0 > 0.9 * digit }, "the control: with no limit the figure is cut, at \(cut) pt")
    }

    // MARK: Controls, which do what the table must not

    /// The table in a naive layout: `ViewThatFits` takes the table when the figures that are on show fit
    /// beside the names in the width the column has, and the groups when they do not.
    private struct NaiveTable: View {
        /// The six rows.
        let rows: [LatencyTableRow]

        var body: some View {
            ViewThatFits(in: .horizontal) {
                table
                groups
            }
            .fixedSize(horizontal: false, vertical: true)
        }

        private var table: some View {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow(alignment: .firstTextBaseline) {
                    heading("Metric").gridColumnAlignment(.leading)
                    heading("Count").gridColumnAlignment(.trailing)
                    heading("p50").gridColumnAlignment(.trailing)
                    heading("p95").gridColumnAlignment(.trailing)
                    heading("p99").gridColumnAlignment(.trailing)
                }
                Divider()
                ForEach(rows) { row in
                    GridRow(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.title).font(.caption).lineLimit(1)
                            if let clamped = row.clampedText {
                                Text(clamped).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        figure(row.countText)
                        figure(row.p50Text)
                        figure(row.p95Text)
                        figure(row.p99Text)
                    }
                }
            }
        }

        private func heading(_ text: String) -> some View {
            Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
        }

        private func figure(_ text: String) -> some View {
            Text(text).font(.caption.monospacedDigit()).amountOnOneLine()
        }

        private var groups: some View {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).font(.subheadline.weight(.semibold))
                        if let clamped = row.clampedText {
                            Text(clamped).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        LabValueRow(title: "Count", value: row.countText)
                        LabValueRow(title: "p50", value: row.p50Text)
                        LabValueRow(title: "p95", value: row.p95Text)
                        LabValueRow(title: "p99", value: row.p99Text)
                    }
                    Divider()
                }
            }
        }
    }

    /// The figures of the table laid over the templates of their columns as the table lays them, but without the limit
    /// of one line that makes a longer figure shrink: a figure that is too long is cut instead.
    private struct UnlimitedFigures: View {
        /// The six rows.
        let rows: [LatencyTableRow]

        var body: some View {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(rows) { row in
                    HStack(spacing: LatencyHUD.columnSpacing) {
                        figure(row.countText, template: LatencyHUD.countTemplate)
                        figure(row.p50Text, template: LatencyHUD.percentileTemplate)
                        figure(row.p95Text, template: LatencyHUD.percentileTemplate)
                        figure(row.p99Text, template: LatencyHUD.percentileTemplate)
                    }
                }
            }
        }

        private func figure(_ text: String, template: String) -> some View {
            Text(template)
                .font(.caption.monospacedDigit())
                .fixedSize()
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(text).font(.caption.monospacedDigit())
                }
        }
    }
}

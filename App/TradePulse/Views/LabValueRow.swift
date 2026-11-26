import SwiftUI

/// A label and its value, as the Lab lays them out: on one line, the label at the leading edge and the value at the
/// trailing edge, while both fit, and the value under the label when they do not. A value is never cut. It wraps
/// between words when it is a sentence, and a number in it is never broken in the middle.
///
/// VoiceOver reads the row as the label and its value. The row takes the text it is given and nothing else, so it reads
/// nothing that changes while the screen is open.
struct LabValueRow: View {
    /// What the value is the value of.
    let title: String
    /// The value, as the words and figures to show.
    let value: String

    /// The label and the value, in a row or one above the other.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                label
                Spacer(minLength: 8)
                figure(alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                label
                figure(alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    /// The label.
    private var label: some View {
        Text(title)
            .font(.subheadline)
    }

    /// The value, set in digits of one width so that it does not shift as the numbers change.
    private func figure(alignment: TextAlignment) -> some View {
        Text(value)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(alignment)
    }
}

/// A line of words with a symbol in front of it, for a state the Lab says in words: a connection, the answer of the
/// account check or a message under the controls. The symbol goes with the words and is never the only thing that says
/// what the state is. The words wrap as far as they need and are never cut.
struct StatusRow: View {
    /// What the line says.
    let text: String
    /// The name of the SF Symbol that goes with it.
    let symbol: String

    /// The symbol and the words.
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A titled group of rows: the title, as a heading, over what belongs under it. The group takes the height its rows
/// need, whatever height it is offered, so that none of them is cut.
struct LabSection<Content: View>: View {
    /// The heading.
    let title: String
    /// The rows.
    private let content: Content

    /// A section called `title` that holds what `content` builds.
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    /// The heading over the rows.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

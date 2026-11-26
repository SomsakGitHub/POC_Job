import SwiftUI

/// One order as the Orders tab and the ticket draw it: what it is, how far it got, its status, the reason when there is
/// one, and the two things the user can do with it. It is made from an `OrderRowPresentation`, so it decides nothing.
///
/// VoiceOver reads the order as one element with the spoken summary. Each button is an element of its own and its label
/// names the order, so that a list of orders does not have a dozen buttons that all say "Cancel".
struct OrderRowView: View {
    /// What the row says.
    let presentation: OrderRowPresentation
    /// Whether a cancel for this order is out. The button is off until the call returns, so a second tap cannot send
    /// a second cancel.
    let isCancelling: Bool
    /// Asks the exchange to cancel the order. Called from the Cancel button.
    let cancel: () async -> Void
    /// Sends the order again with the same order id. Called from the retry button.
    let retry: () async -> Void

    /// The order over its status, and the buttons under them when the order has any. The row is as tall as its words
    /// need, whatever height the list offers it, so that no line of it is cut short.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.accessibilityText)
            if presentation.canCancel || presentation.canRetry {
                HStack(spacing: 12) {
                    if presentation.canCancel {
                        Button(role: .destructive) {
                            Task { await cancel() }
                        } label: {
                            Text("Cancel")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isCancelling)
                        .accessibilityLabel("Cancel order \(spokenTitle)")
                    }
                    if presentation.canRetry {
                        Button {
                            Task { await retry() }
                        } label: {
                            Text("Unconfirmed \u{2014} Retry")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Retry order \(spokenTitle) with the same order id")
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }

    /// The title, the status chip, the shares and the average price, and the reason under them.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(presentation.title)
                        .font(.headline)
                    Spacer(minLength: 8)
                    StatusChip(kind: presentation.statusKind, text: presentation.statusText)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.title)
                        .font(.headline)
                    StatusChip(kind: presentation.statusKind, text: presentation.statusText)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    quantity
                    average
                }
                VStack(alignment: .leading, spacing: 2) {
                    quantity
                    average
                }
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            if let reason = presentation.reasonText {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The shares filled and the shares asked for, on one line.
    private var quantity: some View {
        Text(presentation.quantityText)
            .amountOnOneLine()
    }

    /// The average price of the fills, on one line.
    private var average: some View {
        Text(presentation.averageText)
            .amountOnOneLine()
    }

    /// The title as it is said: the dot between the side and the type is a pause.
    private var spokenTitle: String {
        presentation.title.replacingOccurrences(of: " \u{00B7} ", with: ", ")
    }
}

/// A status as a small capsule: an image and the word. The colour only adds to them.
struct StatusChip: View {
    /// How the status is drawn.
    let kind: OrderRowPresentation.StatusKind
    /// The status in a word.
    let text: String

    /// The image and the word, tinted.
    var body: some View {
        Label(text, systemImage: kind.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
    }

    /// The colour of the kind.
    private var tint: Color {
        switch kind {
        case .working: .blue
        case .done: .green
        case .neutral: .secondary
        case .warning: .orange
        case .failed: .red
        }
    }
}

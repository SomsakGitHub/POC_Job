import Contracts
import SwiftUI

/// The controls of the Lab: what the server does to the market feed, and the buttons that act on the server and on what
/// the Lab measures.
///
/// Nothing here can be used until the server has told its settings. A read that failed says so, and can be asked again.
/// A control asks the server for a change and then shows what the server answered with, which is what is in force: the
/// server holds a value inside its range, so the control does not show the value that was asked for until it is told.
///
/// The body reads whether the settings are known, the settings and the line under the controls, and nothing that moves
/// with the prices or the frames: a body that is evaluated again at that pace drops the touch a control is tracking.
/// The slider and the pickers are views of their own, so that a drag evaluates them and not this body.
struct LabControlsSection: View {
    /// The injected delays the control offers, in milliseconds, besides the one the server holds.
    private static let latencies = [0, 50, 200]
    /// The jitters the control offers, in milliseconds, besides the one the server holds.
    private static let jitters = [0, 20]

    /// The model that holds the settings and does what the controls ask.
    let model: LabViewModel

    /// The controls, with what is wrong above them when the settings could not be read and the line of the last failed
    /// request under them.
    var body: some View {
        let loaded = model.settingsLoaded
        let settings = model.settings
        let failure = model.lastError
        LabSection("Controls") {
            VStack(alignment: .leading, spacing: 16) {
                if !loaded, failure != nil {
                    unavailable
                }
                RateControl(current: settings.rateMultiplier, model: model)
                    .disabled(!loaded)
                Toggle("Stress", isOn: flag(settings.stress) { LabPatch(stress: $0) })
                    .disabled(!loaded)
                LabChoicePicker(title: "Injected latency", base: Self.latencies, current: settings.extraLatencyMs) {
                    model.ask(LabPatch(extraLatencyMs: $0))
                }
                .disabled(!loaded)
                LabChoicePicker(title: "Jitter", base: Self.jitters, current: settings.jitterMs) {
                    model.ask(LabPatch(jitterMs: $0))
                }
                .disabled(!loaded)
                Toggle(LabLabels.dropUpdates, isOn: flag(settings.dropUpdates) { LabPatch(dropUpdates: $0) })
                    .accessibilityHint(LabLabels.dropUpdatesHint)
                    .disabled(!loaded)
                buttons
                    .disabled(!loaded)
                if let failure {
                    StatusRow(text: failure, symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    // MARK: Parts

    /// What the controls say while the settings could not be read, and the button that reads them again.
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusRow(text: LabMessages.settingsUnavailable, symbol: "exclamationmark.triangle")
            Button("Try again") {
                Task { await model.load() }
            }
            .buttonStyle(.bordered)
        }
    }

    /// The three buttons, one above the other and as wide as the column, so that a name is never cut at a large text
    /// size.
    private var buttons: some View {
        VStack(spacing: 8) {
            wideButton("Drop connections") {
                Task { await model.dropConnections() }
            }
            ResetAccountButton(model: model)
            wideButton("Reset stats") {
                model.resetStats()
            }
        }
    }

    /// A switch that shows `current` and, when it is flipped, asks the server for the patch that `patch` makes of the
    /// new position. It does not move until the server has answered.
    private func flag(_ current: Bool, patch: @escaping @Sendable (Bool) -> LabPatch) -> Binding<Bool> {
        let model = model
        return Binding(get: { current }, set: { model.ask(patch($0)) })
    }
}

/// A bordered button as wide as the column that says `title` and does `action`.
@MainActor
private func wideButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
    Button(role: role, action: action) {
        Text(title)
            .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
}

/// The button that resets the account. It asks first, because resetting forgets the orders of the demo. The dialog is
/// this view's own state, so that it opening evaluates this view and not the controls around it.
struct ResetAccountButton: View {
    /// The model that asks the server.
    let model: LabViewModel
    /// Whether the dialog is on screen.
    @State private var confirming = false

    /// The button, with the dialog it opens.
    var body: some View {
        wideButton("Reset account", role: .destructive) {
            confirming = true
        }
        .confirmationDialog("Reset the account?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Reset account", role: .destructive) {
                Task { await model.resetAccount() }
            }
        } message: {
            Text(LabLabels.resetAccountMessage)
        }
    }
}

/// The rate multiplier: its figure above a slider that goes from 0.5 to 5 in steps of 0.5.
///
/// The server hears of a drag once, when the finger lifts, and not for every step the slider passes. The slider shows
/// where the finger is while it is down, and the rate the model holds otherwise: when the server brings something the
/// controls look at again (a request that ends, or a round that finds other settings), it goes to that rate, so a
/// change the server did not take is not left on show. An answer that comes under the finger waits for the lift. Its
/// state is its own, so a drag evaluates this view and nothing around it.
struct RateControl: View {
    /// The model the change is asked of.
    let model: LabViewModel
    /// What the slider shows and when it asks.
    @State private var state: RateSliderState

    /// A slider that starts at `current`, the rate the server holds.
    init(current: Double, model: LabViewModel) {
        self.model = model
        _state = State(initialValue: RateSliderState(rate: current))
    }

    /// The figure and the slider under it.
    var body: some View {
        let shown = RateText.text(for: state.shown)
        VStack(alignment: .leading, spacing: 4) {
            LabValueRow(title: "Rate multiplier", value: shown)
                .accessibilityHidden(true)
            Slider(
                value: position, in: 0.5...5, step: 0.5,
                onEditingChanged: { begins in
                    if let rate = state.editing(begins) {
                        model.ask(LabPatch(rateMultiplier: rate))
                    }
                }
            )
            .accessibilityLabel("Rate multiplier")
            .accessibilityValue(shown)
        }
        .onChange(of: model.settingsRevision) { state.follow(model.settings.rateMultiplier) }
    }

    /// Where the slider is. A move that no finger is behind, such as a step of VoiceOver's adjust action, is asked of
    /// the server at once; the steps of a drag wait for the finger to lift.
    private var position: Binding<Double> {
        let state = $state
        let model = model
        return Binding(
            get: { state.wrappedValue.shown },
            set: { rate in
                if let asked = state.wrappedValue.slide(to: rate) {
                    model.ask(LabPatch(rateMultiplier: asked))
                }
            }
        )
    }
}

/// A setting of a few values in milliseconds: a segmented control, and a menu at the accessibility text sizes, where
/// the segments of a segmented control would not fit their words.
///
/// The choices are the ones the control is given and the value the server holds, so a value that was set from outside
/// still shows.
struct LabChoicePicker: View {
    /// What the setting is called.
    let title: String
    /// The values the control offers.
    let base: [Int]
    /// The value the server holds.
    let current: Int
    /// What is done with the value that was picked.
    let pick: @MainActor (Int) -> Void
    /// The text size, which decides between the segments and the menu.
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The name over the control.
    var body: some View {
        let selection = Binding(get: { current }, set: { [pick] value in pick(value) })
        let choices = LabChoices.choices(base, including: current)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .accessibilityHidden(true)
            if typeSize.isAccessibilitySize {
                Picker(title, selection: selection) { options(choices) }
                    .pickerStyle(.menu)
                    .labelsHidden()
            } else {
                Picker(title, selection: selection) { options(choices) }
                    .pickerStyle(.segmented)
                    .labelsHidden()
            }
        }
    }

    /// One option for each of `choices`, in milliseconds.
    private func options(_ choices: [Int]) -> some View {
        ForEach(choices, id: \.self) { value in
            Text("\(CountText.grouped(value)) ms").tag(value)
        }
    }
}

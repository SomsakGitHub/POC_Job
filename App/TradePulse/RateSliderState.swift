/// What the rate slider shows and when it asks the server for a change.
///
/// A drag moves the slider many times a second, and the server must hear of it once, when the finger lifts: one request
/// per gesture. A change that no drag is behind, such as a step of VoiceOver's adjust action, is a request of its own.
/// The slider shows what the finger says while a drag is going on, and what the server last answered otherwise.
struct RateSliderState: Equatable {
    /// The rate the slider shows.
    private(set) var shown: Double
    /// Whether a finger is on the slider.
    private(set) var isDragging = false
    /// The rate the slider showed when the finger went down.
    private var shownAtTouchDown: Double

    /// A slider that shows `rate` and has no finger on it.
    init(rate: Double) {
        shown = rate
        shownAtTouchDown = rate
    }

    /// The slider moved to `rate`. It answers the rate to ask the server for, or nil while a drag is going on, when the
    /// request waits for the finger to lift.
    mutating func slide(to rate: Double) -> Double? {
        shown = rate
        return isDragging ? nil : rate
    }

    /// The finger went down (`begins`) or lifted. It answers the rate to ask the server for when a finger lifts from a
    /// slider that it moved, and nil in every other case: a touch that moved nothing, a drag that came back to where it
    /// began, and a lift with no finger down.
    mutating func editing(_ begins: Bool) -> Double? {
        if begins {
            isDragging = true
            shownAtTouchDown = shown
            return nil
        }
        guard isDragging else { return nil }
        isDragging = false
        return shown == shownAtTouchDown ? nil : shown
    }

    /// The server answered with `rate`, the rate in force. The slider follows it unless a finger is on it, which the
    /// answer must not pull away from the finger.
    mutating func follow(_ rate: Double) {
        guard !isDragging else { return }
        shown = rate
    }
}

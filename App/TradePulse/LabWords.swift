/// The lines the Lab shows under its controls when a request does not work, in plain words that say what did not
/// happen and not why the network failed.
enum LabMessages {
    /// What the controls say while the server's settings could not be read, so that they cannot be used.
    static let settingsUnavailable = "Lab settings unavailable: is the server running?"
    /// The line under the controls after the settings could not be read.
    static let couldNotReachTheServer = "Could not reach the server"
    /// The line under the controls after a change of a setting did not work.
    static let couldNotChangeTheSetting = "Could not change the setting"
    /// The line under the controls after the request to drop the connections did not work.
    static let couldNotDropTheConnections = "Could not drop the connections"
    /// The line under the controls after the request to reset the account did not work.
    static let couldNotResetTheAccount = "Could not reset the account"
}

/// Labels and hints of the Lab that more than one place needs, or that a test reads.
enum LabLabels {
    /// What stands for a number nobody measured.
    static let noData = "\u{2014}"
    /// The switch that makes the server withhold market updates.
    static let dropUpdates = "Drop updates (creates gaps)"
    /// What that switch does, for VoiceOver: the server skips every second update, and the app finds the holes in the
    /// sequence numbers and asks for the state again.
    static let dropUpdatesHint =
        "The server skips every second market update, so the app sees gaps in the sequence numbers and fetches the "
        + "state again."
    /// What the count of gaps is, for VoiceOver.
    static let gapsRowHint =
        "Counts the gaps in the sequence numbers of the market feed. The switch that drops updates makes them."
}

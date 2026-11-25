import TradeNetworking

/// Whether a screen that shows market data should ask for it again after the market connection went from `old` to
/// `new`: when the connection has come up, and only then.
///
/// What happened while the connection was down is missing from the history a screen loaded before, so a screen that
/// holds history asks for it again as soon as the connection returns. A connection that stays up or goes down has
/// nothing new to load. The screens that show data from this connection use this one rule so that they agree on when.
func shouldReloadOnConnection(from old: ConnectionState, to new: ConnectionState) -> Bool {
    new == .connected && old != .connected
}

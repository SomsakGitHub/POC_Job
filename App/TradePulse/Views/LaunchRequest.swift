import Contracts

extension MarketListView {
    /// The launch argument that asks for a symbol's detail screen, `--open-symbol <TICKER>` (used by the measurement
    /// script and by screenshots): the value after the first `--open-symbol`, as it was written.
    ///
    /// The flag with nothing after it, or with an empty value, is no request. A second flag is not looked at: the
    /// first one wins. Which symbol the ticker names, and in which case it was written, is for `LaunchRequest`.
    nonisolated static func openSymbolRequest(in arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "--open-symbol") else { return nil }
        let value = arguments.index(after: flag)
        guard value < arguments.endIndex, !arguments[value].isEmpty else { return nil }
        return arguments[value]
    }
}

/// The request of the launch arguments to open one symbol's detail screen, which the Market list carries out once.
///
/// It waits for the symbols to load, because the ticker can only be matched against a list. The first time it sees a
/// list it is spent, whether or not the ticker was in it: a screen that the user closed must not open again by
/// itself, and a ticker that does not exist must not keep the request alive.
struct LaunchRequest {
    /// The ticker asked for; nil when nothing was asked for or the request has been spent.
    private var ticker: String?

    /// The request that `arguments` make, if any.
    init(arguments: [String]) {
        ticker = MarketListView.openSymbolRequest(in: arguments)
    }

    /// The id of the symbol to open now: that of the symbol in `symbols` whose ticker is the one asked for, whatever
    /// the case of either. It is nil while `symbols` is empty (the request waits), for a ticker that is not in the
    /// list, and for every call after the first one that saw a list.
    mutating func take(from symbols: [SymbolDTO]) -> UInt32? {
        guard let wanted = ticker, !symbols.isEmpty else { return nil }
        ticker = nil
        return symbols.first { $0.ticker.lowercased() == wanted.lowercased() }?.id
    }
}

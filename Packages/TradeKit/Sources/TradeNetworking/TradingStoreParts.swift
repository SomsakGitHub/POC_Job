import Contracts
import Synchronization
import TradeCore

/// How the app's trading state compares with the server's account.
public enum Reconciliation: Sendable, Equatable {
    /// Same epoch, same event sequence, same cash and positions.
    case consistent
    /// The two could not be compared at one moment: the epochs or the event sequences differ (events are still on
    /// their way), or the account could not be read. Nothing is claimed about drift.
    case inFlight
    /// Same epoch and sequence, but cash or positions differ; the text names the values that differ.
    case drift(String)

    /// The verdict for `state` against `account`. A state with no epoch yet is compared by sequence only.
    static func compare(_ state: TradingState, with account: AccountDTO) -> Reconciliation {
        if let epoch = state.epoch, epoch != account.epoch { return .inFlight }
        guard state.lastEventSeq == account.lastEventSeq else { return .inFlight }
        var held: [UInt32: Quantity] = [:]
        for position in account.positions where position.quantity > 0 {
            held[position.symbolId] = position.quantity
        }
        var differences: [String] = []
        if state.cash != account.cash {
            differences.append("cash: app \(state.cash) satang, server \(account.cash) satang")
        }
        let symbols = Set(state.positions.keys).union(held.keys).sorted()
        for symbol in symbols {
            let mine = state.positions[symbol] ?? 0
            let theirs = held[symbol] ?? 0
            if mine != theirs {
                differences.append("symbol \(symbol): app \(mine) shares, server \(theirs) shares")
            }
        }
        return differences.isEmpty ? .consistent : .drift(differences.joined(separator: "; "))
    }
}

/// The resume point of the event stream, `(lastEventSeq, epoch)` of the store's state, readable from any thread: the
/// client reads it synchronously at the start of every connection, outside the main actor.
final class ResumePoint: Sendable {
    private let value = Mutex<(seq: UInt64, epoch: String?)>((0, nil))

    var current: (seq: UInt64, epoch: String?) {
        value.withLock { $0 }
    }

    func set(seq: UInt64, epoch: String?) {
        value.withLock { $0 = (seq, epoch) }
    }
}

/// One task owned by the store, cancelled when it is replaced and when the slot is released with the store.
final class TaskSlot: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)

    /// Puts `new` in the slot and cancels the task it replaces.
    func replace(with new: Task<Void, Never>?) {
        let old = task.withLock { task in
            defer { task = new }
            return task
        }
        old?.cancel()
    }

    deinit {
        task.withLock { $0 }?.cancel()
    }
}

/// When each order the app submitted began, so its first fill can be timed. Entries older than `maxAgeNs` are dropped
/// without a sample, on every `begin` and every `finish`, which keeps the table as small as the orders of the last
/// ten seconds.
struct FillTimer {
    /// Ten seconds: the longest latency the recorder keeps without clamping it.
    static let maxAgeNs: UInt64 = 10_000_000_000

    private(set) var starts: [String: UInt64] = [:]

    /// Notes that `clientOrderId` began at `nowNs`, unless it already has a start.
    mutating func begin(_ clientOrderId: String, nowNs: UInt64) {
        prune(nowNs: nowNs)
        if starts[clientOrderId] == nil { starts[clientOrderId] = nowNs }
    }

    /// The time from the start of `clientOrderId` to `nowNs`, once: the entry is removed. Nil without an entry.
    mutating func finish(_ clientOrderId: String, nowNs: UInt64) -> Int64? {
        prune(nowNs: nowNs)
        guard let start = starts.removeValue(forKey: clientOrderId) else { return nil }
        return Int64(clamping: nowNs >= start ? nowNs - start : 0)
    }

    /// Forgets `clientOrderId` (an order that will never fill).
    mutating func forget(_ clientOrderId: String) {
        starts[clientOrderId] = nil
    }

    private mutating func prune(nowNs: UInt64) {
        starts = starts.filter { nowNs < $0.value || nowNs - $0.value <= Self.maxAgeNs }
    }
}

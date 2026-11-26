import Foundation
import Synchronization

/// One call of a fake that answers from a script, one answer per call, and notes every argument it was given. A held
/// call does not return until the test releases it by its number, so a test can have two calls in flight and let them
/// end in either order.
///
/// Once the script is used up every call gets the fallback, which fails as a server that is not there does.
final class ScriptedCall<Argument: Sendable, Value: Sendable>: Sendable {
    /// What one call does.
    enum Answer: Sendable {
        /// Returns this value.
        case value(Value)
        /// Throws this error.
        case failure(any Error)
        /// Does not return until the test calls `release(call:_:)`.
        case hold
    }

    /// What the double keeps between calls, under one lock.
    private struct Shared {
        /// The answers still to give, oldest first.
        var script: [Answer]
        /// The argument of every call, in the order the calls arrived.
        var arguments: [Argument] = []
        /// The calls that wait for a release, by the number of the call (0 is the first call).
        var held: [Int: CheckedContinuation<Value, any Error>] = [:]
    }

    /// The answer once the script is used up.
    private let fallback: Answer
    /// Where each call is noted as `name`, so that a test can see the order of calls of several doubles; nil notes
    /// nothing.
    private let log: (log: EventLog, name: String)?
    /// The script, the arguments and the held calls.
    private let shared: Mutex<Shared>

    /// A call that gives the answers of `script`, one per call, and `fallback` after them. With `log` it also notes
    /// each call there under `name`.
    init(
        _ script: [Answer] = [], fallback: Answer = .failure(URLError(.cannotConnectToHost)),
        log: (log: EventLog, name: String)? = nil
    ) {
        self.fallback = fallback
        self.log = log
        shared = Mutex(Shared(script: script))
    }

    /// Notes `argument` and gives the next answer of the script. A held call is counted in `heldCount` only once it can
    /// be released, so a test that waits for a held call waits for that count and not for the argument.
    func call(_ argument: Argument) async throws -> Value {
        let fallback = fallback
        log?.log.add(log?.name ?? "")
        let (number, answer) = shared.withLock { shared in
            shared.arguments.append(argument)
            let answer = shared.script.isEmpty ? fallback : shared.script.removeFirst()
            return (shared.arguments.count - 1, answer)
        }
        switch answer {
        case .value(let value): return value
        case .failure(let error): throw error
        case .hold:
            return try await withCheckedThrowingContinuation { continuation in
                shared.withLock { $0.held[number] = continuation }
            }
        }
    }

    /// Lets the held call number `call` (0 is the first call) return `result`; false when that call is not held.
    @discardableResult
    func release(call: Int, _ result: Result<Value, any Error>) -> Bool {
        let held = shared.withLock { $0.held.removeValue(forKey: call) }
        held?.resume(with: result)
        return held != nil
    }

    /// The argument of every call so far, in the order the calls arrived.
    var arguments: [Argument] { shared.withLock { $0.arguments } }
    /// How many calls there were.
    var count: Int { shared.withLock { $0.arguments.count } }
    /// How many calls wait for a release.
    var heldCount: Int { shared.withLock { $0.held.count } }
}

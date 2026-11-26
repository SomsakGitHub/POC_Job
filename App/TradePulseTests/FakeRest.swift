import Contracts
import Foundation
import Synchronization
import TradeCore
import TradeNetworking

/// A REST API whose calls all answer from scripts: the symbol list, the candle history, the account and the
/// transactions each from a script of their own, and the server's clock, the lab's settings, the drop of the
/// connections and the reset each from a `ScriptedCall`. A call that has no script fails as a server that is not
/// there does: with `URLError.cannotConnectToHost`. A scripted `.hold` keeps the call until the test releases it.
final class FakeRest: RestAPI {
    /// What one call to `symbols()` does.
    enum Answer: Sendable {
        /// Returns this list.
        case list([SymbolDTO])
        /// Throws this error.
        case failure(any Error)
        /// Does not return until the test calls `release(_:)`.
        case hold
    }

    /// What one call to `candles(ticker:interval:limit:)` does.
    enum CandleAnswer: Sendable {
        /// Returns these candles.
        case candles([Candle])
        /// Throws this error.
        case failure(any Error)
        /// Does not return until the test calls `releaseCandles(call:_:)`.
        case hold
    }

    /// What one call to `account()` does.
    enum AccountAnswer: Sendable {
        /// Returns this account.
        case account(AccountDTO)
        /// Throws this error.
        case failure(any Error)
        /// Does not return until the test calls `releaseAccount(call:_:)`.
        case hold
    }

    /// What one call to `transactions(cursor:limit:)` does.
    enum TransactionAnswer: Sendable {
        /// Returns this page.
        case page(TransactionPageDTO)
        /// Throws this error.
        case failure(any Error)
        /// Does not return until the test calls `releaseTransactions(call:_:)`.
        case hold
    }

    /// The arguments of one call to `candles(ticker:interval:limit:)`.
    struct CandleCall: Equatable, Sendable {
        /// The ticker asked for.
        let ticker: String
        /// The interval asked for.
        let interval: CandleInterval
        /// How many candles were asked for.
        let limit: Int
    }

    /// The arguments of one call to `transactions(cursor:limit:)`.
    struct TransactionCall: Equatable, Sendable {
        /// The cursor asked for; nil for the first page.
        let cursor: String?
        /// How many transactions were asked for.
        let limit: Int
    }

    /// What the fake keeps between calls, under one lock.
    private struct Shared {
        /// The answers still to give, oldest first.
        var script: [Answer]
        /// The answer once the script is used up.
        var fallback: Answer
        /// How many times `symbols()` was called.
        var symbolCalls = 0
        /// How many times `account()` was called.
        var accountCalls = 0
        /// The calls of `symbols()` that wait for a release, oldest first.
        var held: [CheckedContinuation<[SymbolDTO], any Error>] = []
        /// The candle answers still to give, oldest first.
        var candleScript: [CandleAnswer]
        /// The candle answer once the candle script is used up.
        var candleFallback: CandleAnswer
        /// Every call of `candles(ticker:interval:limit:)`, in the order it arrived.
        var candleCalls: [CandleCall] = []
        /// The candle calls that wait for a release, by the number of the call (0 is the first call).
        var heldCandles: [Int: CheckedContinuation<[Candle], any Error>] = [:]
        /// The account answers still to give, oldest first.
        var accountScript: [AccountAnswer]
        /// The account answer once the account script is used up.
        var accountFallback: AccountAnswer
        /// The account calls that wait for a release, by the number of the call (0 is the first call).
        var heldAccounts: [Int: CheckedContinuation<AccountDTO, any Error>] = [:]
        /// The transaction answers still to give, oldest first.
        var transactionScript: [TransactionAnswer]
        /// The transaction answer once the transaction script is used up.
        var transactionFallback: TransactionAnswer
        /// Every call of `transactions(cursor:limit:)`, in the order it arrived.
        var transactionCalls: [TransactionCall] = []
        /// The transaction calls that wait for a release, by the number of the call (0 is the first call).
        var heldTransactions: [Int: CheckedContinuation<TransactionPageDTO, any Error>] = [:]
    }

    /// The fake's script and counters.
    private let shared: Mutex<Shared>
    /// Where each call of `account()` is noted as "rest.account"; nil notes nothing.
    private let accountLog: EventLog?
    /// The answers of `serverTimeNs()`.
    let serverTime: ScriptedCall<Void, Int64>
    /// The answers of `lab()`.
    let labRead: ScriptedCall<Void, LabSettings>
    /// The answers of `setLab(_:)`, and the patches it was given.
    let labWrite: ScriptedCall<LabPatch, LabSettings>
    /// The answers of `dropConnections()`.
    let drops: ScriptedCall<Void, Void>
    /// The answers of `resetServer()`.
    let resets: ScriptedCall<Void, String>

    /// A fake that gives the answers of `script`, one per call, and `fallback` once the script is used up. The history,
    /// account and transaction calls are answered the same way from `candles`, `accounts` and `transactions`, each with
    /// its own fallback; unless a test says otherwise they fail as a server that is not there.
    init(
        _ script: [Answer] = [], fallback: Answer = .list(sampleSymbols), candles: [CandleAnswer] = [],
        candlesFallback: CandleAnswer = .failure(URLError(.cannotConnectToHost)),
        accounts: [AccountAnswer] = [], accountsFallback: AccountAnswer = .failure(URLError(.cannotConnectToHost)),
        transactions: [TransactionAnswer] = [],
        transactionsFallback: TransactionAnswer = .failure(URLError(.cannotConnectToHost)),
        serverTime: ScriptedCall<Void, Int64> = ScriptedCall(),
        labRead: ScriptedCall<Void, LabSettings> = ScriptedCall(),
        labWrite: ScriptedCall<LabPatch, LabSettings> = ScriptedCall(),
        drops: ScriptedCall<Void, Void> = ScriptedCall(),
        resets: ScriptedCall<Void, String> = ScriptedCall(), accountLog: EventLog? = nil
    ) {
        self.accountLog = accountLog
        self.serverTime = serverTime
        self.labRead = labRead
        self.labWrite = labWrite
        self.drops = drops
        self.resets = resets
        shared = Mutex(
            Shared(
                script: script, fallback: fallback, candleScript: candles, candleFallback: candlesFallback,
                accountScript: accounts, accountFallback: accountsFallback, transactionScript: transactions,
                transactionFallback: transactionsFallback
            )
        )
    }

    /// Gives the next answer of the script.
    func symbols() async throws -> [SymbolDTO] {
        let answer = shared.withLock { shared in
            shared.symbolCalls += 1
            return shared.script.isEmpty ? shared.fallback : shared.script.removeFirst()
        }
        switch answer {
        case .list(let list): return list
        case .failure(let error): throw error
        case .hold:
            return try await withCheckedThrowingContinuation { continuation in
                shared.withLock { $0.held.append(continuation) }
            }
        }
    }

    /// Lets the oldest held call return `result`; false when no call is held.
    @discardableResult
    func release(_ result: Result<[SymbolDTO], any Error>) -> Bool {
        let held = shared.withLock { shared in
            shared.held.isEmpty ? nil : shared.held.removeFirst()
        }
        held?.resume(with: result)
        return held != nil
    }

    /// How many times `symbols()` was called.
    var symbolCalls: Int { shared.withLock { $0.symbolCalls } }
    /// How many times `account()` was called.
    var accountCalls: Int { shared.withLock { $0.accountCalls } }
    /// How many calls of `symbols()` wait for a release.
    var heldCount: Int { shared.withLock { $0.held.count } }

    /// Counts the call and gives the next answer of the account script. A held call does not return until the test
    /// releases it by its number; a test that waits for a held call waits for `heldAccountCount`, which counts it only
    /// once it can be released.
    func account() async throws -> AccountDTO {
        accountLog?.add("rest.account")
        let (number, answer) = shared.withLock { shared in
            shared.accountCalls += 1
            let answer = shared.accountScript.isEmpty ? shared.accountFallback : shared.accountScript.removeFirst()
            return (shared.accountCalls - 1, answer)
        }
        switch answer {
        case .account(let account): return account
        case .failure(let error): throw error
        case .hold:
            return try await withCheckedThrowingContinuation { continuation in
                shared.withLock { $0.heldAccounts[number] = continuation }
            }
        }
    }

    /// Lets the held account call number `call` (0 is the first call) return `result`; false when that call is not
    /// held.
    @discardableResult
    func releaseAccount(call: Int, _ result: Result<AccountDTO, any Error>) -> Bool {
        let held = shared.withLock { $0.heldAccounts.removeValue(forKey: call) }
        held?.resume(with: result)
        return held != nil
    }

    /// How many account calls wait for a release.
    var heldAccountCount: Int { shared.withLock { $0.heldAccounts.count } }

    /// Notes the call and gives the next answer of the candle script. A held call does not return until the test
    /// releases it by its number; the call is noted first, so a test can wait for it to be held.
    func candles(ticker: String, interval: CandleInterval, limit: Int) async throws -> [Candle] {
        let (number, answer) = shared.withLock { shared in
            shared.candleCalls.append(CandleCall(ticker: ticker, interval: interval, limit: limit))
            let answer = shared.candleScript.isEmpty ? shared.candleFallback : shared.candleScript.removeFirst()
            return (shared.candleCalls.count - 1, answer)
        }
        switch answer {
        case .candles(let candles): return candles
        case .failure(let error): throw error
        case .hold:
            return try await withCheckedThrowingContinuation { continuation in
                shared.withLock { $0.heldCandles[number] = continuation }
            }
        }
    }

    /// Lets the held candle call number `call` (0 is the first call) return `result`; false when that call is not held.
    @discardableResult
    func releaseCandles(call: Int, _ result: Result<[Candle], any Error>) -> Bool {
        let held = shared.withLock { $0.heldCandles.removeValue(forKey: call) }
        held?.resume(with: result)
        return held != nil
    }

    /// Every call of `candles(ticker:interval:limit:)` so far, in the order it arrived.
    var candleCalls: [CandleCall] { shared.withLock { $0.candleCalls } }
    /// How many candle calls wait for a release.
    var heldCandleCount: Int { shared.withLock { $0.heldCandles.count } }

    /// Notes the call and gives the next answer of the transaction script. A held call does not return until the test
    /// releases it by its number; the call is noted first, so a test can wait for it to be held.
    func transactions(cursor: String?, limit: Int) async throws -> TransactionPageDTO {
        let (number, answer) = shared.withLock { shared in
            shared.transactionCalls.append(TransactionCall(cursor: cursor, limit: limit))
            let answer =
                shared.transactionScript.isEmpty ? shared.transactionFallback : shared.transactionScript.removeFirst()
            return (shared.transactionCalls.count - 1, answer)
        }
        switch answer {
        case .page(let page): return page
        case .failure(let error): throw error
        case .hold:
            return try await withCheckedThrowingContinuation { continuation in
                shared.withLock { $0.heldTransactions[number] = continuation }
            }
        }
    }

    /// Lets the held transaction call number `call` (0 is the first call) return `result`; false when that call is not
    /// held.
    @discardableResult
    func releaseTransactions(call: Int, _ result: Result<TransactionPageDTO, any Error>) -> Bool {
        let held = shared.withLock { $0.heldTransactions.removeValue(forKey: call) }
        held?.resume(with: result)
        return held != nil
    }

    /// Every call of `transactions(cursor:limit:)` so far, in the order it arrived.
    var transactionCalls: [TransactionCall] { shared.withLock { $0.transactionCalls } }
    /// How many transaction calls wait for a release.
    var heldTransactionCount: Int { shared.withLock { $0.heldTransactions.count } }

    /// Gives the next answer of the server-time script.
    func serverTimeNs() async throws -> Int64 {
        try await serverTime.call(())
    }

    /// Gives the next answer of the lab-read script.
    func lab() async throws -> LabSettings {
        try await labRead.call(())
    }

    /// Notes the patch and gives the next answer of the lab-write script.
    func setLab(_ patch: LabPatch) async throws -> LabSettings {
        try await labWrite.call(patch)
    }

    /// Gives the next answer of the drop script.
    func dropConnections() async throws {
        try await drops.call(())
    }

    /// Gives the next answer of the reset script.
    func resetServer() async throws -> String {
        try await resets.call(())
    }
}

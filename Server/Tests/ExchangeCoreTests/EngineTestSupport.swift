import Synchronization
import Testing
import TradeCore
@testable import ExchangeCore

/// The nanosecond time every test engine starts at: the market start time of the market tests.
let engineStartNs: Int64 = marketStartMs * 1_000_000

/// The cash a test engine starts with unless a test asks for more: 1,000,000.00 baht.
let defaultStartingCash: Int64 = 100_000_000

/// A clock for the engine that a test controls: each reading returns the next value and moves on by `stepNs`, so every
/// reading is distinct and a test can tell which reading went where.
final class FakeClock: Sendable {
    private let next: Mutex<Int64>
    let stepNs: Int64

    init(startNs: Int64 = engineStartNs, stepNs: Int64 = 1_000) {
        next = Mutex(startNs)
        self.stepNs = stepNs
    }

    /// Returns the current value and moves the clock on by one step.
    func now() -> Int64 {
        next.withLock { value in
            defer { value += stepNs }
            return value
        }
    }

    /// The value the next reading will return, without taking a reading.
    var upcoming: Int64 {
        next.withLock { $0 }
    }
}

/// An engine over the catalog (seed 42) reading `clock`.
func makeEngine(
    symbols: [SymbolInfo] = catalogSymbols, seed: UInt64 = 42, clock: FakeClock = FakeClock(),
    eventLogCapacity: Int = 10_000, startingCash: Int64 = defaultStartingCash
) -> ExchangeEngine {
    ExchangeEngine(
        symbols: symbols, seed: seed, nowNs: { clock.now() }, eventLogCapacity: eventLogCapacity,
        startingCash: startingCash
    )
}

func order(
    _ clientOrderId: String, _ side: Side, _ type: OrderType, _ quantity: Quantity, limit: Int64? = nil,
    symbol: UInt32 = ptt.id
) -> OrderRequest {
    OrderRequest(
        clientOrderId: clientOrderId, symbolId: symbol, side: side, type: type, quantity: quantity,
        limitPrice: limit.map { Price(satang: $0) }
    )
}

/// The order id of an accepted outcome, or nil for a rejection.
func acceptedId(_ outcome: SubmitOutcome) -> String? {
    if case .accepted(let id, _) = outcome { id } else { nil }
}

/// Submits `request` and returns the id it was accepted under; the test fails if it was rejected.
func submitAccepted(_ engine: ExchangeEngine, _ request: OrderRequest) async throws -> String {
    let outcome = await engine.submit(request)
    return try #require(acceptedId(outcome), "\(request.clientOrderId) was rejected: \(outcome)")
}

/// The reason of a rejected outcome, or nil for an acceptance.
func rejectReason(_ outcome: SubmitOutcome) -> RejectReason? {
    if case .rejected(let reason, _) = outcome { reason } else { nil }
}

func timing(_ outcome: SubmitOutcome) -> ServerTimingNs {
    switch outcome {
    case .accepted(_, let timing), .rejected(_, let timing): timing
    }
}

/// The first `count` records of `stream`, or fewer when the stream ends first or `seconds` pass first, so that a test
/// never waits forever for a record that does not come. `ended` is true when the stream finished by itself.
func firstRecords(
    of stream: AsyncStream<OrderEventRecord>, count: Int, seconds: Int = 5
) async -> (records: [OrderEventRecord], ended: Bool) {
    await withTaskGroup(of: (records: [OrderEventRecord], ended: Bool)?.self) { group in
        group.addTask {
            var records: [OrderEventRecord] = []
            guard count > 0 else { return (records, false) }
            for await record in stream {
                records.append(record)
                if records.count == count { return (records, false) }
            }
            return (records, !Task.isCancelled)
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        var collected: (records: [OrderEventRecord], ended: Bool) = ([], false)
        for await result in group {
            if let result { collected = result }
            group.cancelAll()
        }
        return collected
    }
}

/// The records of the engine's log after `seq`, read through a stream in the engine's own epoch and closed once the
/// replay is in. The engine must not be changed while this runs.
func loggedEvents(_ engine: ExchangeEngine, after seq: UInt64 = 0) async throws -> [OrderEventRecord] {
    let epoch = await engine.epoch
    let last = await engine.account().lastEventSeq
    let stream = try await engine.eventStream(after: seq, clientEpoch: epoch)
    return await firstRecords(of: stream, count: Int(last > seq ? last - seq : 0)).records
}

/// The payloads of the engine's log after `seq`.
func loggedPayloads(_ engine: ExchangeEngine, after seq: UInt64 = 0) async throws -> [OrderEventPayload] {
    try await loggedEvents(engine, after: seq).map(\.payload)
}

/// The fills among `payloads`, in log order, as (order id, quantity, price, remaining).
func fills(
    in payloads: [OrderEventPayload]
) -> [(orderId: String, quantity: Quantity, price: Price, remaining: Quantity)] {
    payloads.compactMap {
        if case .fill(let orderId, _, _, let quantity, let price, let remaining) = $0 {
            (orderId, quantity, price, remaining)
        } else {
            nil
        }
    }
}

/// Advances `engine` one step of `stepMs` at a time from `fromMs`, at most `maxSteps` times, until `done` holds for the
/// payloads the step logged. Returns the time reached and the payloads of the step that made `done` true, or nil when
/// the bound was reached first (a test then fails on that nil).
func advanceUntil(
    _ engine: ExchangeEngine, fromMs: Int64, stepMs: Int64 = 1_000, rate: Double = 20, maxSteps: Int = 2_000,
    _ done: ([OrderEventPayload]) -> Bool
) async throws -> (atMs: Int64, payloads: [OrderEventPayload])? {
    var atMs = fromMs
    for _ in 0..<maxSteps {
        let before = await engine.account().lastEventSeq
        atMs += stepMs
        _ = await engine.advance(toMs: atMs, updatesPerSymbolPerSecond: rate)
        let payloads = try await loggedPayloads(engine, after: before)
        if done(payloads) { return (atMs, payloads) }
    }
    return nil
}

/// The engine's current quote of `symbolId`.
func currentQuote(_ engine: ExchangeEngine, _ symbolId: UInt32 = ptt.id) async throws -> SymbolQuote {
    let all = await engine.quotes()
    return try #require(all.first { $0.symbolId == symbolId })
}

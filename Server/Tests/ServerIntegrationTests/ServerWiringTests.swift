import Contracts
import ExchangeCore
import Testing
import TradeCore
@testable import ExchangeServerKit

/// How the app is put together: what its configuration reaches, which clock and lab the routes and the runner share,
/// and what the service group runs and stops.
@Suite("ServerWiringTests")
struct ServerWiringTests {
    /// The shares traded on every symbol so far; it only grows, and it grows faster the more the market ticks.
    private func totalDayVolume(_ engine: ExchangeEngine) async -> Int64 {
        await engine.quotes().map(\.dayVolume).reduce(0, +)
    }

    @Test func configurationStartsWithTheDocumentedDefaults() {
        let config = ServerConfig()
        #expect(config.eventLogCapacity == 10_000)
        #expect(config.commissionBps == 15)
    }

    @Test func theConfiguredCommissionReachesTheLedger() async throws {
        var config = ServerConfig.ephemeral
        config.commissionBps = 100
        try await withRestServer(config: config) { app, client in
            try await submitMarket(app.engine, "buy", .buy)
            let page = try await client.get("/v1/transactions").decode(TransactionPageDTO.self)
            let entry = try #require(page.items.first)
            let value = entry.price * entry.quantity
            #expect(entry.commission == Commission.compute(notional: value, bps: 100))
        }
    }

    /// Two orders make six events (accepted, fill and ledger entry each). A log of three has dropped the first three.
    @Test func theConfiguredEventLogCapacityReachesTheEngine() async throws {
        var config = ServerConfig.ephemeral
        config.eventLogCapacity = 3
        let app = ExchangeServerApp(config: config)
        try await submitMarket(app.engine, "one", .buy)
        try await submitMarket(app.engine, "two", .buy)

        await #expect(throws: EventLogError.outOfRange(oldestRetained: 4)) {
            _ = try await app.engine.eventStream(after: 0, clientEpoch: nil)
        }
    }

    @Test func theDefaultEventLogStillHoldsASessionOfSixEvents() async throws {
        let app = ExchangeServerApp(config: .ephemeral)
        try await submitMarket(app.engine, "one", .buy)
        try await submitMarket(app.engine, "two", .buy)

        _ = try await app.engine.eventStream(after: 0, clientEpoch: nil)
    }

    @Test func theConfiguredSeedReachesTheMarket() async {
        let now: @Sendable () -> Int64 = { 1_732_000_000_000_000_000 }
        var config = ServerConfig.ephemeral
        config.seed = 7
        let first = await ExchangeServerApp(config: config, nowNs: now).engine.quotes()
        let again = await ExchangeServerApp(config: config, nowNs: now).engine.quotes()
        config.seed = 8
        let other = await ExchangeServerApp(config: config, nowNs: now).engine.quotes()
        #expect(first.count == 12)
        #expect(first == again)
        #expect(first != other)
    }

    /// The time route and the engine read one clock: with a clock that always says the same, both say it.
    @Test func theRoutesAndTheEngineReadTheSameClock() async throws {
        let stamp: Int64 = 1_732_000_000_123_456_789
        try await withRestServer(nowNs: { stamp }) { app, client in
            let time = try await client.get("/v1/time")
            #expect(time.text == #"{"serverNs":1732000000123456789}"#)

            try await submitMarket(app.engine, "buy", .buy)
            let page = try await client.get("/v1/transactions").decode(TransactionPageDTO.self)
            #expect(page.items.map(\.tsNs) == [stamp])
        }
    }

    @Test func theLabOfTheAppIsTheOneTheRoutesUse() async throws {
        try await withRestServer { app, client in
            await app.lab.apply(LabPatch(jitterMs: 77))
            let viaRoute = try await client.get("/v1/admin/lab").decode(LabSettings.self)
            #expect(viaRoute.jitterMs == 77)

            _ = try await client.post("/v1/admin/lab", json: #"{"extraLatencyMs":12}"#)
            let direct = await app.lab.settings()
            #expect(direct.extraLatencyMs == 12)
            #expect(direct.jitterMs == 77)
        }
    }

    @Test func theMarketAdvancesWhileTheServerRuns() async throws {
        try await withRunningServer { app, _ in
            let before = await totalDayVolume(app.engine)
            let moved = await eventually { await totalDayVolume(app.engine) > before }
            #expect(moved, "the market did not move while the server ran")
        }
    }

    /// The shares traded per clock reading while the clock is read `count` more times. The market's time is the
    /// clock's, and the clock moves at every reading, so this does not depend on how fast the machine runs.
    private func tradedPerReading(_ engine: ExchangeEngine, _ clock: SteppedClock, over count: Int) async -> Double {
        let firstReading = clock.readings
        let before = await totalDayVolume(engine)
        _ = await eventually { clock.readings >= firstReading + count }
        let after = await totalDayVolume(engine)
        return Double(after - before) / Double(clock.readings - firstReading)
    }

    /// Stress mode, switched on through the route, makes the running market tick many times faster: the shares traded
    /// per reading of the clock grow by a multiple of what they were before.
    @Test func theRunnerFollowsTheLabSettingsOfTheRoutes() async throws {
        let clock = SteppedClock(startNs: 1_732_000_000_000_000_000, stepNs: 2_000_000)
        try await withRestServer(nowNs: { clock.now() }) { app, client in
            let normal = await tradedPerReading(app.engine, clock, over: 50)
            let switched = try await client.post("/v1/admin/lab", json: #"{"stress":true}"#)
            let stress = await tradedPerReading(app.engine, clock, over: 50)

            #expect(switched.status == 200)
            #expect(normal > 0)
            #expect(stress > 3 * normal, "\(normal) shares per reading, then \(stress) in stress mode")
        }
    }

    /// The service group has no limit on how long a shutdown may take, so every service must end when it is told to.
    @Test func aGracefulShutdownOfTheWholeAppCompletesWithinABound() async throws {
        let server = try await startServer()
        let client = RestClient(host: server.host, port: server.ports.rest)
        // The runner is running and a client holds a connection when the shutdown begins.
        let health = try await client.get("/healthz")
        #expect(health.status == 200)
        let before = await totalDayVolume(server.app.engine)
        let running = await eventually { await totalDayVolume(server.app.engine) > before }
        #expect(running, "the market was not moving before the shutdown")

        let stopped = await server.shutDown(within: patience)
        #expect(stopped, "run() did not return after a graceful shutdown")
    }
}

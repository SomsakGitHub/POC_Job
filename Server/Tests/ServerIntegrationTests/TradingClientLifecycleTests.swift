import Contracts
import ExchangeCore
import GRPCCore
import Testing
import TradeCore
import TradeNetworking
@testable import ExchangeServerKit

/// The life of the trading client's connection against a real server: when it counts as connected, what a submit
/// does with no connection, a nudge, a stop and a start again, and a quiet stream across keepalive pings.
extension TradingClientTests {
    /// The stream's response head is enough: a server with no orders still makes the client `.connected`.
    @Test func freshServerReachesConnected() async throws {
        try await withTradingStore { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            let state = await rig.state()
            let engine = await rig.app.engine.account()
            #expect(engine.lastEventSeq == 0)
            #expect(state.epoch == engine.epoch)
            #expect(state.lastEventSeq == 0)
        }
    }

    /// Before the stream is started nobody will connect, so a submit fails at once without waiting; a submit made
    /// the moment the stream starts, before its connection is up, is retried until it is, and makes one order.
    @Test func submitBeforeTheConnectionIsUpIsRetriedIntoOneOrder() async throws {
        try await withTradingStore { rig in
            let client = rig.client.base
            let early = await rpcError { _ = try await client.submit(marketDraft("early")) }
            #expect(early?.code == .unavailable)
            #expect(rig.sleeps.waits.isEmpty)
            let untouched = await rig.app.engine.account()
            #expect(untouched.lastEventSeq == 0)

            rig.client.startEventStream(resumeFrom: { (0, nil) }, onEvent: { _ in }, onOutOfRange: {})
            let first = try await client.submit(marketDraft("first"))
            #expect(first.accepted)
            #expect(rig.sleeps.waits.first == .milliseconds(250))
            let again = try await client.submit(marketDraft("first"))
            #expect(again.orderId == first.orderId)
            // Only the answered attempt of each submit is timed: the early failure and the failed attempts are not.
            #expect(rig.latency.summary(.orderSubmitToAck).count == 2)

            let logged = await rig.app.engine.account().lastEventSeq
            let delivered = await eventually { rig.client.events.last?.eventSeq == logged }
            #expect(delivered)
            let accepted = rig.client.events.filter { $0.kind == "accepted" }
            #expect(accepted.map(\.accepted.clientOrderID) == ["first"])
        }
    }

    @Test func nudgeReconnectsAndSubmitWorksAfter() async throws {
        try await withTradingStore { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            let index = rig.log.count
            rig.client.nudge()
            let dropped = await rig.log.wait(after: index) { $0.isReconnecting }
            #expect(dropped != nil)
            let back = await rig.connected(after: index)
            #expect(back)
            await rig.store.submit(marketDraft("after-nudge"))
            let caughtUp = await rig.caughtUp()
            #expect(caughtUp)
            let row = await rig.state().row("after-nudge")
            #expect(row?.status == .filled)
            #expect(rig.sleeps.waits.isEmpty)
        }
    }

    /// A stopped client started again by the same store picks up the events it missed, keeps the rows it had and
    /// makes none twice.
    @Test func startAgainKeepsRowsAndReceivesWhatWasMissed() async throws {
        try await withTradingStore { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            await rig.store.submit(marketDraft("kept"))
            let first = await rig.caughtUp()
            #expect(first)
            await rig.client.stop()

            try await submitMarket(rig.app.engine, "missed-1", .buy)
            try await submitMarket(rig.app.engine, "missed-2", .sell)
            await rig.store.start()
            let second = await rig.caughtUp()
            #expect(second)
            let state = await rig.state()
            #expect(state.orders.map(\.id).sorted() == ["kept", "missed-1", "missed-2"])
            #expect(state.epochChanges == 0)
            let delivered = rig.client.events.map(\.eventSeq)
            #expect(isStrictlyIncreasing(delivered))
            #expect(isContiguousFromOne(delivered))
        }
    }

    /// After `stop()` nobody will reconnect: a submit fails at once, with none of the waits between attempts.
    @Test func submitAfterStopFailsAtOnce() async throws {
        try await withTradingStore { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            await rig.client.stop()
            let client = rig.client.base
            let start = ContinuousClock.now
            let error = await rpcError { _ = try await client.submit(marketDraft("late")) }
            let took = start.duration(to: .now)
            #expect(error?.code == .unavailable)
            // No client of the stopped connection is left behind for a call to find.
            #expect(error?.message == "no connection to the order service")
            #expect(rig.sleeps.waits.isEmpty)
            #expect(took < .milliseconds(700), "the submit waited \(took)")
            let engine = await rig.app.engine.account()
            #expect(engine.lastEventSeq == 0)
        }
    }

    /// `.connected` means the stream is established: a peer that accepts the TCP connection and never speaks HTTP/2
    /// never makes the client connected (`freshServerReachesConnected` is the positive control), and `stop()` still
    /// returns at once.
    @Test func aSilentPeerNeverCountsAsConnected() async throws {
        let listener = try SilentListener()
        defer { listener.close() }
        let client = GRPCTradingClient(
            config: ClientConfig(host: "127.0.0.1", grpcPort: listener.port), latency: LatencyRecorder())
        let log = StateLog(client.connection)
        client.startEventStream(resumeFrom: { (0, nil) }, onEvent: { _ in }, onOutOfRange: {})
        let connected = await log.wait(within: .seconds(3)) { $0 == .connected }
        #expect(connected == nil)
        #expect(log.states.first == .connecting)
        let stopped = await finishes(within: .seconds(5)) { await client.stop() }
        #expect(stopped, "stop() did not return with a silent peer")
        await log.finished()
    }

    /// A submit to a peer that never answers runs into the 2 s deadline on each attempt that finds the connection,
    /// is tried 3 times with the 250 ms and 500 ms waits, throws the last attempt's `deadlineExceeded`, and records
    /// no round trip: only an answered attempt is timed.
    @Test func aSubmitToASilentPeerTimesOutThreeTimesAndRecordsNothing() async throws {
        let listener = try SilentListener()
        defer { listener.close() }
        let latency = LatencyRecorder()
        let sleeps = CountingSleep()
        let client = GRPCTradingClient(
            config: ClientConfig(host: "127.0.0.1", grpcPort: listener.port), latency: latency,
            sleep: { try await sleeps.sleep($0) })
        client.startEventStream(resumeFrom: { (0, nil) }, onEvent: { _ in }, onOutOfRange: {})
        let error = await rpcError { _ = try await client.submit(marketDraft("into-the-void")) }
        #expect(error?.code == .deadlineExceeded)
        #expect(sleeps.waits == [.milliseconds(250), .milliseconds(500)])
        #expect(latency.summary(.orderSubmitToAck).count == 0)
        #expect(latency.summary(.orderServerProcessing).count == 0)
        let stopped = await finishes(within: .seconds(5)) { await client.stop() }
        #expect(stopped)
    }

    /// The stream is opened again only once the out-of-range handler has finished, so the next connection asks
    /// from the point the handler left: one recovery, however long it takes.
    @Test func outOfRangeIsAwaitedBeforeTheStreamOpensAgain() async throws {
        var config = ServerConfig.ephemeral
        config.eventLogCapacity = 10
        try await withRunningServer(config: config) { app, ports in
            await logRejectedOrders(app.engine, count: 30)
            let account = await app.engine.account()
            let (last, epoch) = (account.lastEventSeq, account.epoch)
            let client = GRPCTradingClient(
                config: ClientConfig(host: config.host, restPort: ports.rest, grpcPort: ports.grpc),
                latency: LatencyRecorder())
            let point = ResumeBox()
            let recoveries = Counter()
            let received = Counter()
            client.startEventStream(
                resumeFrom: { point.value },
                onEvent: { _ in received.increment() },
                onOutOfRange: {
                    recoveries.increment()
                    try? await Task.sleep(for: .seconds(1))
                    point.set(seq: last, epoch: epoch)
                })
            let recovered = await eventually { point.value.seq == last }
            #expect(recovered)
            // A new event shows that a stream from the recovered point is open.
            await logRejectedOrders(app.engine, count: 1, prefix: "after")
            let streaming = await eventually { received.value == 1 }
            #expect(streaming)
            #expect(recoveries.value == 1)
            await client.stop()
        }
    }

    /// The keepalive interval given is the one used: pings every second, which the server refuses (it allows one
    /// every 5 s), get the quiet connection closed and replaced.
    @Test func aKeepaliveIntervalTheServerRefusesGetsTheConnectionReplaced() async throws {
        try await withTradingStore(keepaliveInterval: .seconds(1)) { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            let replaced = await rig.log.wait(within: .seconds(20)) { $0.isReconnecting }
            #expect(replaced != nil, "the server never closed a connection that pinged every second")
        }
    }

    /// A connection that carries nothing for two keepalive intervals stays up, and the next order still goes out on
    /// it: no state other than `.connected` is seen after the first `.connected`.
    @Test func quietStreamStaysConnectedAcrossKeepalives() async throws {
        try await withTradingStore(keepaliveInterval: .seconds(6)) { rig in
            await rig.store.start()
            let connected = await rig.connected()
            #expect(connected)
            try await Task.sleep(for: .seconds(13))
            await rig.store.submit(marketDraft("after-quiet"))
            let caughtUp = await rig.caughtUp()
            #expect(caughtUp)
            let row = await rig.state().row("after-quiet")
            #expect(row?.status == .filled)
            let afterConnected = Array(rig.log.states.drop { $0 != .connected })
            #expect(afterConnected == [.connected])
            #expect(rig.sleeps.waits.isEmpty)
        }
    }
}

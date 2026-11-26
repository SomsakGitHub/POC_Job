import Contracts
import GRPCCore
import Testing
@testable import ExchangeCore
@testable import ExchangeServerKit

/// `StreamOrderEvents`: where the replay starts, the live events after it, and every way the stream ends.
extension GrpcOrderTests {
    @Test func streamResumesFromSeq() async throws {
        try await withOrderServer { app, client in
            await logRejectedOrders(app.engine, count: 4)
            let epoch = await app.engine.epoch
            try await withEventStream(client, after: 2, epoch: epoch) { call in
                let events = await call.events(atLeast: 2)
                #expect(events.map(\.eventSeq) == [3, 4])
                #expect(events.map(\.rejected.clientOrderID) == ["reject-3", "reject-4"])
            }
        }
    }

    @Test func clientEpochMismatchReplaysFromTheStart() async throws {
        try await withOrderServer { app, client in
            await logRejectedOrders(app.engine, count: 3)
            for epoch in ["an-epoch-of-another-run", ""] {
                try await withEventStream(client, after: 2, epoch: epoch) { call in
                    let events = await call.events(atLeast: 3)
                    #expect(events.map(\.eventSeq) == [1, 2, 3], "client epoch \"\(epoch)\"")
                }
            }
        }
    }

    /// A log of 10 after 25 events keeps 16...25; asking for what follows 2 cannot be answered without a gap.
    @Test func streamOutOfRangeStatus() async throws {
        var config = ServerConfig.ephemeral
        config.eventLogCapacity = 10
        try await withOrderServer(config: config) { app, client in
            await logRejectedOrders(app.engine, count: 25)
            let epoch = await app.engine.epoch
            try await withEventStream(client, after: 2, epoch: epoch) { call in
                let ending = await call.ending()
                guard case .failed(let code, let message) = ending else {
                    Issue.record("expected an outOfRange error, got \(String(describing: ending))")
                    return
                }
                #expect(code == .outOfRange)
                #expect(message.contains("16"), "\(message)")
            }
        }
    }

    @Test func streamDeliversLiveEventsAfterTheReplay() async throws {
        try await withOrderServer { app, client in
            await logRejectedOrders(app.engine, count: 2, prefix: "before")
            try await withEventStream(client, after: 0) { call in
                let replayed = await call.events(atLeast: 2)
                try #require(replayed.count == 2)
                let response = try await client.submitOrder(submitRequest("live", quantity: 150), options: boundedCall)
                #expect(response.rejectReason == .invalidLot)
                let events = await call.events(atLeast: 3)
                #expect(events.map(\.eventSeq) == [1, 2, 3])
                #expect(events.last?.rejected.clientOrderID == "live")
                #expect(events.last?.rejected.reason == .invalidLot)
            }
        }
    }

    /// A reset and a dropped connection both finish the engine's streams; the call then ends with status OK.
    @Test func resetEndsStream() async throws {
        try await withOrderServer { app, client in
            await logRejectedOrders(app.engine, count: 1)
            try await withEventStream(client, after: 0) { call in
                let replayed = await call.events(atLeast: 1)
                try #require(replayed.count == 1)
                await app.engine.reset()
                let ending = await call.ending()
                #expect(ending == .finished)
            }
            await logRejectedOrders(app.engine, count: 1)
            try await withEventStream(client, after: 0) { call in
                let replayed = await call.events(atLeast: 1)
                try #require(replayed.count == 1)
                await app.engine.dropStreams()
                let ending = await call.ending()
                #expect(ending == .finished)
            }
        }
    }

    /// A client that goes away leaves nothing behind: the engine no longer holds its stream.
    @Test func cancellingTheCallReleasesTheEngineStream() async throws {
        try await withOrderServer { app, client in
            let before = await app.engine.liveStreamCount
            let call = EventStreamCall(client, after: 0)
            let opened = await eventually { await app.engine.liveStreamCount == before + 1 }
            #expect(opened, "the stream never registered with the engine")
            let stopped = await call.cancel()
            #expect(stopped)
            let released = await eventually { await app.engine.liveStreamCount == before }
            #expect(released, "the engine still holds the cancelled call's stream")
        }
    }

    /// The service group waits for every service without a limit, so an open stream must not hold up a shutdown.
    @Test func gracefulShutdownEndsAnOpenStream() async throws {
        let server = try await startServer()
        let stopped = try await withOrderClient(server.ports) { client in
            let call = EventStreamCall(client, after: 0)
            let opened = await eventually { await server.app.engine.liveStreamCount == 1 }
            #expect(opened, "the stream never registered with the engine")

            let stopped = await server.shutDown(within: patience)
            let ending = await call.ending()
            #expect(ending == .finished)
            _ = await call.cancel()
            return stopped
        }
        #expect(stopped, "run() did not return with a stream open")
    }
}

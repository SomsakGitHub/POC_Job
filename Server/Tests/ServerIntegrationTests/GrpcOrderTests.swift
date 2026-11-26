import Contracts
import ExchangeCore
import GRPCCore
import GRPCNIOTransportHTTP2
import ServiceLifecycleTestKit
import Testing
import TradeCore
@testable import ExchangeServerKit

/// The order service over real HTTP/2, called with the raw generated client: submitting, cancelling and the transport
/// settings. The event stream's tests are in `GrpcOrderStreamTests.swift`.
@Suite("GrpcOrderTests")
struct GrpcOrderTests {
    @Test func submitMarketBuyAcceptedAndStreamed() async throws {
        try await withOrderServer { app, client in
            let response = try await client.submitOrder(submitRequest("buy-1"), options: boundedCall)
            #expect(response.accepted)
            #expect(!response.orderID.isEmpty)
            // Accepted, then a fill and its ledger entry for every level the order swept.
            let logged = Int(await app.engine.account().lastEventSeq)
            try #require(logged >= 3)

            let epoch = await app.engine.epoch
            try await withEventStream(client, after: 0) { call in
                let events = await call.events(atLeast: logged)
                try #require(events.count >= logged)
                #expect(events.prefix(3).map(\.kind) == ["accepted", "fill", "ledgerEntry"])
                #expect(events.map(\.eventSeq) == Array(1...UInt64(events.count)))
                #expect(events.allSatisfy { $0.serverEpoch == epoch })
                #expect(events[0].accepted.orderID == response.orderID)
                #expect(events[0].accepted.clientOrderID == "buy-1")
                #expect(events[1].fill.orderID == response.orderID)
                #expect(events[2].ledgerEntry.orderID == response.orderID)
            }
        }
    }

    @Test func duplicateSubmitSameResponse() async throws {
        try await withOrderServer { app, client in
            let first = try await client.submitOrder(submitRequest("same"), options: boundedCall)
            let second = try await client.submitOrder(submitRequest("same"), options: boundedCall)
            #expect(first.accepted)
            #expect(second == first, "a retry must get the stored answer, its timing included")

            let logged = Int(await app.engine.account().lastEventSeq)
            try await withEventStream(client, after: 0) { call in
                let events = await call.events(atLeast: logged)
                try #require(events.count == logged)
                #expect(events.filter { $0.kind == "accepted" }.count == 1)
            }
        }
    }

    /// A side or type the server cannot read is a malformed request: an RPC error, and nothing reaches the engine.
    @Test func unspecifiedSideIsInvalidArgument() async throws {
        try await withOrderServer { app, client in
            let malformed = [
                submitRequest("no-side", side: .unspecified),
                submitRequest("odd-side", side: .UNRECOGNIZED(7)),
                submitRequest("no-type", type: .unspecified),
                submitRequest("odd-type", type: .UNRECOGNIZED(9)),
            ]
            for request in malformed {
                let error = await rpcError { _ = try await client.submitOrder(request, options: boundedCall) }
                #expect(error?.code == .invalidArgument, "\(request.clientOrderID)")
            }
            let logged = await app.engine.account().lastEventSeq
            #expect(logged == 0)
        }
    }

    /// The client order id is the key of the engine's idempotency table, so its size is bounded: 1 to 64 UTF-8 bytes.
    @Test func emptyClientOrderIdIsInvalidArgument() async throws {
        let thai = String(repeating: "ก", count: 21)  // 63 bytes in 21 characters
        let refused = ["", String(repeating: "x", count: 65), thai + "ab"]
        let allowed = [String(repeating: "y", count: 64), thai + "a"]
        try await withOrderServer { app, client in
            for id in refused {
                let error = await rpcError {
                    _ = try await client.submitOrder(submitRequest(id, quantity: 150), options: boundedCall)
                }
                #expect(error?.code == .invalidArgument, "\(id.utf8.count) bytes")
            }
            for id in allowed {
                let response = try await client.submitOrder(submitRequest(id, quantity: 150), options: boundedCall)
                #expect(response.rejectReason == .invalidLot, "\(id.utf8.count) bytes")
            }
            let logged = await app.engine.account().lastEventSeq
            #expect(logged == UInt64(allowed.count))
        }
    }

    /// A rule the order breaks is an answer, not a failed call: `accepted` false, the reason, no id, and the timing.
    @Test func businessRejectIsNotRpcError() async throws {
        try await withOrderServer { _, client in
            let lot = try await client.submitOrder(submitRequest("odd-lot", quantity: 150), options: boundedCall)
            #expect(!lot.accepted)
            #expect(lot.rejectReason == .invalidLot)
            #expect(lot.orderID.isEmpty)
            #expect(lot.hasTiming)
            #expect(lot.timing.recvNs > 0)

            // A limit order with no price (0 on the wire) is the engine's to refuse.
            let unpriced = try await client.submitOrder(submitRequest("no-price", type: .limit), options: boundedCall)
            #expect(!unpriced.accepted)
            #expect(unpriced.rejectReason == .invalidTick)

            let unknown = try await client.submitOrder(submitRequest("nowhere", symbol: 9_999), options: boundedCall)
            #expect(unknown.rejectReason == .unknownSymbol)
        }
    }

    @Test func timingIsOrdered() async throws {
        try await withOrderServer { _, client in
            let accepted = try await client.submitOrder(submitRequest("timed"), options: boundedCall)
            let rejected = try await client.submitOrder(submitRequest("timed-lot", quantity: 1), options: boundedCall)
            for response in [accepted, rejected] {
                #expect(response.hasTiming)
                #expect(response.timing.recvNs > 0)
                #expect(response.timing.ackNs >= response.timing.recvNs)
            }
        }
    }

    @Test func cancelOrderCancelsARestingLimitAndRefusesUnknown() async throws {
        try await withOrderServer { app, client in
            // A buy at the bottom of the band rests: the market is far above it.
            let symbol = try #require(await app.engine.symbols().first { $0.id == 1 })
            let low = TickRules.band(reference: symbol.reference).lowerBound.satang
            let tick = TickRules.tickSize(at: Price(satang: low)).satang
            let price = (low + tick - 1) / tick * tick
            let placed = try await client.submitOrder(
                submitRequest("rest", type: .limit, limitPrice: price), options: boundedCall
            )
            try #require(placed.accepted, "\(placed.rejectReason)")

            var cancel = Tp_CancelOrderRequest()
            cancel.orderID = placed.orderID
            let first = try await client.cancelOrder(cancel, options: boundedCall)
            let again = try await client.cancelOrder(cancel, options: boundedCall)
            cancel.orderID = "O-999999"
            let unknown = try await client.cancelOrder(cancel, options: boundedCall)
            cancel.orderID = ""
            let empty = try await client.cancelOrder(cancel, options: boundedCall)

            #expect(first.cancelled)
            #expect(!again.cancelled)
            #expect(!unknown.cancelled)
            #expect(!empty.cancelled)
            let logged = Int(await app.engine.account().lastEventSeq)
            try await withEventStream(client, after: 0) { call in
                let events = await call.events(atLeast: logged)
                #expect(events.map(\.kind) == ["accepted", "cancelled"])
                #expect(events.last?.cancelled.orderID == placed.orderID)
                #expect(events.last?.cancelled.reason == .unspecified)
            }
        }
    }

    /// The server accepts keepalive pings from a client with no call open, at most every 5 seconds.
    @Test func keepaliveAllowsClientPingsOnAnIdleChannel() {
        let behavior = GRPCServerService.transportConfig.connection.keepalive.clientBehavior
        #expect(behavior.allowWithoutCalls)
        #expect(behavior.minPingIntervalWithoutCalls == .seconds(5))
    }

    /// Regression: a graceful shutdown that reaches the gRPC service before `serve()` has started
    /// must not hang the service (it used to wait forever for a listening address).
    /// `testGracefulShutdown` makes the early-shutdown ordering deterministic. The test asks only whether `run()`
    /// returns at all, so it waits a full minute before it calls the service hung: a run that keeps every thread busy
    /// can delay an answer by seconds, and a late answer is not a wrong one.
    @Test(.timeLimit(.minutes(2))) func grpcShutdownBeforeServeReturns() async {
        let service = GRPCServerService(host: "127.0.0.1", port: 0, services: [], onListening: { _ in })
        let returned = await finishes(within: .seconds(60)) {
            await testGracefulShutdown { trigger in
                trigger.triggerGracefulShutdown()
                _ = try? await service.run()
            }
        }
        #expect(returned, "GRPCServerService.run() hung after a graceful shutdown that preceded serve()")
    }
}

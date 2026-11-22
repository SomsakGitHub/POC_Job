@testable import ExchangeServerKit
import ServiceLifecycleTestKit
import Testing
import TradeNetworking

@Suite("SkeletonTests")
struct SkeletonTests {
    @Test func restHealthz() async throws {
        try await withSkeletonServer { probe in
            let status = try await probe.rest()
            #expect(status == "ok")
        }
    }

    @Test func webSocketDeliversFrame() async throws {
        try await withSkeletonServer { probe in
            let last = try await probe.webSocketLast()
            #expect(last == 3425)
        }
    }

    @Test func grpcSubmitAccepted() async throws {
        try await withSkeletonServer { probe in
            let orderID = try await probe.grpcOrderId()
            #expect(orderID == "skeleton")
        }
    }

    /// Regression: a graceful shutdown that reaches the gRPC service before `serve()` has started
    /// must not hang the service (it used to wait forever for a listening address).
    /// `testGracefulShutdown` makes the early-shutdown ordering deterministic.
    @Test func grpcShutdownBeforeServeReturns() async {
        let service = GRPCServerService(host: "127.0.0.1", port: 0, services: [], onListening: { _ in })
        let returned = await finishes(within: .seconds(10)) {
            await testGracefulShutdown { trigger in
                trigger.triggerGracefulShutdown()
                _ = try? await service.run()
            }
        }
        #expect(returned, "GRPCServerService.run() hung after a graceful shutdown that preceded serve()")
    }
}

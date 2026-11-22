import Contracts
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

/// Walking-skeleton client: one round trip per protocol (REST, WebSocket, gRPC) against the exchange server.
public struct SkeletonProbe: Sendable {
    private let host: String
    private let restPort: Int
    private let grpcPort: Int

    public init(host: String, restPort: Int, grpcPort: Int) {
        self.host = host
        self.restPort = restPort
        self.grpcPort = grpcPort
    }

    /// `GET /healthz`; returns the `status` field ("ok").
    public func rest() async throws -> String {
        let url = try makeURL(scheme: "http", path: "/healthz")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SkeletonProbeError.unexpectedResponse("HTTP status \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
        }
        return try JSONDecoder().decode(Health.self, from: data).status
    }

    /// Opens `/ws/market` and returns `last` of the first symbol update in the first binary frame.
    public func webSocketLast() async throws -> Int64 {
        let task = URLSession.shared.webSocketTask(with: try makeURL(scheme: "ws", path: "/ws/market"))
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        guard case .data(let data) = try await task.receive() else {
            throw SkeletonProbeError.unexpectedResponse("expected a binary WebSocket frame")
        }
        let frame = try Tp_MarketFrame(serializedBytes: data)
        guard let update = frame.updates.first else {
            throw SkeletonProbeError.unexpectedResponse("frame has no symbol updates")
        }
        return update.last
    }

    /// Calls `tp.OrderService/SubmitOrder` over plaintext HTTP/2 and returns the order id.
    public func grpcOrderId() async throws -> String {
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: grpcPort),
            transportSecurity: .plaintext
        )
        return try await withGRPCClient(transport: transport) { client in
            var request = Tp_SubmitOrderRequest()
            request.clientOrderID = "skeleton-probe"
            request.symbolID = 1
            request.side = .buy
            request.type = .market
            request.quantity = 100
            let response = try await Tp_OrderService.Client(wrapping: client).submitOrder(request)
            guard response.accepted else {
                throw SkeletonProbeError.unexpectedResponse("order rejected: \(response.rejectReason)")
            }
            return response.orderID
        }
    }

    private func makeURL(scheme: String, path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = restPort
        components.path = path
        guard let url = components.url else { throw SkeletonProbeError.invalidURL }
        return url
    }
}

public enum SkeletonProbeError: Error, Sendable {
    case invalidURL
    case unexpectedResponse(String)
}

private struct Health: Decodable {
    let status: String
}

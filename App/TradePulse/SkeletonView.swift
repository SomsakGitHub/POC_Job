import Foundation
import Observation
import SwiftUI
import TradeNetworking

/// One protocol round trip shown on the skeleton screen.
struct ProbeRow: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case done(String)
        case failed(String)
    }

    let id: String
    let title: String
    var state: State
}

/// Runs the three `SkeletonProbe` calls (REST, WebSocket, gRPC) and exposes one row per protocol.
@MainActor
@Observable
final class SkeletonViewModel {
    private(set) var rows: [ProbeRow] = [
        ProbeRow(id: "rest", title: "REST", state: .pending),
        ProbeRow(id: "websocket", title: "WebSocket", state: .pending),
        ProbeRow(id: "grpc", title: "gRPC", state: .pending),
    ]

    private let probe: SkeletonProbe

    init(host: String = ProcessInfo.processInfo.environment["TRADEPULSE_HOST"] ?? "127.0.0.1") {
        probe = SkeletonProbe(host: host, restPort: 18080, grpcPort: 18051)
    }

    func run() async {
        let probe = probe
        async let rest = Self.outcome { try await probe.rest() }
        async let webSocket = Self.outcome { Self.baht(fromSatang: try await probe.webSocketLast()) }
        async let grpc = Self.outcome { try await probe.grpcOrderId() }
        rows[0].state = await rest
        rows[1].state = await webSocket
        rows[2].state = await grpc
    }

    /// Formats satang as baht with two decimals using integer arithmetic only, e.g. 3425 → "34.25".
    nonisolated static func baht(fromSatang satang: Int64) -> String {
        let sign = satang < 0 ? "-" : ""
        let magnitude = satang.magnitude
        let fraction = magnitude % 100
        return "\(sign)\(magnitude / 100).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    private nonisolated static func outcome(_ call: @Sendable () async throws -> String) async -> ProbeRow.State {
        do {
            return .done(try await call())
        } catch {
            return .failed(String(describing: error))
        }
    }
}

struct SkeletonView: View {
    @State private var viewModel = SkeletonViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.rows) { row in
                        ProbeRowView(row: row)
                    }
                } footer: {
                    Text("SIMULATED DATA")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("TradePulse")
        }
        .task { await viewModel.run() }
    }
}

private struct ProbeRowView: View {
    let row: ProbeRow

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            switch row.state {
            case .pending:
                Text(row.title)
                Spacer()
                ProgressView()
            case .done(let value):
                Text("\(row.title) \(value)")
                Spacer()
                Image(systemName: "checkmark")
                    .foregroundStyle(.primary)
                    .accessibilityLabel("done")
            case .failed(let message):
                VStack(alignment: .leading) {
                    Text(row.title)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "xmark")
                    .accessibilityLabel("failed")
            }
        }
    }
}

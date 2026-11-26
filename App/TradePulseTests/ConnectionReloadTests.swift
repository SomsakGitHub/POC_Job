import Testing
import TradeNetworking
@testable import TradePulse

/// When a screen that shows market data asks for it again after the market connection changes: when the connection
/// comes up, and only then.
@Suite(.timeLimit(.minutes(1)))
struct ConnectionReloadTests {
    @Test func aConnectionThatComesUpReloads() {
        #expect(shouldReloadOnConnection(from: .connecting, to: .connected))
        #expect(shouldReloadOnConnection(from: .reconnecting(attempt: 1), to: .connected))
        #expect(shouldReloadOnConnection(from: .reconnecting(attempt: 4), to: .connected))
        #expect(shouldReloadOnConnection(from: .stopped, to: .connected))
    }

    @Test func aConnectionThatStaysUpOrGoesDownDoesNotReload() {
        #expect(!shouldReloadOnConnection(from: .connected, to: .connected))
        #expect(!shouldReloadOnConnection(from: .connected, to: .reconnecting(attempt: 1)))
        #expect(!shouldReloadOnConnection(from: .connected, to: .connecting))
        #expect(!shouldReloadOnConnection(from: .connected, to: .stopped))
    }

    @Test func noChangeThatDoesNotEndConnectedReloads() {
        let states: [ConnectionState] = [
            .connecting, .connected, .reconnecting(attempt: 1), .reconnecting(attempt: 2), .stopped,
        ]
        #expect(states.count == 5)
        var reloads = 0
        for from in states {
            for to in states where to != .connected {
                #expect(!shouldReloadOnConnection(from: from, to: to), "\(from) to \(to)")
            }
            if shouldReloadOnConnection(from: from, to: .connected) {
                reloads += 1
            }
        }
        // Every state but .connected itself reloads when the connection comes up: four of the five.
        #expect(reloads == 4)
    }
}

import Contracts

/// The loop that sends one connection its frames, outside the hub so that a slow `send` holds up nothing else.
///
/// It sleeps until the hub signals that something is waiting or the connection has been silent for a second, keeps
/// two frames at least 5 ms apart, takes the next frame from the hub (stamped at that moment), waits out the lab's
/// latency and jitter, and sends. Spacing and silence are measured from the end of the last send on a monotonic
/// clock, so the lab's delay counts as sending: no heartbeat queues up behind a delayed frame.
///
/// It stops when the connection ends (the hub cancels it and finishes its wake-up stream, or answers `.ended`) or when
/// a `send` throws, which it reports to the hub. Every wait ends quietly on cancellation.
struct MarketFlusher: Sendable {
    /// The shortest time between two frames of one connection: updates that arrive faster are merged.
    static let spacing = Duration.milliseconds(5)
    /// How long a connection may go without a frame before it is sent an empty one, unless the hub says otherwise.
    static let idleTimeout = Duration.seconds(1)

    let hub: MarketHub
    let id: ConnectionID
    let lab: LabControls
    /// How long the connection may be silent before it gets a heartbeat.
    let idleTimeout: Duration
    let send: @Sendable (Tp_MarketFrame) async throws -> Void
    /// Signalled (by this loop's own timer as well) whenever there may be something to do.
    let wake: AsyncStream<Void>.Continuation

    func run(wakes: AsyncStream<Void>) async {
        var wakeUps = wakes.makeAsyncIterator()
        let clock = ContinuousClock()
        var lastSend = clock.now
        while !Task.isCancelled {
            let heartbeatAt = lastSend + idleTimeout
            guard let pending = await hub.hasPending(id) else { return }
            if !pending && clock.now < heartbeatAt {
                guard await waitForWakeUp(&wakeUps, until: heartbeatAt) else { return }
                continue
            }
            do {
                try await Task.sleep(until: lastSend + Self.spacing, clock: clock)
            } catch {
                return  // cancelled: the connection has ended
            }
            let settings = await lab.settings()
            let step = await hub.takeFrame(
                id, dropUpdates: settings.dropUpdates, heartbeatDue: clock.now >= heartbeatAt
            )
            switch step {
            case .ended:
                return
            case .nothing:
                continue
            case .frame(let frame):
                let delayMs = settings.extraLatencyMs + (settings.jitterMs > 0 ? Int.random(in: 0...settings.jitterMs) : 0)
                if delayMs > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(delayMs))
                    } catch {
                        return
                    }
                }
                do {
                    try await send(frame)
                } catch {
                    await hub.sendFailed(id)
                    return
                }
                lastSend = clock.now
            }
        }
    }

    /// Waits until the hub signals or `deadline` passes. Returns false when the connection has ended (the stream
    /// finished) or the task was cancelled.
    private func waitForWakeUp(
        _ wakeUps: inout AsyncStream<Void>.Iterator, until deadline: ContinuousClock.Instant
    ) async -> Bool {
        await withDiscardingTaskGroup { group in
            group.addTask { [wake] in
                // The timer wakes the loop with the same signal the hub uses; a cancelled timer stays silent.
                guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
                wake.yield()
            }
            let woke = await wakeUps.next() != nil
            group.cancelAll()
            return woke
        }
    }
}

import Contracts
import Dispatch
import Observation
import TradeCore

/// The trading state the order screens show, kept up to date from the app's own submissions, the server's order
/// events and REST account snapshots.
///
/// Every change goes through `TradingReducer.reduce`, in one main-actor method that also refreshes the resume point
/// the client reads when it reconnects. The closures handed to the client hold the store weakly, so releasing the
/// store ends its observer; the client itself still has to be stopped by its owner.
@MainActor @Observable public final class TradingStore {
    /// What the order screens draw.
    public private(set) var state: TradingState

    @ObservationIgnored private let client: TradingClient
    @ObservationIgnored private let rest: RestAPI
    @ObservationIgnored private let latency: LatencyRecorder
    @ObservationIgnored private let monotonicNs: @Sendable () -> UInt64
    @ObservationIgnored private let wallNs: @Sendable () -> Int64
    @ObservationIgnored private let resume = ResumePoint()
    @ObservationIgnored private let observer = TaskSlot()
    @ObservationIgnored private var fillTimer = FillTimer()
    /// The newest connection state the observer has seen; nil before `start()`.
    @ObservationIgnored private var connectionState: ConnectionState?

    /// A store that trades through `client`, reads the account through `rest` and records `orderSubmitToFill` into
    /// `latency`. `monotonicNs` times submit to fill; `wallNs` stamps the rows the app creates. Both are there so a
    /// test can set the clocks.
    public init(
        client: TradingClient, rest: RestAPI, latency: LatencyRecorder,
        monotonicNs: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        wallNs: @escaping @Sendable () -> Int64 = { WallClock.nowNs() }
    ) {
        state = TradingState()
        self.client = client
        self.rest = rest
        self.latency = latency
        self.monotonicNs = monotonicNs
        self.wallNs = wallNs
    }

    /// Starts trading: reads the account once for the cash and the epoch, then starts the event stream from the
    /// state's resume point (0 on a fresh launch, so the server replays its log and the order rows are rebuilt), and
    /// watches the connection: at every `.connected` the account is read again, which is how a server that was reset
    /// or restarted, and has no events of its new epoch yet, still clears the rows of the old one. A failed read is
    /// ignored; the next connection reads again. Calling it again after the client was stopped starts the stream
    /// again and keeps the rows.
    public func start() async {
        await fetchAccount(adoptEventSeq: false)
        connectionState = nil
        let resume = resume
        client.startEventStream(
            resumeFrom: { resume.current },
            onEvent: { [weak self] event in await self?.receive(event) },
            onOutOfRange: { [weak self] in await self?.recoverFromOutOfRange() }
        )
        // Subscribed after the start: a stopped client's stream would only say `.stopped` and finish. A new stream
        // yields the current state first, so a connection that is already up is not missed.
        let states = client.connection
        observer.replace(with: Task { [weak self] in
            for await connection in states {
                guard let self else { return }
                await self.connectionChanged(connection)
            }
        })
    }

    /// Shows `d` as a pending order and sends it. A refusal with a reason ends the row as rejected; a refusal with no
    /// reason this build knows, or no answer at all, makes it unknown until the event log settles it. An accepted
    /// order is moved on by its `accepted` event. A draft whose id already has a row is sent again with the same id
    /// (the server answers with what it answered first) and changes nothing else.
    public func submit(_ d: OrderDraft) async {
        fillTimer.begin(d.clientOrderId, nowNs: monotonicNs())
        apply(.localSubmitted(d, createdNs: wallNs()))
        await send(d)
    }

    /// Sends the order of an unknown row again, with the same id, so the server either answers what it decided
    /// before or takes the order now. Any other id, or a row that is not unknown, is left alone.
    public func retryUnconfirmed(clientOrderId: String) async {
        guard let row = state.orders.first(where: { $0.id == clientOrderId }), row.status == .unknown else { return }
        let draft = OrderDraft(
            clientOrderId: row.id, symbolId: row.symbolId, side: row.side, type: row.type, quantity: row.quantity,
            limitPrice: row.limitPrice)
        await send(draft)
    }

    /// Asks the server to cancel the order, only when it is open (accepted or partly filled) and the connection is
    /// up; never retried. The stream's `cancelled` event changes the row, so an error is ignored.
    public func cancel(orderId: String) async {
        guard connectionState == .connected,
            let row = state.orders.first(where: { $0.orderId == orderId }),
            row.status == .accepted || row.status == .partiallyFilled
        else { return }
        _ = try? await client.cancel(orderId: orderId)
    }

    /// Compares the state with the server's account, read now: see `Reconciliation`. A failed read is `.inFlight`.
    /// The state is never changed.
    public func reconcile() async -> Reconciliation {
        guard let account = try? await rest.account() else { return .inFlight }
        return Reconciliation.compare(state, with: account)
    }

    // MARK: Applying actions

    /// The one place the state changes. Returns whether the reducer moved the pair `(epoch, lastEventSeq)`, which is
    /// how a taken event is told from a repeated or stale one (the number alone can stay the same across epochs).
    @discardableResult
    private func apply(_ action: TradingAction) -> Bool {
        let before = (state.epoch, state.lastEventSeq)
        TradingReducer.reduce(&state, action)
        resume.set(seq: state.lastEventSeq, epoch: state.epoch)
        return before != (state.epoch, state.lastEventSeq)
    }

    /// One event of the stream. The first fill of an order this app submitted, in this run, records the time from
    /// its submit.
    private func receive(_ event: Tp_OrderEvent) {
        guard apply(.event(event)), case .fill(let fill)? = event.event else { return }
        let now = monotonicNs()
        guard let row = state.orders.first(where: { $0.orderId == fill.orderID }),
            let elapsed = fillTimer.finish(row.id, nowNs: now)
        else { return }
        latency.record(.orderSubmitToFill, nanos: elapsed)
    }

    /// Sends `draft` and applies what the answer says about its row.
    private func send(_ draft: OrderDraft) async {
        let id = draft.clientOrderId
        do {
            let result = try await client.submit(draft)
            guard !result.accepted else { return }
            if let reason = result.rejectReason {
                fillTimer.forget(id)
                apply(.submitRejected(clientOrderId: id, reason: reason))
            } else {
                apply(.submitUnconfirmed(clientOrderId: id))
            }
        } catch {
            apply(.submitUnconfirmed(clientOrderId: id))
        }
    }

    private func connectionChanged(_ connection: ConnectionState) async {
        connectionState = connection
        if connection == .connected { await fetchAccount(adoptEventSeq: false) }
    }

    /// The server no longer keeps the events the state would resume from: start over from its account. When the
    /// read fails the cleared state stays; the next connection reads the account and asks again.
    private func recoverFromOutOfRange() async {
        apply(.clear)
        await fetchAccount(adoptEventSeq: true)
    }

    /// Reads the account and applies it, unless the answer would straddle an epoch change: when the state's epoch
    /// changed while the call was out and the answer's epoch is not the state's epoch now, the answer belongs to the
    /// epoch the state has left, and applying it would take the state back and wipe the new epoch's rows. A failed
    /// read changes nothing.
    private func fetchAccount(adoptEventSeq: Bool) async {
        let epochBefore = resume.current.epoch
        guard let account = try? await rest.account() else { return }
        let epochNow = state.epoch
        if epochNow != epochBefore, account.epoch != epochNow { return }
        apply(.account(account, adoptEventSeq: adoptEventSeq))
    }
}

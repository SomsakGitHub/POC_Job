import Testing
import TradeCore
@testable import ExchangeCore

/// A distinct payload per number, so a test can tell which append a record came from.
private func payload(_ n: Int) -> OrderEventPayload {
    .rejected(clientOrderId: "c\(n)", reason: .invalidLot)
}

/// A log of `capacity` with `count` appends, the n-th (from 1) carrying `payload(n)` and timestamp `n * 10`.
private func filledLog(capacity: Int, count: Int) -> EventLog {
    var log = EventLog(capacity: capacity)
    for n in stride(from: 1, through: count, by: 1) {
        _ = log.append(payload(n), epoch: "E", tsNs: Int64(n) * 10)
    }
    return log
}

@Suite struct EventLogTests {
    @Test func appendAssignsContiguousSeq() {
        var log = EventLog()
        #expect(log.lastSeq == 0)
        var seqs: [UInt64] = []
        for n in 1...5 {
            let record = log.append(payload(n), epoch: "E1", tsNs: Int64(n) * 10)
            #expect(record == OrderEventRecord(seq: UInt64(n), epoch: "E1", tsNs: Int64(n) * 10, payload: payload(n)))
            seqs.append(record.seq)
        }
        #expect(seqs == [1, 2, 3, 4, 5])
        #expect(log.lastSeq == 5)
    }

    @Test func eventsAfterSeqReturnsTail() throws {
        let log = filledLog(capacity: 100, count: 6)
        let tail = try log.events(after: 3)
        #expect(tail.map(\.seq) == [4, 5, 6])
        #expect(tail.map(\.payload) == [payload(4), payload(5), payload(6)])
        #expect(tail.map(\.tsNs) == [40, 50, 60])
        let all = try log.events(after: 0)
        #expect(all.map(\.seq) == [1, 2, 3, 4, 5, 6])
    }

    @Test func tooOldThrowsOutOfRange() throws {
        let log = filledLog(capacity: 10, count: 25)
        #expect(throws: EventLogError.outOfRange(oldestRetained: 16)) { try log.events(after: 2) }
        #expect(throws: EventLogError.outOfRange(oldestRetained: 16)) { try log.events(after: 14) }
        #expect(throws: EventLogError.outOfRange(oldestRetained: 16)) { try log.events(after: 0) }
        let fromOldest = try log.events(after: 15)
        #expect(fromOldest.map(\.seq) == Array(16...25))
        #expect(fromOldest.map(\.payload) == (16...25).map(payload))
    }

    @Test func seqContinuesAfterRingWraps() throws {
        var log = filledLog(capacity: 3, count: 7)
        let record = log.append(payload(8), epoch: "E", tsNs: 80)
        #expect(record.seq == 8)
        #expect(log.lastSeq == 8)
        let tail = try log.events(after: 5)
        #expect(tail.map(\.seq) == [6, 7, 8])
        #expect(tail.map(\.payload) == [payload(6), payload(7), payload(8)])
    }

    @Test func afterAtOrBeyondLastSeqIsEmpty() throws {
        let empty = EventLog(capacity: 4)
        #expect(try empty.events(after: 0).isEmpty)
        #expect(try empty.events(after: 9).isEmpty)
        let wrapped = filledLog(capacity: 4, count: 10)
        #expect(try wrapped.events(after: 10).isEmpty)
        #expect(try wrapped.events(after: 11).isEmpty)
        #expect(try wrapped.events(after: .max).isEmpty)
        #expect(try wrapped.events(after: 9).map(\.seq) == [10])
    }

    @Test(arguments: [0, -1, Int.min])
    func capacityBelowOneClampsToOne(capacity: Int) throws {
        let log = filledLog(capacity: capacity, count: 3)
        #expect(log.lastSeq == 3)
        #expect(try log.events(after: 2).map(\.payload) == [payload(3)])
        #expect(throws: EventLogError.outOfRange(oldestRetained: 3)) { try log.events(after: 1) }
    }
}

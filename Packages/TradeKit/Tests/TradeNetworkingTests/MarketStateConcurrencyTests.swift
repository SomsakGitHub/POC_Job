import Contracts
import Testing
import TradeCore
import TradeNetworking

extension MarketStateTests {
    /// One task applies frames while others read, as the feed and the screen do. A snapshot is one value copied under
    /// the lock, so a reader never sees two updates mixed: every field of every snapshot it reads is the one update's,
    /// and the version never goes back. The counts are exact whatever the interleaving, so the test cannot flake.
    ///
    /// The readers wait for the first frame, so that every read finds a snapshot to check. A reader that found none
    /// would have checked nothing, and the test would pass without testing anything; the number of snapshots checked
    /// is asserted for that reason.
    @Test func concurrentAppliesAndReadsNeverTear() async {
        let latency = LatencyRecorder()
        let state = MarketState(latency: latency)
        let frames = 3_000
        let readers = 3
        let readsPerReader = 20_000

        let report = await withTaskGroup(of: ReaderReport.self) { group in
            group.addTask {
                for number in 1...frames {
                    let update = symbolUpdate(seq: UInt64(number), last: 3_000 + Int64(number))
                    let frame = marketFrame(sendNs: 1_000, frameSeq: UInt64(number), updates: [update])
                    _ = state.apply(frame: frame, receivedAtNs: Int64(number))
                }
                return ReaderReport()
            }
            for _ in 0..<readers {
                group.addTask {
                    while state.version == 0 {
                        await Task.yield()
                    }
                    var report = ReaderReport()
                    var newestVersion: UInt64 = 0
                    for _ in 0..<readsPerReader {
                        let version = state.version
                        if version < newestVersion { report.problems += 1 }
                        newestVersion = version
                        guard let snapshot = state.snapshot(1) else {
                            report.problems += 1
                            continue
                        }
                        report.checked += 1
                        // One frame, one update, one version: the snapshot, read after the version, is at least as new.
                        if snapshot.seq < version || !isFromOneUpdate(snapshot) { report.problems += 1 }
                    }
                    return report
                }
            }
            var total = ReaderReport()
            for await each in group {
                total.problems += each.problems
                total.checked += each.checked
            }
            return total
        }

        #expect(report.problems == 0)
        #expect(report.checked == readers * readsPerReader)
        #expect(state.version == UInt64(frames))
        #expect(state.snapshot(1)?.seq == UInt64(frames))
        #expect(state.snapshot(1)?.gapCount == 0)
        #expect(state.lastFrameAtNs == Int64(frames))
        #expect(latency.summary(.tickToApp).count == frames)
        #expect(latency.summary(.tickToApplied).count == frames)
    }
}

/// What one task found: the snapshots it read and checked, and how many of its observations were wrong.
private struct ReaderReport: Sendable {
    var problems = 0
    var checked = 0
}

/// Whether every field of `snapshot` is what `symbolUpdate(seq:last:)` made for its `seq` with `last = 3_000 + seq`.
private func isFromOneUpdate(_ snapshot: SymbolSnapshot) -> Bool {
    let number = Int64(truncatingIfNeeded: snapshot.seq)
    let last = 3_000 + number
    return snapshot.last.satang == last
        && snapshot.bid.satang == last - 25
        && snapshot.ask.satang == last + 25
        && snapshot.bidQty == 1_000 + number
        && snapshot.askQty == 2_000 + number
        && snapshot.dayVolume == 10_000 + number
        && snapshot.candle1s.close.satang == last
        && snapshot.candle1m.close.satang == last
        && snapshot.candle5m.close.satang == last
        && snapshot.appliedAtNs == number
}

import Testing
import TradeCore

private let millisecond: Int64 = 1_000_000

/// Feeds `estimator` a ping that left the client at `send`, took `rtt` ns to come back, and was answered by a
/// server whose clock is `offset` ns ahead of the client's. The server stamps halfway through the round trip, so for
/// an even `rtt` the offset the estimator recovers is exactly `offset`.
private func add(
    to estimator: inout ClockOffsetEstimator, sendAt send: Int64, rtt: Int64, offset: Int64
) {
    estimator.add(clientSendNs: send, serverNs: send + rtt / 2 + offset, clientRecvNs: send + rtt)
}

struct ClockOffsetEstimatorTests {
    @Test func withoutSamplesTheOffsetIsZeroAndThereIsNoRoundTrip() {
        let estimator = ClockOffsetEstimator()
        #expect(estimator.offsetNs == 0)
        #expect(estimator.bestRttNs == nil)
    }

    /// The brief's example: a 10 ms round trip and then a 2 ms one, both showing the server 5 ms ahead.
    @Test func theBriefsExample() {
        var estimator = ClockOffsetEstimator()
        add(to: &estimator, sendAt: 1_000_000_000, rtt: 10 * millisecond, offset: 5 * millisecond)
        add(to: &estimator, sendAt: 2_000_000_000, rtt: 2 * millisecond, offset: 5 * millisecond)
        #expect(estimator.offsetNs == 5_000_000)
        #expect(estimator.bestRttNs == 2_000_000)
    }

    @Test func aSingleSampleIsItsOwnBest() {
        var estimator = ClockOffsetEstimator()
        add(to: &estimator, sendAt: 500, rtt: 8 * millisecond, offset: -3 * millisecond)
        #expect(estimator.offsetNs == -3_000_000)
        #expect(estimator.bestRttNs == 8_000_000)
    }

    /// The report comes from the sample with the smallest round trip, because the less time a ping spent on the wire,
    /// the less room there was for an uneven path to skew the midpoint. A slow sample with another offset does not
    /// move it, whether it arrives before or after the fast one.
    @Test func theSmallestRoundTripWinsWhicheverOrderTheyArriveIn() {
        var fastFirst = ClockOffsetEstimator()
        add(to: &fastFirst, sendAt: 1_000_000_000, rtt: 2 * millisecond, offset: 5 * millisecond)
        add(to: &fastFirst, sendAt: 2_000_000_000, rtt: 40 * millisecond, offset: 9 * millisecond)
        add(to: &fastFirst, sendAt: 3_000_000_000, rtt: 12 * millisecond, offset: 1 * millisecond)

        var fastLast = ClockOffsetEstimator()
        add(to: &fastLast, sendAt: 2_000_000_000, rtt: 40 * millisecond, offset: 9 * millisecond)
        add(to: &fastLast, sendAt: 3_000_000_000, rtt: 12 * millisecond, offset: 1 * millisecond)
        add(to: &fastLast, sendAt: 1_000_000_000, rtt: 2 * millisecond, offset: 5 * millisecond)

        #expect(fastFirst.offsetNs == 5_000_000)
        #expect(fastFirst.bestRttNs == 2_000_000)
        #expect(fastLast.offsetNs == 5_000_000)
        #expect(fastLast.bestRttNs == 2_000_000)
    }

    /// There is no window: a very good early sample is still the best long after, however many slower ones follow.
    @Test func anOldBestSampleIsNeverAgedOut() {
        var estimator = ClockOffsetEstimator()
        add(to: &estimator, sendAt: 0, rtt: 1 * millisecond, offset: 7 * millisecond)
        for i in 1...1000 {
            add(to: &estimator, sendAt: Int64(i) * 1_000_000_000, rtt: 5 * millisecond, offset: 2 * millisecond)
        }
        #expect(estimator.offsetNs == 7_000_000)
        #expect(estimator.bestRttNs == 1_000_000)
    }

    /// Two samples with the same round trip: the newer one is reported, since it is the fresher reading of a
    /// clock that drifts.
    @Test func anEqualRoundTripGoesToTheNewerSample() {
        var estimator = ClockOffsetEstimator()
        add(to: &estimator, sendAt: 1_000_000_000, rtt: 4 * millisecond, offset: 5 * millisecond)
        add(to: &estimator, sendAt: 2_000_000_000, rtt: 4 * millisecond, offset: 6 * millisecond)
        #expect(estimator.offsetNs == 6_000_000)
        #expect(estimator.bestRttNs == 4_000_000)
    }

    /// The server stamps halfway through the round trip: the midpoint is `send + rtt / 2`, and an odd round trip
    /// rounds that down, to the send side, by half a nanosecond. 0 -> 3 has its midpoint at 1 (not 2), so a server
    /// stamp of 10 means an offset of 9. For a negative offset the same rounding applies.
    @Test(arguments: [
        // (send, server, recv, expected offset, expected rtt)
        (0, 10, 3, 9, 3),
        (0, 10, 4, 8, 4),
        (0, 10, 1, 10, 1),
        (1_000, 500, 1_004, -502, 4),
        (1_000, 500, 1_005, -502, 5),
        (1_000, 1_000, 1_000, 0, 0),
    ] as [(Int64, Int64, Int64, Int64, Int64)])
    func anOddRoundTripPutsTheMidpointHalfANanosecondEarly(
        send: Int64, server: Int64, recv: Int64, offset: Int64, rtt: Int64
    ) {
        var estimator = ClockOffsetEstimator()
        estimator.add(clientSendNs: send, serverNs: server, clientRecvNs: recv)
        #expect(estimator.offsetNs == offset)
        #expect(estimator.bestRttNs == rtt)
    }

    /// A reply that arrives "before" the request left means the client clock stepped backwards in between: the sample
    /// says nothing true, so it is ignored, not counted as a very fast round trip.
    @Test func aNegativeRoundTripIsIgnored() {
        var estimator = ClockOffsetEstimator()
        add(to: &estimator, sendAt: 1_000_000_000, rtt: 6 * millisecond, offset: 5 * millisecond)
        estimator.add(clientSendNs: 5_000, serverNs: 123, clientRecvNs: 4_999)
        #expect(estimator.offsetNs == 5_000_000)
        #expect(estimator.bestRttNs == 6_000_000)
    }

    @Test func onlyNegativeRoundTripsLeaveTheEstimatorEmpty() {
        var estimator = ClockOffsetEstimator()
        estimator.add(clientSendNs: 5_000, serverNs: 123, clientRecvNs: 4_999)
        estimator.add(clientSendNs: .max, serverNs: 0, clientRecvNs: .min)
        estimator.add(clientSendNs: 0, serverNs: 0, clientRecvNs: .min)
        #expect(estimator.offsetNs == 0)
        #expect(estimator.bestRttNs == nil)
    }

    /// A round trip of zero is a real (if coarse-clocked) sample, and the best possible one.
    @Test func aZeroRoundTripIsAccepted() {
        var estimator = ClockOffsetEstimator()
        add(to: &estimator, sendAt: 1_000, rtt: 2 * millisecond, offset: 1 * millisecond)
        estimator.add(clientSendNs: 5_000, serverNs: 5_500, clientRecvNs: 5_000)
        #expect(estimator.bestRttNs == 0)
        #expect(estimator.offsetNs == 500)
    }

    /// Every difference is formed wide enough that no `Int64` input can overflow, and what comes out is clamped to
    /// the `Int64` range: a round trip of 2^64 - 1 reads as `Int64.max`, an offset of 2^63 as `Int64.max`, and
    /// -(2^64 - 1) as `Int64.min`.
    @Test(arguments: [
        // (send, server, recv, expected offset, expected rtt)
        (Int64.min, Int64.max, Int64.max, Int64.max, Int64.max),
        (Int64.min, 0, Int64.max, 1, Int64.max),
        (Int64.max, Int64.min, Int64.max, Int64.min, 0),
        (Int64.min, Int64.min, Int64.min, 0, 0),
        (Int64.max, Int64.max, Int64.max, 0, 0),
        (0, Int64.max, 0, Int64.max, 0),
        (0, Int64.min, 0, Int64.min, 0),
    ] as [(Int64, Int64, Int64, Int64, Int64)])
    func extremeInputsDoNotOverflow(send: Int64, server: Int64, recv: Int64, offset: Int64, rtt: Int64) {
        var estimator = ClockOffsetEstimator()
        estimator.add(clientSendNs: send, serverNs: server, clientRecvNs: recv)
        #expect(estimator.offsetNs == offset)
        #expect(estimator.bestRttNs == rtt)
    }

    /// Two round trips that are both wider than `Int64` can say still compare by their true widths, not by what they
    /// read back as (both `Int64.max`): the narrower one stays the best however it arrived. The narrow one here is
    /// 2^64 - 6 wide with its midpoint at 2, so its offset is 20 - 2 = 18; the wide one is 2^64 - 1 wide with its
    /// midpoint at -1, so its offset would be 10 + 1 = 11, and a tie by clamped width would hand it the win.
    @Test func roundTripsBeyondInt64StillCompareByTheirTrueWidth() {
        var estimator = ClockOffsetEstimator()
        estimator.add(clientSendNs: .min + 5, serverNs: 20, clientRecvNs: .max)
        estimator.add(clientSendNs: .min, serverNs: 10, clientRecvNs: .max)
        #expect(estimator.bestRttNs == .max)
        #expect(estimator.offsetNs == 18)
    }
}

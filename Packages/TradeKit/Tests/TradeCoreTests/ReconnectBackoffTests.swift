import Testing
import TradeCore

struct ReconnectBackoffTests {
    // MARK: The reference table (defaults: 250 ms base, 10 s cap)

    /// With the full delay (jitter 1.0): 250 ms doubling per attempt until it reaches the 10 s cap, exactly.
    @Test(arguments: [
        (0, Duration.milliseconds(250)),
        (1, .milliseconds(500)),
        (2, .seconds(1)),
        (3, .seconds(2)),
        (4, .seconds(4)),
        (5, .seconds(8)),
        (6, .seconds(10)),
        (7, .seconds(10)),
    ] as [(Int, Duration)])
    func fullJitterDoublesUntilTheCap(attempt: Int, expected: Duration) {
        #expect(ReconnectBackoff().delay(attempt: attempt, jitter: 1.0) == expected)
    }

    /// Jitter 0.0 halves every one of those, exactly (the capped 10 s halves to 5 s).
    @Test(arguments: [
        (0, Duration.milliseconds(125)),
        (1, .milliseconds(250)),
        (2, .milliseconds(500)),
        (3, .seconds(1)),
        (4, .seconds(2)),
        (5, .seconds(4)),
        (6, .seconds(5)),
        (7, .seconds(5)),
    ] as [(Int, Duration)])
    func zeroJitterHalvesEachDelay(attempt: Int, expected: Duration) {
        #expect(ReconnectBackoff().delay(attempt: attempt, jitter: 0.0) == expected)
    }

    /// The scale is 0.5 + 0.5 * jitter, so jitter 0.5 is three quarters and jitter 0.25 five eighths, still exact.
    @Test(arguments: [
        (0, 0.5, Duration.nanoseconds(187_500_000)),
        (1, 0.5, .nanoseconds(375_000_000)),
        (6, 0.5, .milliseconds(7_500)),
        (0, 0.25, .nanoseconds(156_250_000)),
        (2, 0.75, .milliseconds(875)),
    ] as [(Int, Double, Duration)])
    func jitterScalesTheDelayBetweenHalfAndWhole(attempt: Int, jitter: Double, expected: Duration) {
        #expect(ReconnectBackoff().delay(attempt: attempt, jitter: jitter) == expected)
    }

    // MARK: Attempts out of range

    /// The doubling stops at the cap, so an enormous attempt number is the cap, not an overflow.
    @Test(arguments: [64, 65, 127, 128, 1000, 1_000_000, Int.max] as [Int])
    func aHugeAttemptIsTheCap(attempt: Int) {
        #expect(ReconnectBackoff().delay(attempt: attempt, jitter: 1.0) == .seconds(10))
        #expect(ReconnectBackoff().delay(attempt: attempt, jitter: 0.0) == .seconds(5))
    }

    /// An attempt below 0 is a counting mistake, not a reason to wait less than the first delay: it is attempt 0.
    @Test(arguments: [-1, -2, -1000, Int.min] as [Int])
    func aNegativeAttemptCountsAsTheFirst(attempt: Int) {
        #expect(ReconnectBackoff().delay(attempt: attempt, jitter: 1.0) == .milliseconds(250))
        #expect(ReconnectBackoff().delay(attempt: attempt, jitter: 0.0) == .milliseconds(125))
    }

    // MARK: Jitter out of range

    /// Jitter is a fraction in 0...1; outside it, it is clamped to the nearest end.
    @Test(arguments: [-0.0001, -1, -1e300, -Double.infinity] as [Double])
    func aJitterBelowZeroIsZero(jitter: Double) {
        #expect(ReconnectBackoff().delay(attempt: 2, jitter: jitter) == .milliseconds(500))
    }

    @Test(arguments: [1.0001, 2, 1e300, Double.infinity] as [Double])
    func aJitterAboveOneIsOne(jitter: Double) {
        #expect(ReconnectBackoff().delay(attempt: 2, jitter: jitter) == .seconds(1))
    }

    /// A NaN jitter (a broken random source) counts as 1.0, the full delay: waiting the whole time is the safe
    /// side of not knowing.
    @Test func aNaNJitterCountsAsOne() {
        for attempt in [0, 3, 6, Int.max] {
            #expect(
                ReconnectBackoff().delay(attempt: attempt, jitter: .nan)
                    == ReconnectBackoff().delay(attempt: attempt, jitter: 1.0)
            )
        }
    }

    /// Jitter counts to the millionth, so a jitter below half a millionth is no jitter at all: 4e-7 is 0.
    @Test func jitterCountsToTheMillionth() {
        let backoff = ReconnectBackoff()
        #expect(backoff.delay(attempt: 0, jitter: 4e-7) == backoff.delay(attempt: 0, jitter: 0))
        #expect(backoff.delay(attempt: 0, jitter: 6e-7) == .nanoseconds(125_000_125))
    }

    // MARK: Custom base and cap

    @Test func baseAndCapAreWhateverTheyWereGiven() {
        let backoff = ReconnectBackoff(base: .seconds(1), cap: .seconds(30))
        let delays = (0...7).map { backoff.delay(attempt: $0, jitter: 1.0) }
        #expect(delays == [
            .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30), .seconds(30),
        ])
    }

    /// The delay is rounded down to a whole nanosecond: half of 3 ns is 1 ns.
    @Test func theDelayIsWholeNanoseconds() {
        let backoff = ReconnectBackoff(base: .nanoseconds(3), cap: .seconds(1))
        #expect(backoff.delay(attempt: 0, jitter: 0) == .nanoseconds(1))
        #expect(backoff.delay(attempt: 0, jitter: 1) == .nanoseconds(3))
        #expect(backoff.delay(attempt: 1, jitter: 0) == .nanoseconds(3))
    }

    /// A cap below the base wins from the first attempt: the delay is never above the cap.
    @Test func aCapBelowTheBaseIsTheDelayFromTheStart() {
        let backoff = ReconnectBackoff(base: .seconds(10), cap: .seconds(1))
        #expect(backoff.delay(attempt: 0, jitter: 1.0) == .seconds(1))
        #expect(backoff.delay(attempt: 5, jitter: 1.0) == .seconds(1))
        #expect(backoff.delay(attempt: 5, jitter: 0.0) == .milliseconds(500))
    }

    @Test func aCapEqualToTheBaseNeverGrows() {
        let backoff = ReconnectBackoff(base: .seconds(2), cap: .seconds(2))
        #expect(backoff.delay(attempt: 0, jitter: 1.0) == .seconds(2))
        #expect(backoff.delay(attempt: 9, jitter: 1.0) == .seconds(2))
    }

    // MARK: Zero and negative durations

    /// A base or a cap that is zero or negative leaves nothing to wait: the delay is exactly `.zero` for every
    /// attempt and jitter, and a negative duration is never returned. The same goes for one under a nanosecond,
    /// the resolution the delay is worked out in. None of them can trap or hang on a huge attempt.
    @Test(arguments: [
        (Duration.zero, Duration.seconds(10)),
        (.milliseconds(-250), .seconds(10)),
        (.nanoseconds(-1), .seconds(10)),
        (Duration(secondsComponent: Int64.min, attosecondsComponent: 0), .seconds(10)),
        (Duration(secondsComponent: 0, attosecondsComponent: 999_999_999), .seconds(10)),
        (.milliseconds(250), .zero),
        (.milliseconds(250), .milliseconds(-1)),
        (.milliseconds(250), Duration(secondsComponent: Int64.min, attosecondsComponent: 0)),
        (.milliseconds(250), Duration(secondsComponent: 0, attosecondsComponent: 999_999_999)),
        (.zero, .zero),
        (.nanoseconds(-1), .nanoseconds(-1)),
    ] as [(Duration, Duration)])
    func aZeroOrNegativeBaseOrCapMeansNoWait(base: Duration, cap: Duration) {
        let backoff = ReconnectBackoff(base: base, cap: cap)
        for attempt in [Int.min, -1, 0, 1, 6, 1000, Int.max] {
            for jitter in [-1.0, 0.0, 0.5, 1.0, 2.0, .nan, .infinity] {
                #expect(backoff.delay(attempt: attempt, jitter: jitter) == .zero)
            }
        }
    }

    /// A base and a cap as large as a `Duration` gets (about 9.2e18 s) are still worked out without overflow, and the
    /// delay stays within 0 and the cap.
    @Test func enormousDurationsDoNotOverflow() {
        let largest = Duration(secondsComponent: Int64.max, attosecondsComponent: 999_999_999_999_999_999)
        let backoff = ReconnectBackoff(base: largest, cap: largest)
        for attempt in [0, 1, 70, Int.max] {
            for jitter in [0.0, 0.5, 1.0] {
                let delay = backoff.delay(attempt: attempt, jitter: jitter)
                #expect(delay > .zero && delay <= largest)
            }
        }
        let doubling = ReconnectBackoff(base: .seconds(Int64.max / 2 + 1), cap: .seconds(Int64.max))
        #expect(doubling.delay(attempt: 1, jitter: 1.0) == .seconds(Int64.max))
        #expect(doubling.delay(attempt: 0, jitter: 1.0) == .seconds(Int64.max / 2 + 1))
    }

    // MARK: Properties over a sweep

    /// For every attempt and every jitter in steps of 0.05: the delay is never negative and never above the cap; it
    /// never shrinks as attempts grow or as jitter grows; and it lies between half of, and all of, the full delay.
    @Test func delayIsBoundedAndOrderedOverAFullSweep() {
        let backoff = ReconnectBackoff()
        let attempts = Array(-3...100) + [1000, Int.max]
        let jitters = (0...20).map { Double($0) / 20 }
        var violations: [String] = []
        for (i, attempt) in attempts.enumerated() {
            for (j, jitter) in jitters.enumerated() {
                let delay = backoff.delay(attempt: attempt, jitter: jitter)
                let full = backoff.delay(attempt: attempt, jitter: 1.0)
                if delay < .zero || delay > .seconds(10) {
                    violations.append("attempt \(attempt) jitter \(jitter): \(delay) outside 0...cap")
                }
                if delay > full || delay * 2 < full {
                    violations.append("attempt \(attempt) jitter \(jitter): \(delay) outside half...full of \(full)")
                }
                if i + 1 < attempts.count, backoff.delay(attempt: attempts[i + 1], jitter: jitter) < delay {
                    violations.append("attempt \(attempt) jitter \(jitter): shrank at the next attempt")
                }
                if j + 1 < jitters.count, backoff.delay(attempt: attempt, jitter: jitters[j + 1]) < delay {
                    violations.append("attempt \(attempt) jitter \(jitter): shrank at the next jitter")
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.prefix(5))")
    }
}

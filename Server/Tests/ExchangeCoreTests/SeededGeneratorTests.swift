import Testing
@testable import ExchangeCore

private func requireSendable<T: Sendable>(_: T.Type) {}

struct SeededGeneratorTests {
    /// The first three outputs of SplitMix64 for three seeds. The values come from an independent implementation
    /// (a few lines of Python written from the algorithm's definition, not from this code), so they pin the algorithm
    /// itself: the increment, both multipliers and the three shifts. Seed `UInt64.max` makes the first increment wrap.
    @Test(arguments: [
        (UInt64(0), [0xE220_A839_7B1D_CDAF, 0x6E78_9E6A_A1B9_65F4, 0x06C4_5D18_8009_454F]),
        (UInt64(42), [0xBDD7_3226_2FEB_6E95, 0x28EF_E333_B266_F103, 0x4752_6757_130F_9F52]),
        (UInt64.max, [0xE4D9_7177_1B65_2C20, 0xE99F_F867_DBF6_82C9, 0x382F_F84C_B272_81E9]),
    ] as [(UInt64, [UInt64])])
    func firstThreeOutputsMatchSplitMix64(seed: UInt64, expected: [UInt64]) {
        var generator = SeededGenerator(seed: seed)

        #expect([generator.next(), generator.next(), generator.next()] == expected)
    }

    @Test func sameSeedGivesTheSameStreamAndDifferentSeedsDiffer() {
        var first = SeededGenerator(seed: 7)
        var second = SeededGenerator(seed: 7)
        var other = SeededGenerator(seed: 8)

        let a = (0..<20).map { _ in first.next() }
        let b = (0..<20).map { _ in second.next() }
        let c = (0..<20).map { _ in other.next() }

        #expect(a == b)
        #expect(a != c)
    }

    /// The numbered streams of one seed (one per symbol) are unrelated: none is a shifted copy of another. Deriving a
    /// stream by adding multiples of the generator's own increment to the seed would give exactly that, since the
    /// state moves by the increment on every output (seed 0, streams 1 and 2 would be one sequence, one output
    /// apart). Seed 0 is where the naive derivation is at its worst, so it is in the table.
    @Test(arguments: [UInt64(0), 1, 42, .max] as [UInt64])
    func streamsOfOneSeedAreNotShiftedCopiesOfEachOther(seed: UInt64) {
        let streams = (UInt32(0)..<12).map { stream -> [UInt64] in
            var generator = SeededGenerator(seed: seed, stream: stream)
            return (0..<64).map { _ in generator.next() }
        }
        var shifted: [String] = []

        for (i, a) in streams.enumerated() {
            for (j, b) in streams.enumerated() where i != j {
                for shift in 0..<16 where Array(a.dropFirst(shift).prefix(32)) == Array(b.prefix(32)) {
                    shifted.append("stream \(j) is stream \(i) moved on by \(shift)")
                }
            }
        }

        #expect(shifted.isEmpty, "\(shifted)")
        #expect(Set(streams.map { $0[0] }).count == streams.count)
    }

    @Test func aStreamIsAFunctionOfItsSeedAndItsNumberOnly() {
        func outputs(_ seed: UInt64, _ stream: UInt32) -> [UInt64] {
            var generator = SeededGenerator(seed: seed, stream: stream)
            return (0..<20).map { _ in generator.next() }
        }

        #expect(outputs(5, 3) == outputs(5, 3))
        #expect(outputs(5, 3) != outputs(5, 4))
        #expect(outputs(5, 3) != outputs(6, 3))
    }

    /// It is a value type: a copy continues the stream on its own, so handing a generator to a function by value
    /// cannot disturb the original.
    @Test func aCopyContinuesTheStreamIndependently() {
        var original = SeededGenerator(seed: 99)
        _ = original.next()
        var copy = original

        let fromCopy = (0..<5).map { _ in copy.next() }
        let fromOriginal = (0..<5).map { _ in original.next() }

        #expect(fromCopy == fromOriginal)
    }

    @Test func isARandomNumberGeneratorAndSendable() {
        var generator = SeededGenerator(seed: 1)
        let roll = Int.random(in: 0..<10, using: &generator)

        #expect((0..<10).contains(roll))
        requireSendable(SeededGenerator.self)
    }
}

/// The draws the simulator builds on. Each is checked on a long seeded run, so the statistics are deterministic:
/// nothing here can flake.
struct SeededGeneratorDrawTests {
    private let draws = 100_000

    @Test func unitStaysInTheHalfOpenIntervalAndIsUniform() {
        var generator = SeededGenerator(seed: 11)
        var smallest = 1.0
        var largest = 0.0
        var sum = 0.0

        for _ in 0..<draws {
            let value = generator.unit()
            smallest = min(smallest, value)
            largest = max(largest, value)
            sum += value
        }

        #expect(smallest >= 0)
        #expect(largest < 1)
        #expect(smallest < 0.001 && largest > 0.999)
        #expect(abs(sum / Double(draws) - 0.5) < 0.01)
    }

    /// `below(n)` lands in `0..<n` and reaches every value; a bound that is not positive has nothing to choose from
    /// and answers 0 rather than trapping.
    @Test(arguments: [1, 2, 3, 7, 100])
    func belowCoversTheWholeRange(bound: Int) {
        var generator = SeededGenerator(seed: UInt64(bound))
        var seen = Set<Int>()
        var allInRange = true

        for _ in 0..<5_000 {
            let value = generator.below(bound)
            allInRange = allInRange && (0..<bound).contains(value)
            seen.insert(value)
        }

        #expect(allInRange)
        #expect(seen.count == bound)
    }

    @Test(arguments: [0, -1, Int.min])
    func belowAnswersZeroWhenThereIsNothingToChooseFrom(bound: Int) {
        var generator = SeededGenerator(seed: 3)

        #expect(generator.below(bound) == 0)
    }

    @Test func exponentialIsNonNegativeFiniteWithUnitMean() {
        var generator = SeededGenerator(seed: 12)
        var sum = 0.0
        var allValid = true

        for _ in 0..<draws {
            let value = generator.exponential()
            allValid = allValid && value >= 0 && value.isFinite
            sum += value
        }

        #expect(allValid)
        #expect(abs(sum / Double(draws) - 1) < 0.03)
    }

    @Test func normalIsFiniteWithZeroMeanAndUnitVariance() {
        var generator = SeededGenerator(seed: 13)
        var sum = 0.0
        var squares = 0.0
        var allFinite = true

        for _ in 0..<draws {
            let value = generator.normal()
            allFinite = allFinite && value.isFinite
            sum += value
            squares += value * value
        }
        let mean = sum / Double(draws)

        #expect(allFinite)
        #expect(abs(mean) < 0.03)
        #expect(abs(squares / Double(draws) - mean * mean - 1) < 0.05)
    }
}

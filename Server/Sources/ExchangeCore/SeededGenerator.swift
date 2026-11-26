import Foundation

/// A deterministic random number generator: SplitMix64.
///
/// Each `next()` adds the golden-ratio constant `0x9E3779B97F4A7C15` to the state, then scrambles it:
/// `z = (z ^ z >> 30) * 0xBF58476D1CE4E5B9`, `z = (z ^ z >> 27) * 0x94D049BB133111EB`, and the output is `z ^ z >> 31`.
/// Every operation wraps at 64 bits. Any seed, zero included, gives a full-period stream, and seeds that differ only a
/// little give unrelated streams.
///
/// A value type, so a copy continues the stream on its own. It reads no clock and no global source of randomness: the
/// seed fixes every number it will ever produce, which is what makes the simulated market reproducible.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The draws the simulator is built on. They are written out here instead of taken from the standard library's
/// `random(in:using:)` so that a seed means the same numbers on every toolchain.
extension SeededGenerator {
    /// The generator of numbered stream `stream` of `seed`: one stream for each symbol, so the symbols walk on their
    /// own random numbers. The state of SplitMix64 moves by the same increment on every output, so a stream seeded with
    /// `seed + stream * increment` (or an exclusive-or that mostly acts like it) is the stream of another number moved
    /// on by a few outputs: every symbol would draw nearly the same numbers. So the stream number is spread by a large
    /// odd multiplier and the result is mixed through one output of the generator first, which starts each stream at
    /// an unrelated place in the cycle.
    init(seed: UInt64, stream: UInt32) {
        var mixer = SeededGenerator(seed: seed ^ (UInt64(stream) &* 0xD1B5_4A32_D192_ED03))
        self.init(seed: mixer.next())
    }

    /// Uniform in `[0, 1)`: the top 53 bits of one output, so every value is exactly representable.
    mutating func unit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    /// Uniform in `0..<bound`: the high half of a 64 x 64-bit product. The bias is below `bound / 2^64`, far under
    /// anything a simulation can see. A bound that is not positive has nothing to choose from and gives 0.
    mutating func below(_ bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(next().multipliedFullWidth(by: UInt64(bound)).high)
    }

    /// Exponential with mean 1: `-ln(1 - u)` for `u` in `[0, 1)`. The logarithm's argument is in `(0, 1]`, so the
    /// result is finite and never negative. Divided by a rate it is the gap between the events of a Poisson process,
    /// which gives both the count and the times of those events exactly, at any mean.
    mutating func exponential() -> Double {
        -log(1 - unit())
    }

    /// Standard normal, by the Box-Muller transform. It spends two uniforms on one number and keeps no spare, so the
    /// generator's state stays the whole story.
    mutating func normal() -> Double {
        let radius = (-2 * log(1 - unit())).squareRoot()
        return radius * cos(2 * Double.pi * unit())
    }
}

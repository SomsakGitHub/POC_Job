import Foundation
import TradeCore

/// How hard the price is being shaken. A symbol moves between regimes at random times, so its charts have calm
/// stretches and busy ones.
enum Regime: CaseIterable, Sendable {
    case calm
    case normal
    case volatile

    /// The most ticks one step may move the price; a bigger draw is cut to this.
    static let maxStepTicks = 64
    /// The average time a regime lasts, in simulated seconds (the real length is exponential around it).
    static let meanDwellSeconds = 20.0

    /// The spread of one trade's move, in ticks, before it is rounded to a whole number of ticks. Rounding makes a
    /// calm price move on about 2% of trades, a normal one on 10% and a volatile one on 30%.
    var sigma: Double {
        switch self {
        case .calm: 0.22
        case .normal: 0.30
        case .volatile: 0.50
        }
    }

    /// How likely the regime is to be picked next: calm half the time, volatile one time in seven.
    private var weight: Double {
        switch self {
        case .calm: 0.50
        case .normal: 0.35
        case .volatile: 0.15
        }
    }

    /// The regime after `current` (any regime, when there is none yet): a different one, chosen by weight.
    static func next(after current: Regime?, using generator: inout SeededGenerator) -> Regime {
        let candidates = allCases.filter { $0 != current }
        var pick = generator.unit() * candidates.reduce(0) { $0 + $1.weight }
        for candidate in candidates {
            pick -= candidate.weight
            if pick < 0 { return candidate }
        }
        return candidates.last ?? .normal
    }

    /// One step of the walk, in whole ticks (positive is up): a normal draw of this regime's spread, plus the pull back
    /// toward `reference` (the gap measured in ticks at the current price), rounded and cut to `maxStepTicks`.
    func step(
        from price: Price, toward reference: Price, scale: StepScale, using generator: inout SeededGenerator
    ) -> Int {
        let tick = Double(TickRules.tickSize(at: price).satang)
        let pull = scale.pull * (Double(reference.satang) - Double(price.satang)) / tick
        let move = (pull + sigma * scale.spread * generator.normal()).rounded()
        guard move.isFinite else { return 0 }
        return Int(min(max(move, -Double(Self.maxStepTicks)), Double(Self.maxStepTicks)))
    }
}

/// How far one step of the walk reaches. The walk is an Ornstein-Uhlenbeck process in discrete time: each trade
/// pulls the price 0.2% of the way back toward the reference and shakes it by the regime's spread. A step that spans
/// several trades (one slice of a historical candle) takes the exact multi-trade pull and spread, not a repeat of the
/// single-trade ones.
struct StepScale: Sendable {
    /// The fraction of the gap to the reference that the step closes.
    let pull: Double
    /// The factor on the regime's spread: 1 for one trade, growing toward a ceiling as the span lengthens.
    let spread: Double

    init(pull: Double, spread: Double) {
        self.pull = pull
        self.spread = spread
    }

    init(ticks: Double) {
        let reversion = 0.002
        self.init(
            pull: 1 - exp(-reversion * ticks),
            spread: ((1 - exp(-2 * reversion * ticks)) / (2 * reversion)).squareRoot()
        )
    }

    static let perTick = StepScale(ticks: 1)
}

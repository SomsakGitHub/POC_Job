import SwiftUI
import TradeCore

/// How a price move is drawn: a shape and a colour for the same direction, so that a reader who cannot tell the colours
/// apart still gets the direction from the shape. The colours are the system's, which follow the light and dark
/// appearance.
struct DirectionStyle: Equatable {
    /// The name of the SF Symbol that stands for the direction.
    let symbolName: String
    /// The colour of the symbol and of the figures next to it.
    let color: Color

    /// The style of `direction`. A row with no price has no direction and is drawn as flat.
    init(_ direction: PriceChange.Direction?) {
        switch direction {
        case .up:
            symbolName = "arrowtriangle.up.fill"
            color = .green
        case .down:
            symbolName = "arrowtriangle.down.fill"
            color = .red
        case .flat, nil:
            symbolName = "minus"
            color = .secondary
        }
    }
}

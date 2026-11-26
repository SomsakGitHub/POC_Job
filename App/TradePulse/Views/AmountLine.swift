import SwiftUI

/// How the screens lay out an amount of money or a count of shares.
extension View {
    /// Keeps a money amount or a count of shares on one line, so that it is never broken in the middle of a number.
    ///
    /// The amount keeps the size its style gives it unless it alone is wider than the line it has; then it shrinks to
    /// fit, to no less than half of that size. Whether an amount and the view beside it fit on one line is for the
    /// layout around it to decide (`ViewThatFits`), so this only has to hold a lone, long number together.
    func amountOnOneLine() -> some View {
        lineLimit(1).minimumScaleFactor(0.5)
    }
}

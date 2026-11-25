import SwiftUI
import UIKit

/// Lays SwiftUI views out the way the screens of an iPhone 18 Pro do, at a text size the test chooses, and measures or
/// draws them. Nothing here waits for a clock: a layout is judged by the size it asks for, and a drawing is made once.
@MainActor
enum LayoutRig {
    /// The width of the screen the layouts are judged on, in points.
    static let screenWidth: CGFloat = 402
    /// The height of that screen, in points.
    static let screenHeight: CGFloat = 874
    /// What the screens leave empty on each side of their content, in points.
    static let margin: CGFloat = 16
    /// The width a screen gives its content.
    static var contentWidth: CGFloat { screenWidth - 2 * margin }

    /// The height `view` takes when it is offered `width` and `offeredHeight`, at the text size `typeSize`. It is
    /// offered all the height it wants unless a height is given.
    static func height(
        of view: some View, at typeSize: DynamicTypeSize, width: CGFloat,
        offeredHeight: CGFloat = CGFloat.greatestFiniteMagnitude
    ) -> CGFloat {
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, typeSize))
        return host.sizeThatFits(in: CGSize(width: width, height: offeredHeight)).height
    }

    /// A drawing of a view, from which the colour of a point can be read.
    struct Picture {
        /// What was drawn.
        let image: UIImage

        /// The colour at `point`, in points from the top left corner, as red, green, blue and alpha, each from 0 to
        /// 255. It is empty if the drawing has no pixels.
        func color(at point: CGPoint) -> [Int] {
            guard let cgImage = image.cgImage else { return [] }
            var pixel = [UInt8](repeating: 0, count: 4)
            let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                let scale = image.scale
                // The context's origin is its bottom left corner, so the picture is moved to put `point` over it.
                let top = CGFloat(cgImage.height) - point.y * scale - 1
                context.draw(
                    cgImage,
                    in: CGRect(
                        x: -point.x * scale, y: -top, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)
                    )
                )
                return true
            }
            return drawn ? pixel.map(Int.init) : []
        }
    }

    /// What `draw` made: the picture, and how far down the safe area reaches in it.
    struct Drawing {
        /// The view as it was drawn.
        let picture: Picture
        /// The height of the safe area at the top, in points.
        let safeAreaTop: CGFloat
    }

    /// Draws `view` in a window of `size` in light mode on white, at the text size `typeSize` whatever the device is
    /// set to, with `safeAreaTop` more points of safe area at the top than the window has itself, as a navigation
    /// title leaves. It is nil when there is no scene to draw in.
    static func draw(
        _ view: some View, size: CGSize, safeAreaTop: CGFloat, at typeSize: DynamicTypeSize = .large
    ) -> Drawing? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return nil
        }
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, typeSize))
        host.additionalSafeAreaInsets = UIEdgeInsets(top: safeAreaTop, left: 0, bottom: 0, right: 0)
        host.view.backgroundColor = .white
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .white
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let bounds = CGRect(origin: .zero, size: size)
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            _ = host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        return Drawing(picture: Picture(image: image), safeAreaTop: host.view.safeAreaInsets.top)
    }
}

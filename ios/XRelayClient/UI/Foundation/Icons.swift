import UIKit
import CoreGraphics

/// Draws the vector icons of IconData as template images (tinted with tintColor).
enum Icons {
    private static let cache = NSCache<NSString, UIImage>()

    /// `size` is the side of the 24-unit grid in points; `strokeWidth` is in grid units.
    /// A non-default `strokeWidth` from the caller wins; otherwise the icon's own weight
    /// (searchBold) applies.
    static func image(_ name: IconName, size: CGFloat = 24, strokeWidth: CGFloat = 2) -> UIImage {
        let definition = IconData.definition(for: name)
        let width = strokeWidth != 2 ? strokeWidth : (definition.strokeWidth ?? strokeWidth)
        let key = NSString(string: "\(name.rawValue)|\(size)|\(width)")
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = render(definition, size: size, strokeWidth: width)
        cache.setObject(image, forKey: key)
        return image
    }

    private static func render(_ definition: IconDefinition, size: CGFloat, strokeWidth: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            cgContext.scaleBy(x: size / 24, y: size / 24)
            UIColor.black.setFill()
            UIColor.black.setStroke()
            for layer in definition.layers {
                draw(layer, strokeWidth: strokeWidth, in: cgContext)
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    private static func draw(_ layer: IconLayer, strokeWidth: CGFloat, in cgContext: CGContext) {
        let path = VectorPath.bezierPath(layer.path)
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let clears = layer.mode == .clearStroke || layer.mode == .clearFill
        // Passed to each fill/stroke call too: UIBezierPath may reset the context's mode.
        let blend: CGBlendMode = clears ? .clear : .normal
        if clears {
            cgContext.setBlendMode(.clear)
        }
        switch layer.mode {
        case .stroke, .clearStroke:
            path.stroke(with: blend, alpha: 1)
        case .fill, .clearFill:
            path.fill(with: blend, alpha: 1)
        case .fillAndStroke:
            path.fill(with: .normal, alpha: 1)
            path.stroke(with: .normal, alpha: 1)
        }
        if clears {
            cgContext.setBlendMode(.normal)
        }
    }
}

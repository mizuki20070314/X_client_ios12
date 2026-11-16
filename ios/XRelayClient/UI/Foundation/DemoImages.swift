import UIKit
import CoreGraphics

/// Pictures for the `demo://` URLs of the demo data: soft gradients, an initial on avatars,
/// a few translucent circles on photos. The same URL always draws the same picture.
enum DemoImages {
    /// Two-colour gradients (top-left to bottom-right); the number of the URL picks one.
    private static let gradients: [(Int, Int)] = [
        (0x4FC3F7, 0x1565C0), (0xFFB74D, 0xE65100), (0x81C784, 0x2E7D32), (0xBA68C8, 0x6A1B9A),
        (0xF06292, 0xAD1457), (0xFFD54F, 0xF9A825), (0x4DB6AC, 0x00695C), (0x90A4AE, 0x37474F),
        (0xFF8A65, 0xBF360C), (0x7986CB, 0x283593),
    ]

    /// `demo://avatar/<n>`, `demo://photo/<n>?w=&h=`, `demo://banner/<n>`, `demo://card/<n>`.
    /// `maxPixel` bounds the longer side; the loader always passes a value of at least 1.
    static func image(for url: URL, maxPixel: CGFloat) -> UIImage? {
        let number = seed(url.lastPathComponent)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let width = intValue(query, "w")
        let height = intValue(query, "h")
        switch url.host ?? "" {
        case "avatar":
            return avatar(number, maxPixel: maxPixel)
        case "photo":
            return picture(number, width: width ?? 1200, height: height ?? 800, maxPixel: maxPixel)
        case "banner":
            return picture(number, width: width ?? 1500, height: height ?? 500, maxPixel: maxPixel)
        case "card":
            return picture(number, width: width ?? 1200, height: height ?? 628, maxPixel: maxPixel)
        default:
            return nil
        }
    }

    private static func avatar(_ number: Int, maxPixel: CGFloat) -> UIImage {
        // Square, 96 px, but never more pixels than the caller will show.
        let side = Int((maxPixel >= 1 ? min(96, maxPixel) : 96).rounded())
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let initial = String(letters[modulo(number, letters.count)])
        return render(width: side, height: side, number: number, initial: initial)
    }

    private static func picture(_ number: Int, width: Int, height: Int, maxPixel: CGFloat) -> UIImage? {
        guard width > 0, height > 0 else { return nil }
        let longest = maxPixel >= 1 ? min(maxPixel, 800) : 800
        let scale = longest / CGFloat(max(width, height))
        let pixelWidth = max(1, Int((CGFloat(width) * scale).rounded()))
        let pixelHeight = max(1, Int((CGFloat(height) * scale).rounded()))
        return render(width: pixelWidth, height: pixelHeight, number: number, initial: nil)
    }

    /// Thread-safe: UIGraphicsImageRenderer draws into its own context.
    private static func render(width: Int, height: Int, number: Int, initial: String?) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1  // the sizes are already in pixels
        format.opaque = true
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cgContext = context.cgContext
            let pair = gradients[modulo(number, gradients.count)]
            drawGradient(from: pair.0, to: pair.1, in: cgContext, size: size)
            if let initial = initial {
                drawInitial(initial, in: CGRect(origin: .zero, size: size))
            } else {
                drawBubbles(number, in: cgContext, size: size)
            }
        }
    }

    private static func drawGradient(from start: Int, to end: Int, in context: CGContext, size: CGSize) {
        let colors = [UIColor(hex: start).cgColor, UIColor(hex: end).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: nil) else {
            return
        }
        context.drawLinearGradient(gradient, start: .zero,
                                   end: CGPoint(x: size.width, y: size.height), options: [])
    }

    private static func drawBubbles(_ number: Int, in context: CGContext, size: CGSize) {
        // Fixed spots, nudged by the number so neighbouring URLs differ a little.
        let nudge = CGFloat(modulo(number, 5)) * 0.02
        let spots: [(x: CGFloat, y: CGFloat, radius: CGFloat)] = [
            (0.18 + nudge, 0.22, 0.30),
            (0.84, 0.30 - nudge, 0.18),
            (0.70, 0.86, 0.34),
            (0.22, 0.82, 0.16),
        ]
        context.setFillColor(UIColor(white: 1, alpha: 0.12).cgColor)
        let unit = min(size.width, size.height)
        for spot in spots {
            let radius = spot.radius * unit
            let centerX = spot.x * size.width
            let centerY = spot.y * size.height
            context.fillEllipse(in: CGRect(x: centerX - radius, y: centerY - radius,
                                           width: radius * 2, height: radius * 2))
        }
    }

    private static func drawInitial(_ text: String, in rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: rect.height * 0.46, weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        let string = NSString(string: text)
        let textSize = string.size(withAttributes: attributes)
        let origin = CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2)
        string.draw(at: origin, withAttributes: attributes)
    }

    private static func modulo(_ value: Int, _ divisor: Int) -> Int {
        return ((value % divisor) + divisor) % divisor
    }

    /// The path component as a number, or a stable hash of it (Swift's hashValue changes per launch).
    private static func seed(_ text: String) -> Int {
        if let number = Int(text) {
            return number
        }
        var hash: UInt64 = 14695981039346656037  // FNV-1a offset basis
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211  // FNV-1a prime
        }
        return Int(truncatingIfNeeded: hash & 0x7FFF_FFFF)
    }

    private static func intValue(_ items: [URLQueryItem], _ name: String) -> Int? {
        guard let text = items.first(where: { $0.name == name })?.value else { return nil }
        return Int(text)
    }
}

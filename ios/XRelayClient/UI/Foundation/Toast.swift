import UIKit

/// A short message in a pill above the bottom bar. A new toast replaces the one on screen.
enum Toast {
    /// The toast on screen, so that a new one can replace it.
    private static var current: UIView?

    /// The bottom bar of the app; the toast sits above it.
    private static let bottomBarHeight: CGFloat = 49

    static func show(_ text: String) {
        guard let window = UIApplication.shared.keyWindow else { return }
        current?.removeFromSuperview()
        current = nil

        let padX: CGFloat = 16
        let padY: CGFloat = 9
        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: 14)
        label.textColor = UIColor.white
        label.textAlignment = .center
        label.numberOfLines = 0
        let maxTextWidth = window.bounds.width - 2 * 16 - 2 * padX
        let fitted = label.sizeThatFits(CGSize(width: maxTextWidth, height: CGFloat.greatestFiniteMagnitude))
        let textWidth = fitted.width.rounded(.up)
        let textHeight = fitted.height.rounded(.up)

        let pillWidth = textWidth + 2 * padX
        let pillHeight = max(36, textHeight + 2 * padY)
        let bottom = window.bounds.height - window.safeAreaInsets.bottom - bottomBarHeight - 16
        let pill = UIView(frame: CGRect(x: (window.bounds.width - pillWidth) / 2,
                                        y: bottom - pillHeight,
                                        width: pillWidth,
                                        height: pillHeight))
        pill.backgroundColor = Theme.palette.accent
        pill.layer.cornerRadius = pillHeight / 2
        pill.clipsToBounds = true
        pill.isUserInteractionEnabled = false
        label.frame = CGRect(x: padX, y: (pillHeight - textHeight) / 2, width: textWidth, height: textHeight)
        pill.addSubview(label)
        pill.alpha = 0
        window.addSubview(pill)
        current = pill

        UIView.animate(withDuration: 0.2) {
            pill.alpha = 1
        }
        // Fade out after the 0.2 s fade-in plus 2 s on screen.
        UIView.animate(withDuration: 0.2, delay: 2.2, options: [], animations: {
            pill.alpha = 0
        }, completion: { _ in
            pill.removeFromSuperview()
            if Toast.current === pill {
                Toast.current = nil
            }
        })
    }
}

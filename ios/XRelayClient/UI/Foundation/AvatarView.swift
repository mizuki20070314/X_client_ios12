import UIKit

/// A profile picture: a circle, or a rounded square for square accounts, with the placeholder
/// colour until the picture arrives.
final class AvatarView: UIView {
    /// Setting a handler makes the avatar tappable. Without one it takes no touches,
    /// so taps on a row reach the row.
    var onTap: (() -> Void)? {
        didSet {
            isUserInteractionEnabled = onTap != nil
            updateTapRecognizer()
        }
    }

    private let imageView = RemoteImageView()
    private var isSquareShape = false
    private var tapRecognizer: UITapGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    // Declaring an initialiser hides the inherited init(); keep AvatarView() usable.
    override init() {
        super.init(frame: .zero)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    private func setUp() {
        clipsToBounds = true
        isUserInteractionEnabled = false
        addSubview(imageView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        // The radius follows the drawn size, which is `size` when the frame is square.
        let side = min(bounds.width, bounds.height)
        layer.cornerRadius = isSquareShape ? side / 6 : side / 2
    }

    /// Shows the user's picture at `size` points; a nil user shows only the placeholder.
    func set(user: User?, size: CGFloat) {
        let pixels = Int(size * UIScreen.main.scale)
        set(url: user?.avatarURL(pixels: pixels), square: user?.isSquare ?? false, size: size)
    }

    func set(url: URL?, square: Bool, size: CGFloat) {
        isSquareShape = square
        backgroundColor = Theme.palette.avatarPlaceholder
        setNeedsLayout()
        imageView.setImage(url: url, maxPixel: size * UIScreen.main.scale)
    }

    private func updateTapRecognizer() {
        if onTap != nil {
            if tapRecognizer == nil {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
                addGestureRecognizer(recognizer)
                tapRecognizer = recognizer
            }
        } else if let recognizer = tapRecognizer {
            removeGestureRecognizer(recognizer)
            tapRecognizer = nil
        }
    }

    @objc private func handleTap() {
        onTap?()
    }
}

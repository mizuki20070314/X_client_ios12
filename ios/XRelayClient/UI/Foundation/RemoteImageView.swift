import UIKit

/// An image view that loads its picture from a URL, sized to what it shows.
final class RemoteImageView: UIImageView {
    private var currentURL: URL?
    private var pendingLimit: CGFloat = 0
    private var request: ImageRequest?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    // UIImageView's plain init() is only inherited when every designated initialiser is overridden.
    override init(image: UIImage?) {
        super.init(image: image)
        setUp()
    }

    override init(image: UIImage?, highlightedImage: UIImage?) {
        super.init(image: image, highlightedImage: highlightedImage)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    deinit {
        request?.cancel()
    }

    private func setUp() {
        contentMode = .scaleAspectFill
        clipsToBounds = true
    }

    /// Cancels the previous load. A cached picture appears at once; a new one fades in.
    /// `maxPixel` 0 means the longer side of the view in pixels (1024 before the view has a size).
    func setImage(url: URL?, maxPixel: CGFloat = 0) {
        let limit = maxPixel > 0 ? maxPixel : defaultMaxPixel()
        // The same picture is already on its way (cells are often configured twice): keep it.
        if let url = url, url == currentURL, request != nil, limit == pendingLimit {
            return
        }
        request?.cancel()
        request = nil
        currentURL = url
        pendingLimit = limit
        guard let url = url else {
            image = nil
            return
        }
        if let cached = ImageLoader.shared.cached(url, maxPixel: limit) {
            image = cached
            return
        }
        image = nil
        request = ImageLoader.shared.load(url, maxPixel: limit) { [weak self] loaded in
            guard let view = self, view.currentURL == url else { return }
            view.request = nil
            guard let loaded = loaded else { return }
            UIView.transition(with: view, duration: 0.15, options: .transitionCrossDissolve,
                              animations: { view.image = loaded }, completion: nil)
        }
    }

    /// The longer side of the view in pixels, or 1024 before the view has been laid out.
    private func defaultMaxPixel() -> CGFloat {
        let side = max(bounds.width, bounds.height)
        return side > 0 ? side * UIScreen.main.scale : 1024
    }
}

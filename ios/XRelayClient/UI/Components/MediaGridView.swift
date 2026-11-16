import UIKit

/// The photos, videos and GIFs of a post in a grid (ui-spec §3.6). The layout is a pure function of (media, width),
/// so `height(for:width:)` is exactly the height the grid lays its tiles out to.
final class MediaGridView: UIView {
    /// Called with the index (in `media`) of the tapped tile. Taps reach it only when the grid is interactive.
    var onTap: ((Int) -> Void)?

    private static let gap: CGFloat = 2
    private static let cornerRadius: CGFloat = 16
    private static let maxTiles = 4

    private var media: [Media] = []
    private var layoutWidth: CGFloat = 0
    private var tiles: [MediaTileView] = []
    private let borderView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    private func setUp() {
        layer.cornerRadius = MediaGridView.cornerRadius
        layer.masksToBounds = true
        backgroundColor = UIColor.clear
        // the hairline is added above the tiles, so that the photos do not cover it
        borderView.isUserInteractionEnabled = false
        borderView.backgroundColor = UIColor.clear
        borderView.layer.cornerRadius = MediaGridView.cornerRadius
        borderView.layer.borderWidth = Metrics.hairline
        addSubview(borderView)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    /// Shows the first four items of `media` at `width`. A quoted post's grid is not interactive: its touches go to
    /// the quote box.
    func configure(media: [Media], width: CGFloat, interactive: Bool) {
        self.media = Array(media.prefix(MediaGridView.maxTiles))
        layoutWidth = width
        isUserInteractionEnabled = interactive
        let frames = MediaGridView.layout(for: self.media, width: width).frames
        while tiles.count < self.media.count {
            let tile = MediaTileView(frame: .zero)
            insertSubview(tile, belowSubview: borderView)
            tiles.append(tile)
        }
        // the picture is decoded at the size of its tile, never larger
        let scale = UIScreen.main.scale
        for (index, tile) in tiles.enumerated() {
            guard index < self.media.count, index < frames.count else {
                tile.isHidden = true
                continue
            }
            let frame = frames[index]
            tile.isHidden = false
            tile.set(media: self.media[index], maxPixel: max(frame.width, frame.height) * scale)
        }
        borderView.layer.borderColor = Theme.palette.border.cgColor
        borderView.isHidden = self.media.isEmpty
        setNeedsLayout()
    }

    /// The height the grid needs for `media` at `width`; 0 without media.
    static func height(for media: [Media], width: CGFloat) -> CGFloat {
        return layout(for: Array(media.prefix(maxTiles)), width: width).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let grid = MediaGridView.layout(for: media, width: layoutWidth)
        for (index, tile) in tiles.enumerated() where index < grid.frames.count {
            tile.frame = grid.frames[index]
        }
        borderView.frame = CGRect(x: 0, y: 0, width: layoutWidth, height: grid.height)
        bringSubviewToFront(borderView)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        let frames = MediaGridView.layout(for: media, width: layoutWidth).frames
        if let index = frames.firstIndex(where: { $0.contains(point) }) {
            onTap?(index)
        }
    }

    /// Tile frames and the total height (ui-spec §3.6). Tiles are 2 pt apart.
    private static func layout(for media: [Media], width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let count = min(media.count, maxTiles)
        guard count > 0, width > 0 else { return ([], 0) }
        let gap = MediaGridView.gap
        if count == 1 {
            // a single picture follows its own shape, within 3:4 (tall) and 5:2 (wide)
            let aspect = min(max(media[0].aspect, 0.75), 2.5)
            let height = (width / aspect).rounded()
            return ([CGRect(x: 0, y: 0, width: width, height: height)], height)
        }
        let leftWidth = ((width - gap) / 2).rounded(.down)
        let rightWidth = width - gap - leftWidth
        if count == 2 {
            let height = (width * 4 / 7).rounded()
            let frames = [
                CGRect(x: 0, y: 0, width: leftWidth, height: height),
                CGRect(x: leftWidth + gap, y: 0, width: rightWidth, height: height),
            ]
            return (frames, height)
        }
        if count == 3 {
            // the first tile fills the left column, the other two stack on the right
            let height = (width * 4 / 7).rounded()
            let topHeight = ((height - gap) / 2).rounded(.down)
            let bottomHeight = height - gap - topHeight
            let frames = [
                CGRect(x: 0, y: 0, width: leftWidth, height: height),
                CGRect(x: leftWidth + gap, y: 0, width: rightWidth, height: topHeight),
                CGRect(x: leftWidth + gap, y: topHeight + gap, width: rightWidth, height: bottomHeight),
            ]
            return (frames, height)
        }
        let height = (width * 9 / 16).rounded()
        let topHeight = ((height - gap) / 2).rounded(.down)
        let bottomHeight = height - gap - topHeight
        let frames = [
            CGRect(x: 0, y: 0, width: leftWidth, height: topHeight),
            CGRect(x: leftWidth + gap, y: 0, width: rightWidth, height: topHeight),
            CGRect(x: 0, y: topHeight + gap, width: leftWidth, height: bottomHeight),
            CGRect(x: leftWidth + gap, y: topHeight + gap, width: rightWidth, height: bottomHeight),
        ]
        return (frames, height)
    }
}

/// One item of the grid: the picture, and for videos the play button and the duration, for GIFs the label "GIF".
private final class MediaTileView: UIView {
    private let imageView = RemoteImageView(frame: .zero)
    private let playBadge = MediaPlayBadge(frame: .zero)
    private let pill = MediaOverlayPill(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(imageView)
        addSubview(playBadge)
        addSubview(pill)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Photos show their small size, videos and GIFs their poster frame.
    func set(media: Media, maxPixel: CGFloat) {
        let palette = Theme.palette
        backgroundColor = palette.surface
        imageView.backgroundColor = palette.surface
        let url: URL? = media.kind == .photo ? media.imageURL(.small) : media.url
        imageView.setImage(url: url, maxPixel: maxPixel)

        playBadge.isHidden = media.kind != .video
        pill.isHidden = media.kind == .photo
        if media.kind != .photo {
            let text = media.kind == .gif ? "GIF" : Format.duration(ms: media.durationMs)
            pill.frame.size = pill.configure(text: text, font: Theme.font(12, .medium))
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        let badgeSide: CGFloat = 48
        playBadge.frame = CGRect(x: (bounds.width - badgeSide) / 2, y: (bounds.height - badgeSide) / 2,
                                 width: badgeSide, height: badgeSide)
        // 8 pt in from the bottom-left corner
        pill.frame.origin = CGPoint(x: 8, y: bounds.height - 8 - pill.frame.height)
    }
}

/// The round play button drawn over a video: 48 pt, accent with a white ring and a white play icon.
final class MediaPlayBadge: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.palette.accent
        layer.cornerRadius = 24
        layer.borderWidth = 3
        layer.borderColor = UIColor.white.cgColor
        let icon = UIImageView(image: Icons.image(.play, size: 22))
        icon.tintColor = UIColor.white
        icon.frame = CGRect(x: 13, y: 13, width: 22, height: 22)
        addSubview(icon)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A small black pill with white text: the duration or GIF on a tile, the title on a card.
final class MediaOverlayPill: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0, alpha: 0.77)
        layer.cornerRadius = 4
        clipsToBounds = true
        label.textColor = UIColor.white
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Sets the text (one line, at most `maxWidth` wide, 4 pt padding at the sides and 2 pt above and below) and
    /// returns the size of the pill. The caller places the pill with its frame.
    func configure(text: String, font: UIFont, maxWidth: CGFloat = CGFloat.greatestFiniteMagnitude) -> CGSize {
        label.text = text
        label.font = font
        let fitted = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                               height: CGFloat.greatestFiniteMagnitude))
        let textWidth = ceil(fitted.width)
        let textHeight = ceil(fitted.height)
        let width = min(textWidth + 8, maxWidth)
        label.frame = CGRect(x: 4, y: 2, width: max(0, width - 8), height: textHeight)
        return CGSize(width: width, height: textHeight + 4)
    }
}

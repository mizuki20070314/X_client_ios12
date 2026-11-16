import UIKit

/// A quoted post in a box (ui-spec §3.7): its author, text and media, or only a notice when it cannot be shown.
/// The whole box is one touch target; the links in it are coloured but do not take touches.
final class QuoteView: UIControl {
    /// Called when the box is tapped (the quoted post opens).
    var onTap: (() -> Void)?

    private static let padding: CGFloat = 12
    private static let avatarSide: CGFloat = 20
    /// Between the rows: avatar and name line, name line and text.
    private static let rowGap: CGFloat = 4

    private let avatar = AvatarView(frame: .zero)
    private let nameLine = NameLineView(frame: .zero)
    private let textLabel = LinkLabel(frame: .zero)
    private let mediaGrid = MediaGridView(frame: .zero)
    private let noticeLabel = LinkLabel(frame: .zero)

    /// Frames and texts of one quote box. A pure function of (content, width): `height` and `configure` agree.
    private struct Layout {
        var height: CGFloat = 0
        var avatarFrame = CGRect.zero
        var nameFrame = CGRect.zero
        var textFrame = CGRect.zero
        var textLayout: TextLayout?
        var hasMedia = false
        var mediaFrame = CGRect.zero
        var noticeFrame = CGRect.zero
        var noticeLayout: TextLayout?
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    private func setUp() {
        layer.cornerRadius = 16
        layer.borderWidth = Metrics.hairline
        backgroundColor = UIColor.clear
        let children: [UIView] = [avatar, nameLine, textLabel, mediaGrid, noticeLabel]
        for child in children {
            addSubview(child)
        }
        // the children never take touches: the box does
        let passive: [UIView] = [nameLine, textLabel, mediaGrid, noticeLabel]
        for child in passive {
            child.isUserInteractionEnabled = false
        }
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    /// The box is pressed in the highlight colour while the finger is on it.
    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? Theme.palette.highlight : UIColor.clear
        }
    }

    /// Shows the quoted `tweet`, or `unavailable` alone when it is nil. The box is `width` wide; its height is
    /// `height(tweet:unavailable:width:)`.
    func configure(tweet: Tweet?, unavailable: String?, width: CGFloat) {
        let layout = QuoteView.makeLayout(tweet: tweet, unavailable: unavailable, width: width)
        let palette = Theme.palette
        layer.borderColor = palette.border.cgColor
        backgroundColor = isHighlighted ? palette.highlight : UIColor.clear

        guard let quoted = tweet else {
            avatar.isHidden = true
            nameLine.isHidden = true
            textLabel.isHidden = true
            mediaGrid.isHidden = true
            noticeLabel.isHidden = false
            noticeLabel.textLayout = layout.noticeLayout
            noticeLabel.frame = layout.noticeFrame
            return
        }

        noticeLabel.isHidden = true
        avatar.isHidden = false
        avatar.set(user: quoted.user, size: QuoteView.avatarSide)
        avatar.frame = layout.avatarFrame
        nameLine.isHidden = false
        nameLine.set(user: quoted.user, time: Format.relativeTime(quoted.createdAt), width: layout.nameFrame.width)
        nameLine.frame = layout.nameFrame
        textLabel.isHidden = layout.textLayout == nil
        textLabel.textLayout = layout.textLayout
        textLabel.frame = layout.textFrame
        mediaGrid.isHidden = !layout.hasMedia
        if layout.hasMedia {
            mediaGrid.configure(media: quoted.media, width: layout.mediaFrame.width, interactive: false)
            mediaGrid.frame = layout.mediaFrame
        }
    }

    /// The height of the box for `tweet` (or the notice) at `width`.
    static func height(tweet: Tweet?, unavailable: String?, width: CGFloat) -> CGFloat {
        return makeLayout(tweet: tweet, unavailable: unavailable, width: width).height
    }

    @objc private func tapped() {
        onTap?()
    }

    private static func makeLayout(tweet: Tweet?, unavailable: String?, width: CGFloat) -> Layout {
        var layout = Layout()
        let padding = QuoteView.padding
        let inner = max(0, width - 2 * padding)
        let palette = Theme.palette

        guard let quoted = tweet else {
            let notice = TweetText.attributed(unavailable ?? "", entities: [], font: Theme.font(15),
                                              color: palette.secondaryText, linkColor: palette.secondaryText,
                                              lineSpacing: 2)
            let noticeLayout = TextLayout(notice, width: inner)
            layout.noticeLayout = noticeLayout
            layout.noticeFrame = CGRect(x: padding, y: padding, width: inner, height: noticeLayout.size.height)
            layout.height = padding + noticeLayout.size.height + padding
            return layout
        }

        // first row: the avatar, then the name line up to the right padding
        let nameX = padding + QuoteView.avatarSide + QuoteView.rowGap
        layout.avatarFrame = CGRect(x: padding, y: padding, width: QuoteView.avatarSide, height: QuoteView.avatarSide)
        layout.nameFrame = CGRect(x: nameX, y: padding, width: max(0, width - nameX - padding),
                                  height: NameLineView.height)
        var y = padding + NameLineView.height

        if !quoted.text.isEmpty {
            let body = TweetText.attributed(quoted.text, entities: quoted.entities, font: Theme.font(15),
                                            color: palette.text, linkColor: palette.accent, lineSpacing: 2)
            let textLayout = TextLayout(body, width: inner, maxLines: 8, entities: quoted.entities)
            layout.textLayout = textLayout
            layout.textFrame = CGRect(x: padding, y: y + QuoteView.rowGap, width: inner,
                                      height: textLayout.size.height)
            y += QuoteView.rowGap + textLayout.size.height
        }

        if !quoted.media.isEmpty {
            let mediaHeight = MediaGridView.height(for: quoted.media, width: inner)
            layout.hasMedia = true
            layout.mediaFrame = CGRect(x: padding, y: y + 8, width: inner, height: mediaHeight)
            y += 8 + mediaHeight
        }

        layout.height = y + padding
        return layout
    }
}

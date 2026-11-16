import UIKit

/// The text of a notification: the `bold` ranges in bold (ui-spec.md §5.6).
enum NotificationText {
    static func attributed(_ entry: NotificationEntry) -> NSAttributedString {
        let palette = Theme.palette
        let base = TweetText.attributed(entry.text, entities: [], font: Theme.font(15), color: palette.text,
                                        linkColor: palette.text, lineSpacing: 2)
        let result = NSMutableAttributedString(attributedString: base)
        let boldFont = Theme.font(15, .bold)
        let length = result.length
        for range in entry.bold where range.location >= 0 && range.length > 0 && range.location + range.length <= length {
            result.addAttribute(NSAttributedString.Key.font, value: boldFont, range: range)
        }
        return result
    }
}

/// The frames of a notification row at one width (ui-spec.md §5.6). Built once per width by NotificationRow.
struct NotificationLayout {
    let width: CGFloat
    let height: CGFloat
    let iconFrame: CGRect
    /// One frame per avatar shown; the others are hidden.
    let avatarFrames: [CGRect]
    let textFrame: CGRect?
    let text: TextLayout?
    let postFrame: CGRect?
    let post: TextLayout?
    let hairlineFrame: CGRect
}

extension NotificationLayout {
    static func make(entry: NotificationEntry, width: CGFloat) -> NotificationLayout {
        let palette = Theme.palette
        let pad = Metrics.pad(width)
        let contentX = Metrics.contentX(width)
        let contentWidth = Metrics.contentWidth(width)
        // the icon is right-aligned to the end of the avatar column
        let iconFrame = CGRect(x: pad + Metrics.avatar - 24, y: 12, width: 24, height: 24)

        // 28 pt avatars with 4 pt between them: as many as the column holds
        let slot: CGFloat = 32
        let fit = max(0, Int((contentWidth + 4) / slot))
        let count = min(entry.users.count, fit)
        var avatarFrames: [CGRect] = []
        for index in 0..<count {
            avatarFrames.append(CGRect(x: contentX + CGFloat(index) * slot, y: 12, width: 28, height: 28))
        }

        var y: CGFloat = 12
        var bottom: CGFloat = 12
        if !avatarFrames.isEmpty {
            y = 12 + 28
            bottom = y
        }

        var textFrame: CGRect?
        var text: TextLayout?
        if !entry.text.isEmpty {
            // the text sits 8 pt below the avatars
            if !avatarFrames.isEmpty {
                y += 8
            }
            let layout = TextLayout(NotificationText.attributed(entry), width: contentWidth, maxLines: 0,
                                    entities: [])
            textFrame = CGRect(x: contentX, y: y, width: contentWidth, height: layout.size.height)
            text = layout
            y += layout.size.height
            bottom = y
        }

        var postFrame: CGRect?
        var post: TextLayout?
        if let postText = entry.tweet?.text, !postText.isEmpty {
            // the post text sits 4 pt below whatever is above it
            if !avatarFrames.isEmpty || text != nil {
                y += 4
            }
            let attributed = TweetText.attributed(postText, entities: [], font: Theme.font(15),
                                                  color: palette.secondaryText, linkColor: palette.secondaryText,
                                                  lineSpacing: 2)
            let layout = TextLayout(attributed, width: contentWidth, maxLines: 3, entities: [])
            postFrame = CGRect(x: contentX, y: y, width: contentWidth, height: layout.size.height)
            post = layout
            y += layout.size.height
            bottom = y
        }

        // the icon (24 pt) is the minimum height of the row; 12 pt padding at the bottom
        let height = max(bottom, 12 + 24) + 12
        return NotificationLayout(
            width: width,
            height: height,
            iconFrame: iconFrame,
            avatarFrames: avatarFrames,
            textFrame: textFrame,
            text: text,
            postFrame: postFrame,
            post: post,
            hairlineFrame: CGRect(x: 0, y: height - Metrics.hairline, width: width, height: Metrics.hairline)
        )
    }
}

extension NotificationRow {
    /// The layout at `width`, computed once and then reused.
    func layout(for width: CGFloat) -> NotificationLayout {
        if let cached = layoutCache, cached.width == width {
            return cached
        }
        let fresh = NotificationLayout.make(entry: entry, width: width)
        layoutCache = fresh
        return fresh
    }
}

/// A notification: a kind icon in the left column, the users' avatars, the text and the post it is about.
final class NotificationCell: TimelineCellBase {
    private let iconView = UIImageView()
    /// Enough views for the most users a notification lists (the model keeps at most 8).
    private let avatarViews: [AvatarView] = (0..<8).map { _ in AvatarView(frame: .zero) }
    private let bodyLabel = LinkLabel(frame: .zero)
    private let postLabel = LinkLabel(frame: .zero)
    private var users: [User] = []

    override func setUpContent() {
        contentView.addSubview(iconView)
        for (index, avatar) in avatarViews.enumerated() {
            avatar.isHidden = true
            avatar.onTap = { [weak self] in
                self?.openUser(at: index)
            }
            contentView.addSubview(avatar)
        }
        contentView.addSubview(bodyLabel)
        contentView.addSubview(postLabel)
    }

    func configure(_ row: NotificationRow, layout: NotificationLayout) {
        let style = NotificationCell.iconStyle(for: row.entry.icon)
        iconView.image = Icons.image(style.icon, size: 24)
        iconView.tintColor = style.color
        iconView.timelinePlace(layout.iconFrame)

        users = row.entry.users
        for (index, avatar) in avatarViews.enumerated() {
            if index < layout.avatarFrames.count && index < users.count {
                avatar.timelinePlace(layout.avatarFrames[index])
                avatar.set(user: users[index], size: 28)
            } else {
                avatar.timelinePlace(nil)
                avatar.set(url: nil, square: false, size: 28)
            }
        }

        bodyLabel.timelinePlace(layout.textFrame)
        bodyLabel.textLayout = layout.text
        postLabel.timelinePlace(layout.postFrame)
        postLabel.textLayout = layout.post
        hairline.timelinePlace(layout.hairlineFrame)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        users = []
        for avatar in avatarViews {
            avatar.set(url: nil, square: false, size: 28)
        }
        bodyLabel.textLayout = nil
        postLabel.textLayout = nil
    }

    /// The icon and its colour for a notification kind (ui-spec.md §5.6). Other kinds show the bell.
    static func iconStyle(for kind: String) -> (icon: IconName, color: UIColor) {
        let palette = Theme.palette
        switch kind {
        case "heart":
            return (.heartFill, palette.like)
        case "repost":
            return (.repost, palette.repost)
        case "person":
            return (.personFill, palette.accent)
        case "star":
            return (.star, UIColor(hex: 0x7856FF))
        case "logo":
            return (.logo, palette.text)
        case "reply":
            return (.reply, palette.accent)
        case "alert":
            return (.alert, palette.danger)
        default:
            return (.bellFill, palette.accent)
        }
    }

    private func openUser(at index: Int) {
        guard index < users.count else { return }
        Router.openProfile(user: users[index])
    }
}

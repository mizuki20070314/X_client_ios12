import UIKit

// MARK: - More

/// "返信をさらに表示": a 48 pt row with the label in the accent colour, a spinner while the cursor loads.
final class MoreCell: TimelineCellBase {
    static let rowHeight: CGFloat = 48

    private let label = UILabel()
    private let spinner = TimelineSpinner.make()

    override func setUpContent() {
        label.font = Theme.font(15)
        label.textColor = Theme.palette.accent
        label.numberOfLines = 1
        contentView.addSubview(label)
        contentView.addSubview(spinner)
    }

    func configure(_ row: MoreRow, width: CGFloat) {
        let x = Metrics.contentX(width)
        label.text = row.label
        let labelFrame = CGRect(x: x, y: 14, width: Metrics.contentWidth(width), height: 20)
        label.timelinePlace(row.isLoading ? nil : labelFrame)
        if row.isLoading {
            spinner.frame = CGRect(x: x, y: 14, width: 20, height: 20)
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        hairline.timelinePlace(CGRect(x: 0, y: MoreCell.rowHeight - Metrics.hairline, width: width,
                                      height: Metrics.hairline))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spinner.stopAnimating()
    }
}

// MARK: - Header

/// A section title: an 8 pt band of `palette.surface`, then the title (20 bold) in a 52 pt area.
final class HeaderCell: TimelineCellBase {
    static let rowHeight: CGFloat = 60

    private let band = UIView()
    private let titleLabel = UILabel()

    override func setUpContent() {
        let palette = Theme.palette
        band.backgroundColor = palette.surface
        titleLabel.font = Theme.font(20, .bold)
        titleLabel.textColor = palette.text
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(band)
        contentView.addSubview(titleLabel)
    }

    func configure(_ row: HeaderRow, width: CGFloat) {
        let pad = Metrics.pad(width)
        band.frame = CGRect(x: 0, y: 0, width: width, height: 8)
        titleLabel.text = row.text
        // the 24 pt title line is centred in the 52 pt area below the band
        titleLabel.frame = CGRect(x: pad, y: 8 + 14, width: width - 2 * pad, height: 24)
        hairline.timelinePlace(CGRect(x: 0, y: HeaderCell.rowHeight - Metrics.hairline, width: width,
                                      height: Metrics.hairline))
    }
}

// MARK: - Tombstone

/// The frames of a tombstone at one width. Built once per width by TombstoneRow.
struct TombstoneLayout {
    let width: CGFloat
    let height: CGFloat
    let box: CGRect
    let textFrame: CGRect
    let text: TextLayout
    let threadAbove: CGRect?
    let threadBelow: CGRect?
}

extension TombstoneLayout {
    static func make(text: String, above: Bool, below: Bool, width: CGFloat) -> TombstoneLayout {
        let pad = Metrics.pad(width)
        let inset: CGFloat = 12
        let boxTop: CGFloat = 8
        let textWidth = width - 2 * pad - 2 * inset
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key.font: Theme.font(15),
            NSAttributedString.Key.foregroundColor: Theme.palette.secondaryText
        ])
        let layout = TextLayout(attributed, width: textWidth, maxLines: 0, entities: [])
        let boxHeight = layout.size.height + 2 * inset
        let height = boxTop + boxHeight + boxTop
        // the conversation line runs to the middle of the box, which hides it behind the box
        let middle = boxTop + boxHeight / 2
        let threadX = pad + Metrics.avatar / 2 - TimelineSpec.threadWidth / 2
        var threadAbove: CGRect?
        if above {
            threadAbove = CGRect(x: threadX, y: 0, width: TimelineSpec.threadWidth, height: middle)
        }
        var threadBelow: CGRect?
        if below {
            threadBelow = CGRect(x: threadX, y: middle, width: TimelineSpec.threadWidth, height: height - middle)
        }
        return TombstoneLayout(
            width: width,
            height: height,
            box: CGRect(x: pad, y: boxTop, width: width - 2 * pad, height: boxHeight),
            textFrame: CGRect(x: pad + inset, y: boxTop + inset, width: textWidth, height: layout.size.height),
            text: layout,
            threadAbove: threadAbove,
            threadBelow: threadBelow
        )
    }
}

extension TombstoneRow {
    /// The layout at `width`, computed once and then reused.
    func layout(for width: CGFloat) -> TombstoneLayout {
        if let cached = layoutCache, cached.width == width {
            return cached
        }
        let fresh = TombstoneLayout.make(text: text, above: above, below: below, width: width)
        layoutCache = fresh
        return fresh
    }
}

/// A post that cannot be shown: a surface box with the text, a conversation line behind it where needed.
final class TombstoneCell: TimelineCellBase {
    private let box = UIView()
    private let bodyLabel = LinkLabel(frame: .zero)

    override func setUpContent() {
        box.backgroundColor = Theme.palette.surface
        box.layer.cornerRadius = 12
        // added after the conversation lines, so the box covers them
        contentView.addSubview(box)
        contentView.addSubview(bodyLabel)
    }

    func configure(_ row: TombstoneRow, layout: TombstoneLayout) {
        box.timelinePlace(layout.box)
        bodyLabel.timelinePlace(layout.textFrame)
        bodyLabel.textLayout = layout.text
        threadAbove.timelinePlace(layout.threadAbove)
        threadBelow.timelinePlace(layout.threadBelow)
    }
}

// MARK: - User

/// The frames of a user row at one width. Built once per width by UserRow.
struct UserLayout {
    let width: CGFloat
    let height: CGFloat
    let avatarFrame: CGRect
    let nameFrame: CGRect
    let handleFrame: CGRect
    let chipFrame: CGRect?
    let followFrame: CGRect?
    let bioFrame: CGRect?
    let bio: TextLayout?
    let hairlineFrame: CGRect
}

extension UserLayout {
    static func make(user: User, width: CGFloat) -> UserLayout {
        let palette = Theme.palette
        let pad = Metrics.pad(width)
        let contentX = Metrics.contentX(width)
        let contentWidth = Metrics.contentWidth(width)
        let followWidth = TimelineSpec.followWidth
        // the follow button is left out only for the logged-in user (its own profile row)
        let reservesFollow = user.id != Session.shared.me?.id
        let nameWidth = max(0, contentWidth - (reservesFollow ? followWidth + 8 : 0))

        // the handle has priority: it keeps its full width and is cut only when it does not fit the line itself
        let handleText = NSString(string: "@" + user.handle)
        let handleFullWidth = ceil(handleText.size(withAttributes: [
            NSAttributedString.Key.font: Theme.font(15)
        ]).width)
        let handleWidth = min(handleFullWidth, nameWidth)

        let chipFont = Theme.font(11, .medium)
        let chipText = NSString(string: "フォローされています")
        let chipTextWidth = ceil(chipText.size(withAttributes: [NSAttributedString.Key.font: chipFont]).width)
        let chipWidth = chipTextWidth + 8
        let chipHeight = ceil(chipFont.lineHeight) + 4
        // the chip joins the handle only when it fits completely beside it; otherwise it gets a line of its own
        let chipOnHandleLine = user.followedBy && handleFullWidth + 6 + chipWidth <= nameWidth

        // the handle line ends at 52 pt; a chip on a line of its own sits 4 pt under the handle
        var headerBottom: CGFloat = 52
        var chipFrame: CGRect?
        if user.followedBy {
            if chipOnHandleLine {
                chipFrame = CGRect(x: contentX + handleWidth + 6, y: 32 + (20 - chipHeight) / 2,
                                   width: chipWidth, height: chipHeight)
            } else {
                chipFrame = CGRect(x: contentX, y: 52 + 4, width: chipWidth, height: chipHeight)
                headerBottom = 52 + 4 + chipHeight
            }
        }
        var followFrame: CGRect?
        if reservesFollow {
            followFrame = CGRect(x: width - pad - followWidth, y: 12, width: followWidth, height: 32)
        }

        // the bio sits 4 pt under the last line of the header
        var bottom = headerBottom
        var bioFrame: CGRect?
        var bio: TextLayout?
        if !user.bio.isEmpty {
            let attributed = TweetText.attributed(user.bio, entities: user.bioEntities, font: Theme.font(15),
                                                  color: palette.text, linkColor: palette.accent, lineSpacing: 2)
            let layout = TextLayout(attributed, width: contentWidth, maxLines: 2, entities: user.bioEntities)
            bioFrame = CGRect(x: contentX, y: headerBottom + 4, width: contentWidth, height: layout.size.height)
            bio = layout
            bottom = headerBottom + 4 + layout.size.height
        }
        let height = bottom + 12
        return UserLayout(
            width: width,
            height: height,
            avatarFrame: CGRect(x: pad, y: 12, width: Metrics.avatar, height: Metrics.avatar),
            nameFrame: CGRect(x: contentX, y: 12, width: nameWidth, height: 20),
            handleFrame: CGRect(x: contentX, y: 32, width: handleWidth, height: 20),
            chipFrame: chipFrame,
            followFrame: followFrame,
            bioFrame: bioFrame,
            bio: bio,
            hairlineFrame: CGRect(x: 0, y: height - Metrics.hairline, width: width, height: Metrics.hairline)
        )
    }
}

extension UserRow {
    /// The layout at `width`, computed once and then reused.
    func layout(for width: CGFloat) -> UserLayout {
        if let cached = layoutCache, cached.width == width {
            return cached
        }
        let fresh = UserLayout.make(user: user, width: width)
        layoutCache = fresh
        return fresh
    }
}

/// A user in a list: avatar, name, handle with the "フォローされています" chip, a follow button and the bio.
final class UserCell: TimelineCellBase {
    private let avatar = AvatarView(frame: .zero)
    private let nameLine = NameLineView(frame: .zero)
    private let handleLabel = UILabel()
    private let chipLabel = UILabel()
    private let followButton = FollowButton(frame: .zero)
    private let bioLabel = LinkLabel(frame: .zero)

    override func setUpContent() {
        let palette = Theme.palette
        handleLabel.font = Theme.font(15)
        handleLabel.textColor = palette.secondaryText
        handleLabel.numberOfLines = 1
        handleLabel.lineBreakMode = .byTruncatingTail
        chipLabel.font = Theme.font(11, .medium)
        chipLabel.textColor = palette.secondaryText
        chipLabel.backgroundColor = palette.surface
        chipLabel.textAlignment = .center
        chipLabel.numberOfLines = 1
        chipLabel.layer.cornerRadius = 4
        chipLabel.clipsToBounds = true
        chipLabel.text = "フォローされています"
        bioLabel.onTapEntity = { entity in Router.open(entity: entity) }

        let views: [UIView] = [avatar, nameLine, handleLabel, chipLabel, followButton, bioLabel]
        for view in views {
            contentView.addSubview(view)
        }
    }

    func configure(_ row: UserRow, layout: UserLayout) {
        let user = row.user
        avatar.timelinePlace(layout.avatarFrame)
        avatar.set(user: user, size: Metrics.avatar)
        nameLine.timelinePlace(layout.nameFrame)
        nameLine.showsHandle = false
        nameLine.set(user: user, time: nil, width: layout.nameFrame.width)
        handleLabel.timelinePlace(layout.handleFrame)
        handleLabel.text = "@" + user.handle
        chipLabel.timelinePlace(user.followedBy ? layout.chipFrame : nil)

        let showsFollow = layout.followFrame != nil && user.id != Session.shared.me?.id
        followButton.timelinePlace(showsFollow ? layout.followFrame : nil)
        if showsFollow {
            followButton.set(user: user)
        }

        bioLabel.timelinePlace(layout.bioFrame)
        bioLabel.textLayout = layout.bio
        hairline.timelinePlace(layout.hairlineFrame)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatar.set(url: nil, square: false, size: Metrics.avatar)
        bioLabel.textLayout = nil
    }
}

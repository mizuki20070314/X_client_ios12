import UIKit

/// One line of a user's name: name, badge, lock, `@handle` and the time (ui-spec §3.5). The time never shrinks; when
/// the line is too long the handle is shortened first (down to 30 pt), then the name.
final class NameLineView: UIView {
    static let height: CGFloat = 20

    /// False for the focal post and the profile header: then only the name and the badge are shown.
    var showsHandle = true

    private static let minHandleWidth: CGFloat = 30
    /// Between the name group (name, badge, lock) and the handle.
    private static let handleGap: CGFloat = 4

    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let timeLabel = UILabel()
    private let badgeView = UIImageView()
    private let lockView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    private func setUp() {
        backgroundColor = UIColor.clear
        let labels: [UILabel] = [nameLabel, handleLabel, timeLabel]
        for label in labels {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        addSubview(badgeView)
        addSubview(lockView)
    }

    /// Places the parts for a line `width` points wide. `time` is the plain text, e.g. "3時間"; the separator is added here.
    func set(user: User, time: String?, width: CGFloat) {
        let palette = Theme.palette
        let nameFont = Theme.font(15, .bold)
        let bodyFont = Theme.font(15, .regular)

        let handleText = showsHandle ? "@" + user.handle : ""
        var timeText = ""
        if showsHandle, let time = time, !time.isEmpty {
            timeText = " · " + time
        }

        // widths of the full texts, then what the line can hold
        let fullName = NameLineView.textWidth(user.name, nameFont)
        let fullHandle = handleText.isEmpty ? CGFloat(0) : NameLineView.textWidth(handleText, bodyFont)
        let timeWidth = timeText.isEmpty ? CGFloat(0) : NameLineView.textWidth(timeText, bodyFont)
        let badgeBlock: CGFloat = user.verified == .none ? 0 : 18
        let lockBlock: CGFloat = user.isProtected ? 16 : 0
        let gap = NameLineView.handleGap
        let available = max(0, width - timeWidth)

        var nameWidth = fullName
        var handleWidth = fullHandle
        let handleBlock: CGFloat = fullHandle > 0 ? gap + fullHandle : 0
        let fullGroup = fullName + badgeBlock + lockBlock + handleBlock
        if fullGroup > available {
            if fullHandle > 0 {
                let room = available - (fullName + badgeBlock + lockBlock + gap)
                handleWidth = min(fullHandle, max(NameLineView.minHandleWidth, room))
            }
            let handleUse: CGFloat = handleWidth > 0 ? gap + handleWidth : 0
            let others = badgeBlock + lockBlock + handleUse
            nameWidth = max(0, min(fullName, available - others))
        }

        let height = NameLineView.height
        nameLabel.text = user.name
        nameLabel.font = nameFont
        nameLabel.textColor = palette.text
        nameLabel.frame = CGRect(x: 0, y: 0, width: nameWidth, height: height)
        nameLabel.isHidden = nameWidth <= 0

        // the badge and the lock follow the name; each has a 2 pt gap in front of it
        var x = nameWidth
        if badgeBlock > 0 {
            badgeView.image = Icons.image(.verified, size: 16)
            badgeView.tintColor = NameLineView.badgeColor(user.verified, palette)
            badgeView.frame = CGRect(x: x + 2, y: 2, width: 16, height: 16)
            x += badgeBlock
        }
        badgeView.isHidden = badgeBlock == 0
        if lockBlock > 0 {
            lockView.image = Icons.image(.lock, size: 14)
            lockView.tintColor = palette.text
            lockView.frame = CGRect(x: x + 2, y: 3, width: 14, height: 14)
            x += lockBlock
        }
        lockView.isHidden = lockBlock == 0

        if handleWidth > 0 {
            x += gap
            handleLabel.text = handleText
            handleLabel.font = bodyFont
            handleLabel.textColor = palette.secondaryText
            handleLabel.frame = CGRect(x: x, y: 0, width: handleWidth, height: height)
            x += handleWidth
        }
        handleLabel.isHidden = handleWidth <= 0

        if timeWidth > 0 {
            timeLabel.text = timeText
            timeLabel.font = bodyFont
            timeLabel.textColor = palette.secondaryText
            timeLabel.frame = CGRect(x: x, y: 0, width: timeWidth, height: height)
        }
        timeLabel.isHidden = timeWidth <= 0
    }

    private static func badgeColor(_ kind: VerifiedKind, _ palette: Palette) -> UIColor {
        switch kind {
        case .business:
            return palette.gold
        case .government:
            return palette.grey
        case .blue, .none:
            return palette.accent
        }
    }

    /// The width of one line of `text`, rounded up.
    private static func textWidth(_ text: String, _ font: UIFont) -> CGFloat {
        let size = NSString(string: text).size(withAttributes: [NSAttributedString.Key.font: font])
        return ceil(size.width)
    }
}

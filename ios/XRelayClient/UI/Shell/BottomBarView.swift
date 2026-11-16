import UIKit

/// The bottom bar (ui-spec §2.2): four icon-only tab buttons, and number badges on the bell and the message icon.
/// The bar includes the bottom safe area; the buttons sit in its top `Metrics.bottomBarHeight`.
final class BottomBarView: UIView {
    /// Called with the index of the tapped button: 0 home, 1 search, 2 notifications, 3 messages.
    var onSelect: ((Int) -> Void)?

    private struct Item {
        let normal: IconName
        let selected: IconName
        let label: String
    }

    private static let items: [Item] = [
        Item(normal: .home, selected: .homeFill, label: "ホーム"),
        Item(normal: .search, selected: .searchBold, label: "検索"),
        Item(normal: .bell, selected: .bellFill, label: "通知"),
        Item(normal: .message, selected: .messageFill, label: "メッセージ"),
    ]
    private static let iconSize: CGFloat = 26
    private static let badgeHeight: CGFloat = 16
    private static let notificationIndex = 2
    private static let messageIndex = 3

    private let separator = UIView()
    private var buttons: [UIButton] = []
    private let notificationBadge = UILabel()
    private let messageBadge = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    private func setUp() {
        let palette = Theme.palette
        backgroundColor = palette.background
        separator.backgroundColor = palette.separator
        addSubview(separator)
        for (index, item) in BottomBarView.items.enumerated() {
            let button = UIButton(type: .custom)
            button.tag = index
            button.tintColor = palette.text
            button.accessibilityLabel = item.label
            button.setImage(Icons.image(item.normal, size: BottomBarView.iconSize), for: .normal)
            button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
            addSubview(button)
            buttons.append(button)
        }
        for badge in [notificationBadge, messageBadge] {
            badge.font = Theme.font(10, .bold)
            badge.textColor = UIColor.white
            badge.textAlignment = .center
            badge.backgroundColor = palette.accent
            badge.clipsToBounds = true
            badge.layer.cornerRadius = BottomBarView.badgeHeight / 2
            badge.isHidden = true
            addSubview(badge)
        }
    }

    /// The selected tab shows its filled icon.
    func setSelectedIndex(_ index: Int) {
        for (position, button) in buttons.enumerated() {
            let item = BottomBarView.items[position]
            let name = position == index ? item.selected : item.normal
            button.setImage(Icons.image(name, size: BottomBarView.iconSize), for: .normal)
        }
    }

    /// A count of 0 hides the badge; above 99 it reads "99+".
    func setBadges(notifications: Int, messages: Int) {
        setBadge(notificationBadge, count: notifications)
        setBadge(messageBadge, count: messages)
    }

    private func setBadge(_ badge: UILabel, count: Int) {
        badge.isHidden = count <= 0
        badge.text = count > 99 ? "99+" : "\(count)"
        setNeedsLayout()
    }

    @objc private func buttonTapped(_ sender: UIButton) {
        onSelect?(sender.tag)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let slot = width / CGFloat(BottomBarView.items.count)
        let rowHeight = Metrics.bottomBarHeight
        separator.frame = CGRect(x: 0, y: 0, width: width, height: Metrics.hairline)
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: slot * CGFloat(index), y: 0, width: slot, height: rowHeight)
        }
        layoutBadge(notificationBadge, index: BottomBarView.notificationIndex, slot: slot, rowHeight: rowHeight)
        layoutBadge(messageBadge, index: BottomBarView.messageIndex, slot: slot, rowHeight: rowHeight)
    }

    /// The badge is centred 10 pt right of the icon's centre and 9 pt above it; at least 16 pt high and wide.
    private func layoutBadge(_ badge: UILabel, index: Int, slot: CGFloat, rowHeight: CGFloat) {
        let iconX = slot * (CGFloat(index) + 0.5)
        let iconY = rowHeight / 2
        let textSize = badge.sizeThatFits(CGSize(width: 100, height: BottomBarView.badgeHeight))
        let badgeWidth = max(BottomBarView.badgeHeight, ceil(textSize.width) + 8)
        let centerX = iconX + 10
        let centerY = iconY - 9
        badge.frame = CGRect(x: centerX - badgeWidth / 2, y: centerY - BottomBarView.badgeHeight / 2,
                             width: badgeWidth, height: BottomBarView.badgeHeight)
    }
}

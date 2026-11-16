import UIKit

/// The drawer behind the avatar (ui-spec §5.8): the account, its counts, the destinations and the theme button.
/// Every row closes the drawer first, then navigates through Router.
final class DrawerViewController: UIViewController {
    private let avatar = AvatarView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
    private let nameLabel = UILabel()
    private let verifiedIcon = UIImageView()
    private let handleLabel = UILabel()
    private let followingButton = UIButton(type: .custom)
    private let followersButton = UIButton(type: .custom)
    private let profileRow = DrawerRowControl(frame: .zero)
    private let historyRow = DrawerRowControl(frame: .zero)
    private let settingsRow = DrawerRowControl(frame: .zero)
    private let divider = UIView()
    private let themeButton = UIButton(type: .custom)

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.palette
        view.backgroundColor = palette.background

        avatar.onTap = { DrawerViewController.openOwnProfile() }
        view.addSubview(avatar)

        nameLabel.font = Theme.font(17, .bold)
        nameLabel.textColor = palette.text
        nameLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(nameLabel)
        view.addSubview(verifiedIcon)

        handleLabel.font = Theme.font(15)
        handleLabel.textColor = palette.secondaryText
        handleLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(handleLabel)

        followingButton.contentHorizontalAlignment = .left
        followingButton.addTarget(self, action: #selector(followingTapped), for: .touchUpInside)
        view.addSubview(followingButton)
        followersButton.contentHorizontalAlignment = .left
        followersButton.addTarget(self, action: #selector(followersTapped), for: .touchUpInside)
        view.addSubview(followersButton)

        profileRow.configure(icon: .person, title: "プロフィール", font: Theme.font(20, .bold))
        profileRow.onTap = { DrawerViewController.openOwnProfile() }
        historyRow.configure(icon: .history, title: "履歴", font: Theme.font(20, .bold))
        historyRow.onTap = { DrawerViewController.navigate { Router.openHistory() } }
        settingsRow.configure(icon: .settings, title: "設定とプライバシー", font: Theme.font(15))
        settingsRow.onTap = { DrawerViewController.navigate { Router.openSettings() } }
        view.addSubview(profileRow)
        view.addSubview(historyRow)
        divider.backgroundColor = palette.separator
        view.addSubview(divider)
        view.addSubview(settingsRow)

        themeButton.tintColor = palette.text
        themeButton.accessibilityLabel = "ダークモード"
        themeButton.addTarget(self, action: #selector(themeTapped), for: .touchUpInside)
        view.addSubview(themeButton)

        NotificationCenter.default.addObserver(self, selector: #selector(reloadProfile),
                                               name: Session.didUpdate, object: nil)
        reloadProfile()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        let insets = view.safeAreaInsets
        let left: CGFloat = 20
        let textWidth = max(0, width - left - 20)
        let top = insets.top + 16

        avatar.frame = CGRect(x: left, y: top, width: 40, height: 40)

        // the badge follows the name's text
        let nameY = top + 48
        let nameTextWidth = ceil(nameLabel.sizeThatFits(CGSize(width: textWidth, height: 22)).width)
        let nameWidth = min(textWidth, nameTextWidth)
        nameLabel.frame = CGRect(x: left, y: nameY, width: nameWidth, height: 22)
        verifiedIcon.frame = CGRect(x: nameLabel.frame.maxX + 4, y: nameY + 3, width: 16, height: 16)
        handleLabel.frame = CGRect(x: left, y: nameY + 24, width: textWidth, height: 18)

        let countsY = nameY + 24 + 18 + 12
        followingButton.frame = CGRect(x: left, y: countsY, width: followingButton.frame.width, height: 20)
        followersButton.frame = CGRect(x: followingButton.frame.maxX + 20, y: countsY,
                                       width: followersButton.frame.width, height: 20)

        let rowsY = countsY + 20 + 16
        profileRow.frame = CGRect(x: 0, y: rowsY, width: width, height: 56)
        historyRow.frame = CGRect(x: 0, y: rowsY + 56, width: width, height: 56)
        divider.frame = CGRect(x: left, y: rowsY + 112 + 8, width: textWidth, height: Metrics.hairline)
        settingsRow.frame = CGRect(x: 0, y: rowsY + 112 + 8 + 1 + 8, width: width, height: 56)

        themeButton.frame = CGRect(x: left, y: view.bounds.height - insets.bottom - 16 - 36, width: 36, height: 36)
    }

    // MARK: - account

    /// Shows the logged-in account; without one (not set up yet) a placeholder and 未設定.
    @objc private func reloadProfile() {
        let palette = Theme.palette
        let me = Session.shared.me
        avatar.set(user: me, size: 40)
        nameLabel.text = me?.name ?? "未設定"
        setVerified(me?.verified ?? VerifiedKind.none)
        handleLabel.text = me.map { "@" + $0.handle }
        handleLabel.isHidden = me == nil

        // the counts come with the full profile, which /v2/me always has
        let showsCounts = me?.isFull ?? false
        followingButton.isHidden = !showsCounts
        followersButton.isHidden = !showsCounts
        if let user = me, user.isFull {
            setCount(followingButton, number: user.friends, word: "フォロー中")
            setCount(followersButton, number: user.followers, word: "フォロワー")
        }

        // the icon shows the switch: the sun on dark themes, the moon on the light one
        let icon: IconName = palette.isDark ? .sun : .moon
        themeButton.setImage(Icons.image(icon, size: 22), for: .normal)
        view.setNeedsLayout()
    }

    private func setVerified(_ kind: VerifiedKind) {
        let palette = Theme.palette
        verifiedIcon.isHidden = kind == VerifiedKind.none
        verifiedIcon.image = Icons.image(.verified, size: 16)
        switch kind {
        case .business:
            verifiedIcon.tintColor = palette.gold
        case .government:
            verifiedIcon.tintColor = palette.grey
        case .none, .blue:
            verifiedIcon.tintColor = palette.accent
        }
    }

    /// "88 フォロー中": the number bold, the word regular (ui-spec §5.4).
    private func setCount(_ button: UIButton, number: Int, word: String) {
        let palette = Theme.palette
        let text = NSMutableAttributedString(string: Format.count(number), attributes: [
            .font: Theme.font(14, .bold),
            .foregroundColor: palette.text,
        ])
        text.append(NSAttributedString(string: " " + word, attributes: [
            .font: Theme.font(14),
            .foregroundColor: palette.secondaryText,
        ]))
        button.setAttributedTitle(text, for: .normal)
        button.sizeToFit()
    }

    // MARK: - actions

    @objc private func followingTapped() {
        DrawerViewController.openUserList(followers: false)
    }

    @objc private func followersTapped() {
        DrawerViewController.openUserList(followers: true)
    }

    @objc private func themeTapped() {
        ThemeSheet.present(from: self)
    }

    private static func openOwnProfile() {
        guard let me = Session.shared.me else { return }
        navigate { Router.openProfile(user: me) }
    }

    private static func openUserList(followers: Bool) {
        guard let me = Session.shared.me else { return }
        navigate { Router.openUserList(userID: me.id, followers: followers) }
    }

    /// Closes the drawer, then runs the navigation.
    private static func navigate(_ action: @escaping () -> Void) {
        guard let root = RootContainerViewController.current else {
            action()
            return
        }
        root.closeDrawer(completion: action)
    }
}

/// One row of the drawer: an icon at 20 pt, the title, and the pressed highlight while the finger is down.
private final class DrawerRowControl: UIControl {
    private let iconView = UIImageView()
    private let titleView = UILabel()
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    private func setUp() {
        addSubview(iconView)
        addSubview(titleView)
        addTarget(self, action: #selector(pressed), for: .touchDown)
        addTarget(self, action: #selector(released), for: [.touchUpOutside, .touchCancel, .touchDragExit])
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    /// The palette is read here, when the drawer is built.
    func configure(icon: IconName, title: String, font: UIFont) {
        let palette = Theme.palette
        iconView.image = Icons.image(icon, size: 24)
        iconView.tintColor = palette.text
        titleView.text = title
        titleView.font = font
        titleView.textColor = palette.text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        iconView.frame = CGRect(x: 20, y: (bounds.height - 24) / 2, width: 24, height: 24)
        titleView.frame = CGRect(x: 64, y: 0, width: max(0, bounds.width - 84), height: bounds.height)
    }

    @objc private func pressed() {
        backgroundColor = Theme.palette.highlight
    }

    @objc private func released() {
        backgroundColor = UIColor.clear
    }

    @objc private func tapped() {
        released()
        onTap?()
    }
}

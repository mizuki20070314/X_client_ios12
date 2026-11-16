import UIKit

/// The follow button of a profile or a user row: a 32 pt pill whose look follows the relationship (ui-spec §3.10).
/// It follows `User.didChange` for the user it shows.
final class FollowButton: UIButton {
    /// The relationship that decides the look. Named apart from `UIControl.State`, which the class inherits.
    private enum Relation {
        case notFollowing, following, requested, blocking
    }

    private var user: User?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setUp() {
        layer.cornerRadius = 16
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        // a selector observer is removed with the button; it is told about every user and checks which one changed
        NotificationCenter.default.addObserver(self, selector: #selector(userDidChange(_:)),
                                               name: User.didChange, object: nil)
    }

    /// Shows the relationship with `user`. A tap calls `UserActions.toggleFollow`.
    func set(user: User) {
        self.user = user
        applyState()
    }

    /// The same width in every state, so that a change of state never moves the layout: the widest title, at least
    /// 96 pt.
    override var intrinsicContentSize: CGSize {
        return CGSize(width: FollowButton.buttonWidth, height: 32)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        return intrinsicContentSize
    }

    private static let buttonWidth: CGFloat = {
        let font = Theme.font(14, .bold)
        var widest: CGFloat = 0
        for title in ["フォローする", "フォロー中", "承認待ち", "ブロック中"] {
            let size = NSString(string: title).size(withAttributes: [NSAttributedString.Key.font: font])
            widest = max(widest, size.width)
        }
        return max(96, ceil(widest) + 32)
    }()

    private func applyState() {
        guard let user = user else { return }
        let palette = Theme.palette
        let state = FollowButton.state(of: user)
        setTitle(FollowButton.title(for: state), for: .normal)
        titleLabel?.font = Theme.font(14, .bold)
        layer.borderColor = palette.border.cgColor
        switch state {
        case .notFollowing:
            backgroundColor = palette.text
            setTitleColor(palette.background, for: .normal)
            layer.borderWidth = 0
        case .following, .requested:
            backgroundColor = UIColor.clear
            setTitleColor(palette.text, for: .normal)
            layer.borderWidth = Metrics.hairline
        case .blocking:
            backgroundColor = palette.danger
            setTitleColor(UIColor.white, for: .normal)
            layer.borderWidth = 0
        }
    }

    /// Blocking wins over everything else; a pending request looks like "following" with its own title.
    private static func state(of user: User) -> Relation {
        if user.blocking {
            return .blocking
        }
        if user.following {
            return .following
        }
        if user.followRequestSent {
            return .requested
        }
        return .notFollowing
    }

    private static func title(for state: Relation) -> String {
        switch state {
        case .notFollowing:
            return "フォローする"
        case .following:
            return "フォロー中"
        case .requested:
            return "承認待ち"
        case .blocking:
            return "ブロック中"
        }
    }

    @objc private func tapped() {
        guard let user = user else { return }
        UserActions.toggleFollow(user)
    }

    @objc private func userDidChange(_ notification: Notification) {
        guard let changed = notification.object as? User, changed === user else { return }
        applyState()
    }
}

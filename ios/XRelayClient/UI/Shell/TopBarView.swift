import UIKit

/// The top bar of a screen (ui-spec §2.4). The controls sit in the lower 44 pt; the status bar area is above them.
final class TopBarView: UIView, UIGestureRecognizerDelegate {
    enum TitleAlignment {
        case leading, center
    }

    var title: String? {
        didSet {
            titleLabel.text = title
            titleLabel.isHidden = (title ?? "").isEmpty
            setNeedsLayout()
        }
    }

    var titleAlignment: TitleAlignment = .leading {
        didSet { setNeedsLayout() }
    }

    /// Back, close or the avatar; placed at the padding, vertically centred.
    var leftView: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let added = leftView {
                addSubview(added)
            }
            setNeedsLayout()
        }
    }

    /// Centred (a logo), or stretched between the side views when `centerViewFills` is set (a search field).
    var centerView: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let added = centerView {
                addSubview(added)
            }
            setNeedsLayout()
        }
    }

    var centerViewFills = false {
        didSet { setNeedsLayout() }
    }

    /// Left to right, 8 pt apart; the last one sits at the right padding. Each keeps the size of its frame.
    var rightViews: [UIView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            rightViews.forEach { addSubview($0) }
            setNeedsLayout()
        }
    }

    var showsSeparator = true {
        didSet { separator.isHidden = !showsSeparator }
    }

    /// Called when the title or the centre view is tapped (a screen scrolls to the top then).
    var onTapTitle: (() -> Void)?

    private let titleLabel = UILabel()
    private let separator = UIView()
    private var avatarView: AvatarView?

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
        isOpaque = true
        titleLabel.font = Theme.font(17, .bold)
        titleLabel.textColor = palette.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isHidden = true
        addSubview(titleLabel)
        separator.backgroundColor = palette.separator
        addSubview(separator)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionDidUpdate),
                                               name: Session.didUpdate, object: nil)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    // MARK: - left view helpers

    /// The back arrow, in a 36 pt touch area.
    func setBackButton(_ action: @escaping () -> Void) {
        leftView = makeIconButton(.back, label: "戻る", action: action)
    }

    /// The close cross of sheets and the initial setup.
    func setCloseButton(_ action: @escaping () -> Void) {
        leftView = makeIconButton(.close, label: "閉じる", action: action)
    }

    /// The account avatar, 32 pt; a tap opens the drawer.
    func setAvatarButton() {
        let button = TopBarButton(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
        let avatar = AvatarView(frame: CGRect(x: 2, y: 2, width: 32, height: 32))
        button.addSubview(avatar)
        button.accessibilityLabel = "メニュー"
        button.onTap = {
            RootContainerViewController.current?.openDrawer()
        }
        avatarView = avatar
        avatar.set(user: Session.shared.me, size: 32)
        leftView = button
    }

    private func makeIconButton(_ name: IconName, label: String, action: @escaping () -> Void) -> UIButton {
        let button = TopBarButton(frame: CGRect(x: 0, y: 0, width: 36, height: 36))
        button.setImage(Icons.image(name, size: 24), for: .normal)
        button.tintColor = Theme.palette.text
        button.accessibilityLabel = label
        button.onTap = action
        return button
    }

    @objc private func sessionDidUpdate() {
        avatarView?.set(user: Session.shared.me, size: 32)
    }

    // MARK: - taps

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        let onTitle = !titleLabel.isHidden && titleLabel.frame.contains(point)
        let onCenter = centerView.map { !$0.isHidden && $0.frame.contains(point) } ?? false
        if onTitle || onCenter {
            onTapTitle?()
        }
    }

    /// Controls keep their own touches, so a search field can still be edited.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return !(touch.view is UIControl)
    }

    // MARK: - layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let rowHeight = Metrics.topBarHeight
        let rowTop = bounds.height - rowHeight
        let pad = Metrics.pad(width)
        separator.frame = CGRect(x: 0, y: bounds.height - Metrics.hairline, width: width, height: Metrics.hairline)

        // leftEnd: where the content after the left view may start
        var leftEnd = pad
        if let left = leftView {
            let size = sized(left, width: width)
            left.frame = CGRect(x: pad, y: rowTop + (rowHeight - size.height) / 2,
                                width: size.width, height: size.height)
            leftEnd = left.frame.maxX
        }

        // rightLimit: the left edge of the group of right views
        var nextRight = width - pad
        var rightLimit = width - pad
        for item in rightViews.reversed() {
            let size = sized(item, width: width)
            item.frame = CGRect(x: nextRight - size.width, y: rowTop + (rowHeight - size.height) / 2,
                                width: size.width, height: size.height)
            rightLimit = item.frame.minX
            nextRight = rightLimit - 8
        }

        switch titleAlignment {
        case .leading:
            let titleX: CGFloat = leftView == nil ? pad : leftEnd + 20
            titleLabel.textAlignment = .left
            titleLabel.frame = CGRect(x: titleX, y: rowTop, width: max(0, rightLimit - 8 - titleX), height: rowHeight)
        case .center:
            // the same space on both sides, so the title stays centred
            let side = max(leftEnd, width - rightLimit)
            titleLabel.textAlignment = .center
            titleLabel.frame = CGRect(x: side, y: rowTop, width: max(0, width - 2 * side), height: rowHeight)
        }

        if let center = centerView {
            if centerViewFills {
                let start: CGFloat = leftView == nil ? pad : leftEnd + 12
                let end: CGFloat = rightViews.isEmpty ? width - pad : rightLimit - 12
                center.frame = CGRect(x: start, y: rowTop + (rowHeight - 36) / 2,
                                      width: max(0, end - start), height: 36)
            } else {
                let size = sized(center, width: width)
                center.frame = CGRect(x: (width - size.width) / 2, y: rowTop + (rowHeight - size.height) / 2,
                                      width: size.width, height: size.height)
            }
        }
    }

    /// A view's own frame size, or the size it asks for while it has none yet.
    private func sized(_ view: UIView, width: CGFloat) -> CGSize {
        if view.frame.width > 0 && view.frame.height > 0 {
            return view.frame.size
        }
        return view.sizeThatFits(CGSize(width: width, height: Metrics.topBarHeight))
    }
}

/// A button that runs a closure when it is tapped.
private final class TopBarButton: UIButton {
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @objc private func tapped() {
        onTap?()
    }
}

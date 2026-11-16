import UIKit

/// A profile: the header (banner, avatar, bio, counts, tabs) over the user's posts in one timeline.
/// The top bar floats over the banner, and turns opaque once the banner has scrolled under it.
final class ProfileViewController: BaseViewController, ModeSelectable, UIScrollViewDelegate {
    private enum State {
        case loading
        case failed(String)
        /// Protected and not followed, or blocked: the header and a message, no posts.
        case hidden(String)
        case list
    }

    private static let postTabTitles = ["ポスト", "返信", "メディア"]
    private static let ownTabTitles = ["ポスト", "返信", "メディア", "いいね"]
    private static let infoMinHeight: CGFloat = 260

    private let handle: String?
    private var user: User?
    private var state: State = .loading
    /// The selected tab, an index into the tabs of the profile (see userTabs(for:)).
    private var selectedListTab = 0
    private var timeline: TimelineViewController?
    private var timelineLoaded = false
    private var header: ProfileHeaderView?
    /// Holds the header and the message when there is no list.
    private var infoScroll: UIScrollView?
    private var infoBody: UIView?
    private let floatingBack = UIButton(type: .custom)
    private let floatingBackCircle = UIView()
    private var opaque = false
    private var lastWidth: CGFloat = 0

    /// Opened with a user: name, avatar and badge show at once, the rest after the full profile has arrived.
    init(user: User) {
        self.user = user
        self.handle = nil
        super.init(nibName: nil, bundle: nil)
    }

    /// Opened with a handle: nothing is shown until the profile has arrived.
    init(handle: String) {
        self.user = nil
        self.handle = handle
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The bar is shown only once the banner has scrolled under it: transparent over the banner, the
    /// floating back button stands in for it.
    override var showsTopBar: Bool {
        return opaque
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        topBar.setBackButton { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }
        setUpFloatingBack()
        NotificationCenter.default.addObserver(self, selector: #selector(userChanged(_:)),
                                               name: User.didChange, object: nil)
        fetchUser()
    }

    override func layoutContent() {
        let width = view.bounds.width
        let full = CGRect(x: 0, y: 0, width: width, height: view.bounds.height)
        timeline?.view.frame = full
        infoScroll?.frame = full
        let safeTop = view.safeAreaInsets.top
        floatingBack.frame = CGRect(x: Metrics.pad(width) - 2, y: safeTop + 4, width: 36, height: 36)
        view.bringSubviewToFront(topBar)
        view.bringSubviewToFront(floatingBack)

        if width != lastWidth {
            lastWidth = width
            applyState()
        }
        if case .list = state, !timelineLoaded, width > 0, let timeline = timeline {
            timelineLoaded = true
            timeline.loadIfNeeded()
        }
    }

    func selectMode(_ index: Int) {
        selectProfileTab(index)
    }

    // MARK: - loading

    private func fetchUser() {
        state = .loading
        applyState()
        let completion: (Result<User, Error>) -> Void = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let full):
                self.user = full
                self.decide(full)
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
                self.applyState()
            }
        }
        if let handle = handle {
            RelayClient.shared.user(handle: handle, completion: completion)
        } else if let user = user {
            RelayClient.shared.user(id: user.id, completion: completion)
        }
    }

    /// Blocked accounts show nothing; protected accounts show nothing unless the viewer follows them.
    private func decide(_ user: User) {
        if user.blockedBy {
            state = .hidden("ブロックされています")
        } else if user.isProtected && !user.following && !isOwn(user) {
            state = .hidden("このアカウントのポストは非公開です")
        } else {
            state = .list
        }
        applyState()
    }

    private func isOwn(_ user: User) -> Bool {
        return user.id == Session.shared.me?.id
    }

    // MARK: - state

    /// Puts the header and the body for the current state in place. Needs a width.
    private func applyState() {
        let width = view.bounds.width
        guard width > 0 else { return }
        var listing = false
        if case .list = state {
            listing = true
        }

        var headerHeight: CGFloat = 0
        if let user = user {
            let header = ensureHeader()
            let titles: [String]? = listing ? tabTitles(for: user) : nil
            headerHeight = header.configure(user: user, width: width, tabTitles: titles,
                                            selectedTab: selectedListTab, isOwn: isOwn(user))
            header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
            if listing {
                let timeline = ensureTimeline(for: user)
                timeline.view.isHidden = false
                timeline.headerView = header
            } else {
                timeline?.view.isHidden = true
                ensureInfoScroll().addSubview(header)
            }
        }

        if listing {
            infoBody?.removeFromSuperview()
            infoBody = nil
            infoScroll?.removeFromSuperview()
            infoScroll = nil
        } else {
            let scroll = ensureInfoScroll()
            let bodyHeight = max(ProfileViewController.infoMinHeight, view.bounds.height - headerHeight)
            let body = makeInfoBody()
            body.frame = CGRect(x: 0, y: headerHeight, width: width, height: bodyHeight)
            infoBody?.removeFromSuperview()
            scroll.addSubview(body)
            infoBody = body
            scroll.contentSize = CGSize(width: width, height: headerHeight + bodyHeight)
        }
        view.setNeedsLayout()
    }

    /// The body under the header when there is no list: a spinner, an error with a retry, or a message.
    private func makeInfoBody() -> UIView {
        switch state {
        case .loading, .list:
            return LoadingView()
        case .failed(let text):
            return MessageView(title: text, detail: nil, buttonTitle: "再試行", action: { [weak self] in
                self?.fetchUser()
            })
        case .hidden(let text):
            return MessageView(title: text, detail: nil, buttonTitle: nil, action: nil)
        }
    }

    private func ensureHeader() -> ProfileHeaderView {
        if let header = header {
            return header
        }
        let header = ProfileHeaderView()
        header.onOverflowTap = { [weak self] in
            self?.showOverflow()
        }
        header.onTabSelect = { [weak self] index in
            self?.selectProfileTab(index)
        }
        header.onCountTap = { [weak self] followers in
            guard let user = self?.user else { return }
            Router.openUserList(userID: user.id, followers: followers)
        }
        header.onLinkTap = { [weak self] in
            guard let url = self?.user?.linkURL else { return }
            Router.openURL(url)
        }
        self.header = header
        return header
    }

    private func ensureTimeline(for user: User) -> TimelineViewController {
        if let timeline = timeline {
            return timeline
        }
        let tabs = userTabs(for: user)
        let timeline = TimelineViewController(source: .userTimeline(userID: user.id, tab: tabs[min(selectedListTab, tabs.count - 1)]))
        timeline.onScroll = { [weak self] scrollView in
            self?.handleScroll(scrollView)
        }
        timeline.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height)
        addChild(timeline)
        view.addSubview(timeline.view)
        timeline.didMove(toParent: self)
        self.timeline = timeline
        return timeline
    }

    private func ensureInfoScroll() -> UIScrollView {
        if let scroll = infoScroll {
            return scroll
        }
        let scroll = UIScrollView()
        if #available(iOS 11.0, *) {
            scroll.contentInsetAdjustmentBehavior = .never
        }
        scroll.backgroundColor = Theme.palette.background
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        scroll.delegate = self
        scroll.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height)
        view.addSubview(scroll)
        infoScroll = scroll
        return scroll
    }

    private func tabTitles(for user: User) -> [String] {
        return isOwn(user) ? ProfileViewController.ownTabTitles : ProfileViewController.postTabTitles
    }

    private func userTabs(for user: User) -> [UserTab] {
        return isOwn(user) ? [.posts, .replies, .media, .likes] : [.posts, .replies, .media]
    }

    private func selectProfileTab(_ index: Int) {
        guard let user = user else { return }
        let tabs = userTabs(for: user)
        guard tabs.indices.contains(index) else { return }
        selectedListTab = index
        header?.setSelectedTab(index)
        timeline?.setSource(.userTimeline(userID: user.id, tab: tabs[index]))
    }

    // MARK: - top bar

    private func setUpFloatingBack() {
        floatingBackCircle.frame = CGRect(x: 2, y: 2, width: 32, height: 32)
        floatingBackCircle.backgroundColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        floatingBackCircle.layer.cornerRadius = 16
        floatingBackCircle.isUserInteractionEnabled = false
        floatingBack.addSubview(floatingBackCircle)
        floatingBack.setImage(Icons.image(.back, size: 20), for: .normal)
        floatingBack.tintColor = UIColor.white
        floatingBack.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        view.addSubview(floatingBack)
    }

    @objc private func backTapped() {
        navigationController?.popViewController(animated: true)
    }

    /// The bar turns opaque (with the name) once the banner's lower edge has moved under it.
    private func handleScroll(_ scrollView: UIScrollView) {
        let banner = (view.bounds.width / 3).rounded()
        let threshold = banner - topBar.frame.maxY
        setOpaque(scrollView.contentOffset.y > threshold)
    }

    private func setOpaque(_ isOpaque: Bool) {
        guard isOpaque != opaque else { return }
        opaque = isOpaque
        // BaseViewController sets the bar's visibility from showsTopBar on every layout pass, so the
        // flag is the state; the layout pass applies it
        view.setNeedsLayout()
        floatingBack.isHidden = isOpaque
        topBar.title = isOpaque ? user?.name : nil
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        handleScroll(scrollView)
    }

    // MARK: - actions

    private func showOverflow() {
        guard let user = user else { return }
        var items: [BottomSheetItem] = [
            BottomSheetItem(icon: .link, title: "リンクをコピー", handler: { [weak self] in
                self?.copyProfileLink()
            })
        ]
        if !isOwn(user) {
            let muteTitle = user.muting ? "ミュートを解除" : "@\(user.handle)さんをミュート"
            items.append(BottomSheetItem(icon: .volumeOff, title: muteTitle, handler: {
                UserActions.toggleMute(user)
            }))
            let blockTitle = user.blocking ? "ブロックを解除" : "@\(user.handle)さんをブロック"
            items.append(BottomSheetItem(icon: .ban, title: blockTitle, style: .destructive, handler: {
                UserActions.toggleBlock(user)
            }))
        }
        BottomSheet.present(from: self, title: nil, items: items)
    }

    private func copyProfileLink() {
        guard let user = user else { return }
        UIPasteboard.general.string = "https://x.com/\(user.handle)"
        Toast.show("コピーしました")
    }

    /// The user changed (followed, muted, blocked, ...): the header and the state follow it.
    @objc private func userChanged(_ notification: Notification) {
        guard let changed = notification.object as? User, let current = user, changed === current else { return }
        decide(current)
    }
}

/// The profile header: banner, avatar, buttons, name, handle, bio, meta items, counts and the tab strip.
/// It is laid out with frames. `configure` sets the content and returns the height the owner gives the header.
final class ProfileHeaderView: UIView {
    var onOverflowTap: (() -> Void)?
    var onTabSelect: ((Int) -> Void)?
    /// true: the followers list, false: the following list.
    var onCountTap: ((Bool) -> Void)?
    var onLinkTap: (() -> Void)?

    private static let avatarSide: CGFloat = 72
    private static let ringWidth: CGFloat = 4
    private static let buttonSide: CGFloat = 32
    /// Starting width of the follow button before it sizes itself to its title.
    private static let followStartWidth: CGFloat = 96
    private static let tabHeight: CGFloat = 44
    private static let nameHeight: CGFloat = 24
    private static let lineHeight: CGFloat = 20

    private let banner = RemoteImageView()
    private let ring = UIView()
    private let avatar = AvatarView()
    private let followButton = FollowButton()
    private let overflowButton = UIButton(type: .custom)
    private let nameLabel = UILabel()
    private let badgeView = UIImageView()
    private let lockView = UIImageView()
    private let handleLabel = UILabel()
    private let chipLabel = UILabel()
    private let bioLabel = LinkLabel()
    private let followingLabel = UILabel()
    private let followersLabel = UILabel()
    private var metaViews: [UIView] = []
    private var tabStrip: TabStripView?

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
        banner.backgroundColor = palette.surface
        ring.backgroundColor = palette.background

        overflowButton.backgroundColor = palette.background
        overflowButton.layer.cornerRadius = ProfileHeaderView.buttonSide / 2
        overflowButton.layer.borderWidth = Metrics.hairline
        overflowButton.layer.borderColor = palette.border.cgColor
        overflowButton.setImage(Icons.image(.overflow, size: 18), for: .normal)
        overflowButton.tintColor = palette.secondaryText
        overflowButton.addTarget(self, action: #selector(overflowTapped), for: .touchUpInside)

        nameLabel.font = Theme.font(20, .bold)
        nameLabel.textColor = palette.text
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail

        handleLabel.font = Theme.font(15)
        handleLabel.textColor = palette.secondaryText
        handleLabel.numberOfLines = 1

        chipLabel.font = Theme.font(11, .medium)
        chipLabel.textColor = palette.secondaryText
        chipLabel.backgroundColor = palette.surface
        chipLabel.layer.cornerRadius = 4
        chipLabel.clipsToBounds = true
        chipLabel.numberOfLines = 1
        chipLabel.textAlignment = .center
        chipLabel.text = "フォローされています"

        bioLabel.onTapEntity = { entity in
            Router.open(entity: entity)
        }

        followingLabel.isUserInteractionEnabled = true
        followingLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(followingTapped)))
        followersLabel.isUserInteractionEnabled = true
        followersLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(followersTapped)))

        // the order matters: the ring sits between the banner and the avatar
        addSubview(banner)
        addSubview(ring)
        addSubview(avatar)
        addSubview(followButton)
        addSubview(overflowButton)
        addSubview(nameLabel)
        addSubview(badgeView)
        addSubview(lockView)
        addSubview(handleLabel)
        addSubview(chipLabel)
        addSubview(bioLabel)
        addSubview(followingLabel)
        addSubview(followersLabel)
    }

    /// Sets the content for `user` at `width`. `tabTitles` adds the tab strip at the bottom; nil means there
    /// is no list under the header, so there are no tabs. Returns the height of the header.
    func configure(user: User, width: CGFloat, tabTitles: [String]?, selectedTab: Int, isOwn: Bool) -> CGFloat {
        let palette = Theme.palette
        let pad = Metrics.pad(width)
        let contentWidth = max(0, width - 2 * pad)
        let bannerHeight = (width / 3).rounded()
        banner.frame = CGRect(x: 0, y: 0, width: width, height: bannerHeight)
        banner.setImage(url: user.bannerURL(wide: false), maxPixel: width * UIScreen.main.scale)

        // the avatar is centred on the lower edge of the banner, inside a ring in the background colour
        let side = ProfileHeaderView.avatarSide
        let ringSide = side + 2 * ProfileHeaderView.ringWidth
        avatar.set(user: user, size: side)
        avatar.frame = CGRect(x: pad, y: bannerHeight - side / 2, width: side, height: side)
        ring.frame = CGRect(x: pad - ProfileHeaderView.ringWidth, y: bannerHeight - ringSide / 2,
                            width: ringSide, height: ringSide)
        ring.layer.cornerRadius = user.isSquare ? ringSide / 6 : ringSide / 2

        // 12 pt under the banner: the overflow button at the right, the follow button left of it (8 pt gap)
        let buttonSide = ProfileHeaderView.buttonSide
        let buttonY = bannerHeight + 12
        let overflowX = width - pad - buttonSide
        overflowButton.frame = CGRect(x: overflowX, y: buttonY, width: buttonSide, height: buttonSide)
        followButton.isHidden = isOwn
        if !isOwn {
            followButton.set(user: user)
            followButton.frame = CGRect(x: 0, y: buttonY, width: ProfileHeaderView.followStartWidth, height: buttonSide)
            followButton.sizeToFit()
            let followWidth = followButton.frame.width
            followButton.frame = CGRect(x: overflowX - 8 - followWidth, y: buttonY,
                                        width: followWidth, height: buttonSide)
        }

        // name (20 bold), then the badge and the lock after it
        var y = bannerHeight + side / 2 + 8
        let nameHeight = ProfileHeaderView.nameHeight
        nameLabel.text = user.name
        let hasBadge = user.verified != .none
        let hasLock = user.isProtected
        let accessoryWidth: CGFloat = (hasBadge ? 24 : 0) + (hasLock ? 22 : 0)
        let fullNameWidth = ceil(nameLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                               height: nameHeight)).width)
        let nameWidth = min(fullNameWidth, max(0, contentWidth - accessoryWidth))
        nameLabel.frame = CGRect(x: pad, y: y, width: nameWidth, height: nameHeight)
        var accessoryX = pad + nameWidth + 4
        badgeView.isHidden = !hasBadge
        if hasBadge {
            badgeView.image = Icons.image(.verified, size: 20)
            badgeView.tintColor = badgeColor(user.verified)
            badgeView.frame = CGRect(x: accessoryX, y: y + 2, width: 20, height: 20)
            accessoryX += 24
        }
        lockView.isHidden = !hasLock
        if hasLock {
            lockView.image = Icons.image(.lock, size: 18)
            lockView.tintColor = palette.text
            lockView.frame = CGRect(x: accessoryX, y: y + 3, width: 18, height: 18)
        }
        y += nameHeight + 2

        // handle, and the "follows you" chip after it
        let lineHeight = ProfileHeaderView.lineHeight
        handleLabel.text = "@" + user.handle
        let handleFullWidth = ceil(handleLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                                   height: lineHeight)).width)
        let handleWidth = min(handleFullWidth, contentWidth)
        handleLabel.frame = CGRect(x: pad, y: y, width: handleWidth, height: lineHeight)
        chipLabel.isHidden = !user.followedBy
        if user.followedBy {
            let chipTextWidth = ceil(chipLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                                   height: 16)).width)
            chipLabel.frame = CGRect(x: pad + handleWidth + 8, y: y + 2, width: chipTextWidth + 8, height: 16)
        }
        y += lineHeight + 12

        // bio: 12 pt lower, links touchable
        if user.bio.isEmpty {
            bioLabel.isHidden = true
        } else {
            let attributed = TweetText.attributed(user.bio, entities: user.bioEntities, font: Theme.font(15),
                                                  color: palette.text, linkColor: palette.accent, lineSpacing: 2)
            let layout = TextLayout(attributed, width: contentWidth, entities: user.bioEntities)
            bioLabel.isHidden = false
            bioLabel.textLayout = layout
            bioLabel.frame = CGRect(x: pad, y: y, width: contentWidth, height: layout.size.height)
            y += layout.size.height + 12
        }

        // meta items in a wrapping row, 12 pt lower
        for view in metaViews {
            view.removeFromSuperview()
        }
        metaViews = []
        var items: [(icon: IconName, text: String, isLink: Bool)] = []
        if !user.location.isEmpty {
            items.append((icon: .mapPin, text: user.location, isLink: false))
        }
        if let display = user.linkDisplay {
            items.append((icon: .link, text: display, isLink: true))
        }
        if let joined = user.joined {
            items.append((icon: .calendar, text: Format.joined(joined), isLink: false))
        }
        if !items.isEmpty {
            y = layoutMetaItems(items, pad: pad, width: width, top: y)
        }

        // counts, 12 pt lower: each number and word is a tap target for its list
        followingLabel.attributedText = countText(user.friends, word: "フォロー中")
        followersLabel.attributedText = countText(user.followers, word: "フォロワー")
        let followingWidth = ceil(followingLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                                     height: lineHeight)).width)
        let followersWidth = ceil(followersLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                                     height: lineHeight)).width)
        followingLabel.frame = CGRect(x: pad, y: y, width: followingWidth, height: lineHeight)
        followersLabel.frame = CGRect(x: pad + followingWidth + 20, y: y, width: followersWidth, height: lineHeight)
        y += lineHeight + 12

        // the tab strip closes the header when there is a list under it
        if let titles = tabTitles {
            let strip = showTabStrip(titles: titles)
            strip.frame = CGRect(x: 0, y: y, width: width, height: ProfileHeaderView.tabHeight)
            strip.selectedIndex = selectedTab
            y += ProfileHeaderView.tabHeight
        } else {
            tabStrip?.isHidden = true
        }
        return y
    }

    /// Selects a tab in the strip without telling the owner (the owner changes the list itself).
    func setSelectedTab(_ index: Int) {
        tabStrip?.selectedIndex = index
    }

    /// A wrapping row of "icon text" items: 13 pt icon, 4 pt gap, 12 pt between items. Returns the y below it.
    private func layoutMetaItems(_ items: [(icon: IconName, text: String, isLink: Bool)],
                                 pad: CGFloat, width: CGFloat, top: CGFloat) -> CGFloat {
        let palette = Theme.palette
        let iconSide: CGFloat = 13
        let iconGap: CGFloat = 4
        let itemGap: CGFloat = 12
        let rowHeight = ProfileHeaderView.lineHeight
        let rowGap: CGFloat = 8
        let contentWidth = max(0, width - 2 * pad)
        var x = pad
        var rowY = top
        for item in items {
            let label = UILabel()
            label.text = item.text
            label.font = Theme.font(15)
            label.textColor = item.isLink ? palette.accent : palette.secondaryText
            label.numberOfLines = 1
            let fullWidth = ceil(label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                           height: rowHeight)).width)
            let textWidth = min(contentWidth, fullWidth)
            let itemWidth = iconSide + iconGap + textWidth
            if x > pad && x + itemWidth > width - pad {
                x = pad
                rowY += rowHeight + rowGap
            }
            let icon = UIImageView(image: Icons.image(item.icon, size: iconSide))
            icon.tintColor = palette.secondaryText
            icon.frame = CGRect(x: x, y: rowY + (rowHeight - iconSide) / 2, width: iconSide, height: iconSide)
            label.frame = CGRect(x: x + iconSide + iconGap, y: rowY, width: textWidth, height: rowHeight)
            if item.isLink {
                label.isUserInteractionEnabled = true
                label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(linkTapped)))
            }
            addSubview(icon)
            addSubview(label)
            metaViews.append(icon)
            metaViews.append(label)
            x += itemWidth + itemGap
        }
        return rowY + rowHeight + 12
    }

    private func showTabStrip(titles: [String]) -> TabStripView {
        if let strip = tabStrip {
            strip.setTitles(titles)
            strip.isHidden = false
            return strip
        }
        let strip = TabStripView(titles: titles, style: .fill)
        strip.onSelect = { [weak self] index in
            self?.onTabSelect?(index)
        }
        addSubview(strip)
        tabStrip = strip
        return strip
    }

    private func countText(_ count: Int, word: String) -> NSAttributedString {
        let palette = Theme.palette
        let number = NSMutableAttributedString(string: Format.count(count),
                                               attributes: [.font: Theme.font(14, .bold),
                                                            .foregroundColor: palette.text])
        number.append(NSAttributedString(string: " " + word,
                                         attributes: [.font: Theme.font(14),
                                                      .foregroundColor: palette.secondaryText]))
        return number
    }

    private func badgeColor(_ kind: VerifiedKind) -> UIColor {
        let palette = Theme.palette
        switch kind {
        case .blue, .none:
            return palette.accent
        case .business:
            return palette.gold
        case .government:
            return palette.grey
        }
    }

    @objc private func overflowTapped() {
        onOverflowTap?()
    }

    @objc private func linkTapped() {
        onLinkTap?()
    }

    @objc private func followingTapped() {
        onCountTap?(false)
    }

    @objc private func followersTapped() {
        onCountTap?(true)
    }
}

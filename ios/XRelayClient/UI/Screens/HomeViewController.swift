import UIKit

/// The home tab: the "recommended" and "following" timelines, with the compose button floating over them.
final class HomeViewController: BaseViewController, TabRootScrollable, ModeSelectable {
    /// The selected home tab, kept across launches.
    private static let tabKey = "homeTab"
    /// Room under the last post, so the compose button does not cover it.
    private static let bottomInset: CGFloat = 80

    private let strip = TabStripView(titles: ["おすすめ", "フォロー中"], style: .fill)
    private var pager: PagerViewController?
    private let composeButton = UIButton(type: .custom)
    private var restoredTab = false

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var topBarAccessoryHeight: CGFloat {
        return Metrics.tabStripHeight
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        topBar.setAvatarButton()
        topBar.centerView = makeLogoView()
        topBar.showsSeparator = false
        topBar.onTapTitle = { [weak self] in
            self?.scrollToTopOrRefresh()
        }

        view.addSubview(strip)
        strip.onSelect = { [weak self] index in
            self?.pager?.setPage(index, animated: true)
        }

        let pager = PagerViewController(pageCount: 2, makePage: { index in
            HomeViewController.makeTimeline(following: index == 1)
        })
        addChild(pager)
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.onProgress = { [weak self] position in
            self?.strip.setProgress(position)
        }
        pager.onPageChange = { [weak self] index in
            self?.strip.selectedIndex = index
            UserDefaults.standard.set(index, forKey: HomeViewController.tabKey)
        }
        self.pager = pager

        setUpComposeButton()
        NotificationCenter.default.addObserver(self, selector: #selector(tweetCreated(_:)),
                                               name: .tweetCreated, object: nil)
    }

    override func layoutContent() {
        let width = view.bounds.width
        let height = view.bounds.height
        strip.frame = CGRect(x: 0, y: topBar.frame.maxY, width: width, height: Metrics.tabStripHeight)
        let top = contentTop
        pager?.view.frame = CGRect(x: 0, y: top, width: width, height: max(0, height - top))
        // 16 pt from the right and bottom edges of the content area (the bottom bar is already above it)
        composeButton.frame = CGRect(x: width - 16 - 56, y: height - 16 - 56, width: 56, height: 56)
        view.bringSubviewToFront(composeButton)

        // the remembered tab is set once the pager has its width
        if !restoredTab && width > 0 {
            restoredTab = true
            let saved = UserDefaults.standard.integer(forKey: HomeViewController.tabKey)
            selectHomeTab(min(max(saved, 0), 1))
        }
    }

    func scrollToTopOrRefresh() {
        currentTimeline()?.scrollToTopOrRefresh()
    }

    func selectMode(_ index: Int) {
        selectHomeTab(index)
    }

    func selectHomeTab(_ index: Int) {
        strip.selectedIndex = index
        pager?.setPage(index, animated: false)
        (pager?.page(at: index) as? TimelineViewController)?.loadIfNeeded()
    }

    private func currentTimeline() -> TimelineViewController? {
        guard let pager = pager else { return nil }
        return pager.page(at: pager.currentIndex) as? TimelineViewController
    }

    private static func makeTimeline(following: Bool) -> TimelineViewController {
        let timeline = TimelineViewController(source: .home(following: following))
        timeline.extraBottomInset = bottomInset
        return timeline
    }

    /// A post made from the compose button (not a reply) goes to the top of every list that is loaded.
    @objc private func tweetCreated(_ notification: Notification) {
        guard notification.userInfo?["replyTo"] == nil else { return }
        guard let tweet = notification.object as? Tweet, let pager = pager else { return }
        for index in 0..<2 {
            guard let timeline = pager.page(at: index) as? TimelineViewController, timeline.isLoaded else { continue }
            timeline.insertAtTop(tweet)
        }
    }

    @objc private func composeTapped() {
        Router.openCompose()
    }

    private func makeLogoView() -> UIView {
        let logo = UIImageView(image: Icons.image(.logo, size: 22))
        logo.tintColor = Theme.palette.text
        logo.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        return logo
    }

    private func setUpComposeButton() {
        let palette = Theme.palette
        composeButton.backgroundColor = palette.accent
        composeButton.tintColor = UIColor.white
        composeButton.setImage(Icons.image(.plus, size: 24), for: .normal)
        composeButton.layer.cornerRadius = 28
        composeButton.layer.shadowColor = UIColor.black.cgColor
        composeButton.layer.shadowOpacity = 0.25
        composeButton.layer.shadowRadius = 6
        composeButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        composeButton.addTarget(self, action: #selector(composeTapped), for: .touchUpInside)
        view.addSubview(composeButton)
    }
}

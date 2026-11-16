import UIKit

/// The notifications tab: the "all" and "@posts" timelines, one per page of a pager.
final class NotificationsViewController: BaseViewController, TabRootScrollable, ModeSelectable {
    private let strip = TabStripView(titles: ["すべて", "@ポスト"], style: .fill)
    private var pager: PagerViewController?

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
        topBar.title = "通知"
        topBar.setAvatarButton()
        topBar.onTapTitle = { [weak self] in
            self?.scrollToTopOrRefresh()
        }

        view.addSubview(strip)
        strip.onSelect = { [weak self] index in
            self?.pager?.setPage(index, animated: true)
        }

        let pager = PagerViewController(pageCount: 2, makePage: { index in
            NotificationsViewController.makeTimeline(mentions: index == 1)
        })
        addChild(pager)
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.onProgress = { [weak self] position in
            self?.strip.setProgress(position)
        }
        pager.onPageChange = { [weak self] index in
            self?.strip.selectedIndex = index
        }
        self.pager = pager
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Opening the tab reads the notifications, so the bell badge goes. Session has no setter that
        // announces the change, so the update is posted here.
        if Session.shared.badges.notifications != 0 {
            Session.shared.badges.notifications = 0
            NotificationCenter.default.post(name: Session.didUpdate, object: Session.shared)
        }
    }

    override func layoutContent() {
        let width = view.bounds.width
        strip.frame = CGRect(x: 0, y: topBar.frame.maxY, width: width, height: Metrics.tabStripHeight)
        let top = contentTop
        pager?.view.frame = CGRect(x: 0, y: top, width: width, height: max(0, view.bounds.height - top))
    }

    func scrollToTopOrRefresh() {
        guard let pager = pager else { return }
        (pager.page(at: pager.currentIndex) as? TimelineViewController)?.scrollToTopOrRefresh()
    }

    func selectMode(_ index: Int) {
        strip.selectedIndex = index
        pager?.setPage(index, animated: false)
    }

    private static func makeTimeline(mentions: Bool) -> TimelineViewController {
        let timeline = TimelineViewController(source: .notifications(mentions: mentions))
        timeline.emptyText = "通知はまだありません"
        return timeline
    }
}

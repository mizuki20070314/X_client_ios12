import UIKit

/// Bookmarks and liked posts of the logged-in account (ui-spec §5.10).
final class HistoryViewController: BaseViewController {
    private var strip: TabStripView?
    private var pager: PagerViewController?
    /// The likes page while the account is unknown: it shows a message until the account arrives.
    private var waitingLikes: HistoryPageHostController?

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
        topBar.setBackButton { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }
        topBar.title = "履歴"

        let strip = TabStripView(titles: ["ブックマーク", "いいね"], style: .fill)
        strip.onSelect = { [weak self] index in
            self?.pager?.setPage(index, animated: true)
        }
        view.addSubview(strip)
        self.strip = strip

        // the pager creates a page the first time it is needed
        let pager = PagerViewController(pageCount: 2) { [weak self] index in
            guard let self = self else { return UIViewController(nibName: nil, bundle: nil) }
            return self.makePage(index)
        }
        pager.onProgress = { [weak self] position in
            self?.strip?.setProgress(position)
        }
        pager.onPageChange = { [weak self] index in
            self?.strip?.selectedIndex = index
        }
        addChild(pager)
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        self.pager = pager

        NotificationCenter.default.addObserver(self, selector: #selector(sessionDidUpdate),
                                               name: Session.didUpdate, object: nil)
    }

    override func layoutContent() {
        let width = view.bounds.width
        strip?.frame = CGRect(x: 0, y: contentTop - Metrics.tabStripHeight, width: width,
                              height: Metrics.tabStripHeight)
        pager?.view.frame = CGRect(x: 0, y: contentTop, width: width,
                                   height: max(0, view.bounds.height - contentTop))
    }

    /// Page 0 is the bookmarks; page 1 is the liked posts, which are listed per account.
    private func makePage(_ index: Int) -> UIViewController {
        if index == 0 {
            let bookmarks = TimelineViewController(source: .bookmarks)
            bookmarks.emptyText = "ブックマークはまだありません"
            return bookmarks
        }
        if let likes = likesTimeline() {
            return likes
        }
        let waiting = HistoryPageHostController()
        waiting.showMessage(makeWaitingMessage())
        waitingLikes = waiting
        return waiting
    }

    /// The liked posts of the logged-in account; nil while the account is unknown.
    private func likesTimeline() -> TimelineViewController? {
        guard let me = Session.shared.me else { return nil }
        let likes = TimelineViewController(source: .userTimeline(userID: me.id, tab: .likes))
        likes.emptyText = "いいねしたポストはまだありません"
        return likes
    }

    /// The button asks the relay for the account again.
    private func makeWaitingMessage() -> MessageView {
        return MessageView(
            title: "アカウントを読み込めません",
            detail: "いいねしたポストを表示するには、アカウント情報が必要です。",
            buttonTitle: "再試行",
            action: { Session.shared.refresh() }
        )
    }

    /// The account has arrived: the waiting likes page shows its timeline.
    @objc private func sessionDidUpdate() {
        guard let waiting = waitingLikes, let likes = likesTimeline() else { return }
        waiting.host(likes)
        // the pager loads only timelines it creates itself; this one sits in a host page
        likes.loadIfNeeded()
        waitingLikes = nil
    }
}

extension HistoryViewController: ModeSelectable {
    func selectMode(_ index: Int) {
        pager?.setPage(index, animated: false)
        strip?.selectedIndex = index
    }
}

/// A page that shows one child controller, or a message, at its own size.
private final class HistoryPageHostController: UIViewController {
    private var hosted: UIViewController?
    private var message: UIView?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hosted?.view.frame = view.bounds
        message?.frame = view.bounds
    }

    func host(_ child: UIViewController) {
        removeContent()
        addChild(child)
        view.addSubview(child.view)
        child.view.frame = view.bounds
        child.didMove(toParent: self)
        hosted = child
    }

    func showMessage(_ newMessage: UIView) {
        removeContent()
        view.addSubview(newMessage)
        newMessage.frame = view.bounds
        message = newMessage
    }

    private func removeContent() {
        if let child = hosted {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
            hosted = nil
        }
        message?.removeFromSuperview()
        message = nil
    }
}

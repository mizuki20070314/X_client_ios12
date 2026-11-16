import UIKit

/// The search tab: a search field in the top bar, and the explore tabs (topics, trends, news, sports) below it.
final class SearchViewController: BaseViewController, TabRootScrollable, ModeSelectable {
    private let searchField = SearchFieldView()
    private let strip = TabStripView(titles: [], style: .scroll)
    private var pager: PagerViewController?
    private var loadingView: LoadingView?
    private var messageView: MessageView?
    /// The explore tabs, known from the first answer. Until then there is no strip and no pager.
    private var tabs: [ExploreTab] = []
    /// The answer to the first explore request. Its tab is shown from it, so that tab is not requested twice.
    private var prefetched: ExplorePage?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var topBarAccessoryHeight: CGFloat {
        return tabs.isEmpty ? 0 : Metrics.tabStripHeight
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        topBar.setAvatarButton()
        topBar.centerView = searchField
        topBar.centerViewFills = true
        searchField.onSubmit = { query in
            Router.openSearch(query: query)
        }

        strip.isHidden = true
        view.addSubview(strip)
        strip.onSelect = { [weak self] index in
            self?.pager?.setPage(index, animated: true)
        }

        showLoading()
        loadExplore()
    }

    override func layoutContent() {
        let width = view.bounds.width
        strip.frame = CGRect(x: 0, y: topBar.frame.maxY, width: width, height: Metrics.tabStripHeight)
        let top = contentTop
        let area = CGRect(x: 0, y: top, width: width, height: max(0, view.bounds.height - top))
        pager?.view.frame = area
        loadingView?.frame = area
        messageView?.frame = area
    }

    func scrollToTopOrRefresh() {
        guard let pager = pager else { return }
        (pager.page(at: pager.currentIndex) as? TimelineViewController)?.scrollToTopOrRefresh()
    }

    func selectMode(_ index: Int) {
        strip.selectedIndex = index
        pager?.setPage(index, animated: false)
    }

    // MARK: - explore

    private func loadExplore() {
        RelayClient.shared.explore(tab: nil) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let answer):
                self.showExplore(answer)
            case .failure(let error):
                self.showMessage(error.localizedDescription, retry: true)
            }
        }
    }

    private func showExplore(_ answer: ExplorePage) {
        loadingView?.removeFromSuperview()
        loadingView = nil
        messageView?.removeFromSuperview()
        messageView = nil
        guard !answer.tabs.isEmpty else {
            showMessage("表示できる話題がありません", retry: false)
            return
        }

        tabs = answer.tabs
        prefetched = answer
        strip.setTitles(tabs.map { $0.label })
        strip.isHidden = false
        let pager = PagerViewController(pageCount: tabs.count, makePage: { [weak self] index in
            return self?.makeExplorePage(index) ?? UIViewController()
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
        // the accessory height grows with the strip, so the content area moves down
        view.setNeedsLayout()
    }

    private func makeExplorePage(_ index: Int) -> UIViewController {
        guard tabs.indices.contains(index) else { return UIViewController() }
        let tabID = tabs[index].id
        return TimelineViewController(loader: { [weak self] cursor, completion in
            // the explore tabs have no further pages
            guard cursor == nil else {
                completion(.success(TimelinePage(json: JSON(nil))))
                return
            }
            if let answer = self?.takePrefetch(for: tabID) {
                // on a later turn, so the timeline has set its loading state before the rows arrive
                DispatchQueue.main.async {
                    completion(.success(answer.page))
                }
                return
            }
            RelayClient.shared.explore(tab: tabID) { result in
                completion(result.map { $0.page })
            }
        })
    }

    /// The first answer is handed out once, to the tab it answers.
    private func takePrefetch(for tabID: String) -> ExplorePage? {
        guard let answer = prefetched else { return nil }
        let answered = answer.tab ?? answer.tabs.first?.id
        guard answered == tabID else { return nil }
        prefetched = nil
        return answer
    }

    // MARK: - states

    private func showLoading() {
        messageView?.removeFromSuperview()
        messageView = nil
        let loading = LoadingView()
        view.addSubview(loading)
        loadingView = loading
        view.setNeedsLayout()
    }

    private func showMessage(_ text: String, retry: Bool) {
        loadingView?.removeFromSuperview()
        loadingView = nil
        messageView?.removeFromSuperview()
        var action: (() -> Void)?
        if retry {
            action = { [weak self] in
                self?.showLoading()
                self?.loadExplore()
            }
        }
        let message = MessageView(title: text, detail: nil, buttonTitle: retry ? "再試行" : nil, action: action)
        view.addSubview(message)
        messageView = message
        view.setNeedsLayout()
    }
}

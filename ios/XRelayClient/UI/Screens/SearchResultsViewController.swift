import UIKit

/// One search: the "top", "latest", "people" and "media" timelines, one per page of a pager. A new query from the field
/// replaces this screen's query and rebuilds the pager.
final class SearchResultsViewController: BaseViewController, ModeSelectable {
    private static let pages: [(title: String, mode: SearchMode)] = [
        (title: "話題", mode: .top),
        (title: "最新", mode: .latest),
        (title: "ユーザー", mode: .people),
        (title: "メディア", mode: .media)
    ]

    private(set) var query: String
    private let searchField = SearchFieldView()
    private let strip = TabStripView(titles: SearchResultsViewController.pages.map { $0.title }, style: .fill)
    private var pager: PagerViewController?
    /// The tab to show once the pager has a width (its pages are positioned by width).
    private var pendingPage: Int?

    init(query: String) {
        self.query = query
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
        topBar.centerView = searchField
        topBar.centerViewFills = true
        searchField.text = query
        searchField.onSubmit = { [weak self] text in
            self?.submit(text)
        }

        view.addSubview(strip)
        strip.onSelect = { [weak self] index in
            self?.pager?.setPage(index, animated: true)
        }
        rebuildPager(selected: 0)
    }

    override func layoutContent() {
        let width = view.bounds.width
        strip.frame = CGRect(x: 0, y: topBar.frame.maxY, width: width, height: Metrics.tabStripHeight)
        let top = contentTop
        pager?.view.frame = CGRect(x: 0, y: top, width: width, height: max(0, view.bounds.height - top))
        if let index = pendingPage, width > 0 {
            pendingPage = nil
            pager?.setPage(index, animated: false)
        }
    }

    func selectMode(_ index: Int) {
        strip.selectedIndex = index
        pager?.setPage(index, animated: false)
    }

    private func submit(_ text: String) {
        guard text != query else { return }
        query = text
        rebuildPager(selected: strip.selectedIndex)
    }

    /// A fresh pager, so that every page asks for the current query; the old one goes away with its pages.
    private func rebuildPager(selected: Int) {
        if let old = pager {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        let newPager = PagerViewController(pageCount: SearchResultsViewController.pages.count, makePage: { [weak self] index in
            return self?.makeResultPage(index) ?? UIViewController()
        })
        addChild(newPager)
        view.addSubview(newPager.view)
        newPager.didMove(toParent: self)
        newPager.onProgress = { [weak self] position in
            self?.strip.setProgress(position)
        }
        newPager.onPageChange = { [weak self] index in
            self?.strip.selectedIndex = index
        }
        pager = newPager
        strip.selectedIndex = selected
        pendingPage = selected
        view.setNeedsLayout()
    }

    private func makeResultPage(_ index: Int) -> UIViewController {
        guard SearchResultsViewController.pages.indices.contains(index) else { return UIViewController() }
        let mode = SearchResultsViewController.pages[index].mode
        let timeline = TimelineViewController(source: .search(query: query, mode: mode))
        timeline.emptyText = "「\(query)」の検索結果はありません"
        return timeline
    }
}

import UIKit

/// Implemented by the screens that pair a tab strip with a pager, so that the debug step `mode:<n>` can select a tab
/// (ui-wave2-notes.md).
protocol ModeSelectable: AnyObject {
    func selectMode(_ index: Int)
}

/// A horizontally paging scroll view with one child view controller per page (ui-spec §3.2). A page is created the
/// first time it is needed. The pager's view is the scroll view itself, so the owner sets its frame.
final class PagerViewController: UIViewController, UIScrollViewDelegate {
    /// The position as a fractional index (page 1.5 is half way from page 1 to page 2), while the pager moves.
    var onProgress: ((CGFloat) -> Void)?
    /// Called when the page the user is on changes, or when `setPage` changes it.
    var onPageChange: ((Int) -> Void)?

    private let pageCount: Int
    private let makePage: (Int) -> UIViewController
    private let scroller = UIScrollView()
    private var pages: [UIViewController?]
    /// The page the pager is on. `setPage` sets it at once, a drag sets it when the drag settles.
    private var committed = 0
    /// True when the offset must follow `committed` at the next layout (the width was not known yet).
    private var needsOffsetSync = true
    private var lastWidth: CGFloat = 0
    /// A (scroll view, gesture) pair whose pan already waits for the gesture.
    private struct LinkKey: Hashable {
        let scrollView: ObjectIdentifier
        let gesture: ObjectIdentifier
    }
    private var linkedGestures = Set<LinkKey>()

    init(pageCount: Int, makePage: @escaping (Int) -> UIViewController) {
        self.pageCount = max(0, pageCount)
        self.makePage = makePage
        pages = Array(repeating: nil, count: max(0, pageCount))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The page index; setting it is `setPage(_:animated: false)`.
    var currentIndex: Int {
        get {
            return committed
        }
        set {
            setPage(newValue, animated: false)
        }
    }

    /// Selects a page. The page is created if needed and starts its first load (a timeline loads when it is selected).
    func setPage(_ index: Int, animated: Bool) {
        guard pageCount > 0 else { return }
        let target = min(max(index, 0), pageCount - 1)
        let changed = target != committed
        committed = target
        loadViewIfNeeded()
        activate(target)
        let width = scroller.bounds.width
        if width > 0 {
            needsOffsetSync = false
            scroller.setContentOffset(CGPoint(x: CGFloat(target) * width, y: 0), animated: animated)
        } else {
            needsOffsetSync = true
        }
        if changed {
            onPageChange?(target)
        }
    }

    /// The page at `index`, created on demand; nil for an index outside the pager.
    func page(at index: Int) -> UIViewController? {
        guard index >= 0, index < pageCount else { return nil }
        loadViewIfNeeded()
        return ensurePage(index)
    }

    override func loadView() {
        view = scroller
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scroller.delegate = self
        scroller.isPagingEnabled = true
        scroller.bounces = false
        scroller.showsHorizontalScrollIndicator = false
        scroller.showsVerticalScrollIndicator = false
        scroller.scrollsToTop = false
        scroller.contentInsetAdjustmentBehavior = .never
        scroller.backgroundColor = Theme.palette.background
        // the page is created here, but loads only when the pager appears
        if pageCount > 0 {
            ensurePage(committed)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if pageCount > 0 {
            activate(committed)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshPages()
    }

    /// The pager can be attached to its parent after its view is already on screen: the links are checked then too.
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        refreshPages()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = scroller.bounds.size
        scroller.contentSize = CGSize(width: size.width * CGFloat(pageCount), height: size.height)
        for (index, page) in pages.enumerated() {
            page?.view.frame = CGRect(x: CGFloat(index) * size.width, y: 0, width: size.width, height: size.height)
        }
        if size.width != lastWidth {
            lastWidth = size.width
            needsOffsetSync = true
        }
        if needsOffsetSync && size.width > 0 {
            needsOffsetSync = false
            scroller.contentOffset = CGPoint(x: CGFloat(committed) * size.width, y: 0)
        }
        // a page may have got its scroll view since the last check (a host page fills in later)
        refreshPages()
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        onProgress?(scrollView.contentOffset.x / width)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleOnVisiblePage()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            settleOnVisiblePage()
        }
    }

    // MARK: - pages

    /// The page the offset has settled on becomes the committed one.
    private func settleOnVisiblePage() {
        let width = scroller.bounds.width
        guard width > 0, pageCount > 0 else { return }
        let rounded = (scroller.contentOffset.x / width).rounded()
        let index = min(max(Int(rounded), 0), pageCount - 1)
        guard index != committed else { return }
        committed = index
        activate(index)
        onPageChange?(index)
    }

    /// Makes the page at `index` the visible one: creates it, starts its first load, and sets the scroll flags.
    private func activate(_ index: Int) {
        guard index >= 0, index < pageCount else { return }
        let page = ensurePage(index)
        if let timeline = page as? TimelineViewController {
            timeline.loadIfNeeded()
        }
        refreshPages()
    }

    @discardableResult
    private func ensurePage(_ index: Int) -> UIViewController {
        if let existing = pages[index] {
            return existing
        }
        let page = makePage(index)
        pages[index] = page
        addChild(page)
        let size = scroller.bounds.size
        page.view.frame = CGRect(x: CGFloat(index) * size.width, y: 0, width: size.width, height: size.height)
        scroller.addSubview(page.view)
        page.didMove(toParent: self)
        refreshPages()
        return page
    }

    /// Only the visible page's scroll view scrolls to the top (the status bar tap). Every page's pan waits for the
    /// drawer's edge pan and the back swipe, so an edge swipe is not taken by the list.
    private func refreshPages() {
        guard isViewLoaded else { return }
        scroller.scrollsToTop = false
        linkEdgeGestures(scroller)
        for (index, page) in pages.enumerated() {
            guard let page = page, let scrollView = PagerViewController.firstScrollView(in: page.view) else {
                continue
            }
            scrollView.scrollsToTop = index == committed
            linkEdgeGestures(scrollView)
        }
    }

    /// Makes the pan gesture of `scrollView` wait for each edge gesture that matters here. Each pair is linked once.
    /// Nothing is linked while the view is off screen: the gestures are reached through the window.
    private func linkEdgeGestures(_ scrollView: UIScrollView) {
        guard scrollView.window != nil else { return }
        for edge in edgeGestures(above: scrollView) {
            let key = LinkKey(scrollView: ObjectIdentifier(scrollView), gesture: ObjectIdentifier(edge))
            guard !linkedGestures.contains(key) else { continue }
            scrollView.panGestureRecognizer.require(toFail: edge)
            linkedGestures.insert(key)
        }
    }

    /// The gestures the list's pan must wait for: the drawer's left-edge pan (the root controller exposes it), the back
    /// swipe of the enclosing navigation controller, and any other screen-edge pan among the views above `view`.
    private func edgeGestures(above view: UIView) -> [UIGestureRecognizer] {
        var found: [UIGestureRecognizer] = []
        if let drawerEdge = RootContainerViewController.current?.edgePanGesture {
            found.append(drawerEdge)
        }
        if let back = navigationController?.interactivePopGestureRecognizer {
            found.append(back)
        }
        var node: UIView? = view
        while let ancestor = node {
            let recognizers = ancestor.gestureRecognizers ?? []
            for recognizer in recognizers where recognizer is UIScreenEdgePanGestureRecognizer {
                found.append(recognizer)
            }
            node = ancestor.superview
        }
        // the same gesture can be found twice (the back swipe may sit on an ancestor view): keep the first
        var unique: [UIGestureRecognizer] = []
        var seen = Set<ObjectIdentifier>()
        for recognizer in found where !seen.contains(ObjectIdentifier(recognizer)) {
            seen.insert(ObjectIdentifier(recognizer))
            unique.append(recognizer)
        }
        return unique
    }

    /// The first scroll view of the page's own view tree, breadth first (a timeline's table view).
    private static func firstScrollView(in root: UIView) -> UIScrollView? {
        var queue: [UIView] = [root]
        var next = 0
        while next < queue.count {
            let view = queue[next]
            next += 1
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}

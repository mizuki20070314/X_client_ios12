import UIKit

/// The list engine behind every timeline (ui-spec.md §4.1): the first page, paging, "more" rows, pull to refresh,
/// the state views, duplicates and row taps. Main thread only.
final class TimelineViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    typealias Loader = (_ cursor: String?, _ completion: @escaping (Result<TimelinePage, Error>) -> Void) -> Void

    let tableView = UITableView(frame: .zero, style: .plain)
    var emptyText = "表示できるポストがありません"
    /// The profile header and the like: it becomes the table's header.
    var headerView: UIView? {
        didSet {
            tableView.tableHeaderView = headerView
            fitHeaderWidth()
        }
    }
    /// Room under the last row (for example the compose button).
    var extraBottomInset: CGFloat = 0 {
        didSet { applyInsets() }
    }
    /// Applied to every page before its rows are built.
    var transformItems: (([TimelineItem]) -> [TimelineItem])?
    /// Called with the first page as it is shown (after `transformItems`).
    var onFirstPage: ((TimelinePage) -> Void)?
    var onScroll: ((UIScrollView) -> Void)?
    /// True once the first page of the current source has arrived.
    private(set) var isLoaded = false

    private var loader: Loader
    /// What the list shows. The detail of a post (`.tweet`) applies the reply policy.
    private var source: TimelineSource?
    private var rows: [TimelineRow] = []
    /// Cursor of the next (older) page; nil at the end of the list.
    private var bottom: String?
    /// Bumped by every reload and every source change. An answer of an older generation is dropped.
    private var generation = 0
    private var didStartLoad = false
    private var isLoadingFirst = false
    /// A page at the bottom or a "more" row is in flight. Only one of them at a time.
    private var isLoadingMore = false
    private var firstError: Error?
    /// The configurationRevision of the last first-page request. A change reloads the list on appearance.
    private var loadedRevision: Int?
    private var lastWidth: CGFloat = 0
    private var lastHeight: CGFloat = 0
    private let refreshControl = UIRefreshControl()
    private let footerView = UIView(frame: .zero)
    private let footerSpinner = TimelineSpinner.make()
    private var loadingView: LoadingView?
    private var messageView: MessageView?
    private var notificationTokens: [NSObjectProtocol] = []

    // MARK: - Setup

    init(source: TimelineSource) {
        self.source = source
        loader = TimelineViewController.makeLoader(for: source)
        super.init(nibName: nil, bundle: nil)
        observeNotifications()
    }

    init(loader: @escaping Loader) {
        self.loader = loader
        super.init(nibName: nil, bundle: nil)
        observeNotifications()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = Theme.palette
        view.backgroundColor = palette.background
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.backgroundColor = palette.background
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .onDrag
        // rows have exact heights from their models; no estimates (ios-design.md §1)
        tableView.estimatedRowHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        if #available(iOS 11.0, *) {
            tableView.contentInsetAdjustmentBehavior = .never
        }
        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0
        }
        tableView.dataSource = self
        tableView.delegate = self
        registerCells()

        refreshControl.tintColor = palette.secondaryText
        refreshControl.addTarget(self, action: #selector(handleRefreshControl), for: .valueChanged)
        tableView.refreshControl = refreshControl

        footerView.addSubview(footerSpinner)
        view.addSubview(tableView)
        applyInsets()
        fitHeaderWidth()
        refreshStateViews()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // settings changed (another relay or profile): the rows came from the old one
        if let revision = loadedRevision, revision != RelayClient.shared.configurationRevision {
            reload()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
        fitHeaderWidth()
        let width = tableView.bounds.width
        if width > 0 && width != lastWidth {
            lastWidth = width
            // every row keeps one layout per width, so a new width asks for new heights
            tableView.reloadData()
            refreshStateViews()
        }
        layoutStateViews()
        // the first check of a list that was laid out late (or of a short list) happens here
        let height = tableView.bounds.height
        if height != lastHeight {
            lastHeight = height
            loadMoreIfNeeded()
        }
    }

    // MARK: - Public API

    /// Loads the first page once. The owner calls it when the list is first shown.
    func loadIfNeeded() {
        guard !didStartLoad else { return }
        loadFirstPage()
    }

    /// The first page again. A failure keeps the rows on screen and shows a toast.
    func reload() {
        loadFirstPage()
    }

    /// Switches what is shown: the rows are cleared and the first page of `source` loads at once.
    func setSource(_ source: TimelineSource) {
        self.source = source
        loader = TimelineViewController.makeLoader(for: source)
        resetState()
        tableView.reloadData()
        loadFirstPage()
    }

    /// At the top already: reloads. Otherwise scrolls to the top.
    func scrollToTopOrRefresh() {
        let topOffset = -tableView.contentInset.top
        if tableView.contentOffset.y <= topOffset + 1 {
            reload()
        } else {
            tableView.setContentOffset(CGPoint(x: 0, y: topOffset), animated: true)
        }
    }

    /// A post that was just created goes to the top of the list.
    func insertAtTop(_ tweet: Tweet) {
        guard isLoaded else { return }
        let key = TweetRow.key(for: tweet)
        guard !rows.contains(where: { $0.dedupeKey == key }) else { return }
        let entry = TweetEntry(tweet: tweet, contextKind: nil, contextText: nil, above: false, below: false,
                               focal: false)
        let row = TweetRow(entry: entry)
        let height = row.height(for: tableView.bounds.width)
        let wasAtTop = tableView.contentOffset.y <= -tableView.contentInset.top + 1
        rows.insert(row, at: 0)
        rowsChanged()
        if !wasAtTop {
            // the posts on screen stay where they are
            tableView.contentOffset.y += height
        }
        refreshStateViews()
    }

    // MARK: - Loading

    private static func makeLoader(for source: TimelineSource) -> Loader {
        return { cursor, completion in
            _ = RelayClient.shared.timeline(source, cursor: cursor, completion: completion)
        }
    }

    /// Forgets the rows and the paging state. Answers still on their way are dropped by the generation.
    private func resetState() {
        generation += 1
        rows = []
        bottom = nil
        isLoaded = false
        firstError = nil
        isLoadingFirst = false
        isLoadingMore = false
        loadedRevision = nil
        refreshControl.endRefreshing()
    }

    private func loadFirstPage() {
        didStartLoad = true
        generation += 1
        let token = generation
        loadedRevision = RelayClient.shared.configurationRevision
        isLoadingFirst = true
        isLoadingMore = false
        firstError = nil
        refreshStateViews()
        loader(nil) { [weak self] result in
            guard let self = self, token == self.generation else { return }
            self.isLoadingFirst = false
            self.refreshControl.endRefreshing()
            switch result {
            case .success(let page):
                self.applyFirstPage(page)
            case .failure(let error):
                self.applyFirstPageFailure(error)
            }
            self.refreshStateViews()
        }
    }

    private func applyFirstPage(_ page: TimelinePage) {
        let items = transformed(page.items)
        rows = TimelineRowFactory.rows(for: items)
        bottom = page.bottom
        isLoaded = true
        rowsChanged()
        var shown = page
        shown.items = items
        onFirstPage?(shown)
        scheduleMoreCheck()
    }

    private func applyFirstPageFailure(_ error: Error) {
        if rows.isEmpty {
            firstError = error
        } else {
            // a failed refresh keeps what is on screen
            Toast.show(error.localizedDescription)
        }
    }

    /// Checks for the next page after the current layout pass, when the content size is known.
    private func scheduleMoreCheck() {
        DispatchQueue.main.async { [weak self] in
            self?.loadMoreIfNeeded()
        }
    }

    /// Loads the next page when the list is within 800 pt of its end. Nothing else may be loading.
    private func loadMoreIfNeeded() {
        guard let cursor = bottom, !isLoadingFirst, !isLoadingMore else { return }
        // not laid out yet: the layout pass checks again
        guard tableView.bounds.height > 0 else { return }
        let remaining = tableView.contentSize.height - (tableView.contentOffset.y + tableView.bounds.height)
        guard remaining < 800 else { return }
        loadPage(cursor: cursor)
    }

    private func loadPage(cursor: String) {
        isLoadingMore = true
        let token = generation
        refreshStateViews()
        loader(cursor) { [weak self] result in
            guard let self = self, token == self.generation else { return }
            self.isLoadingMore = false
            switch result {
            case .success(let page):
                self.appendPage(page)
                self.refreshStateViews()
                self.scheduleMoreCheck()
            case .failure(let error):
                // the next scroll tries again
                Toast.show(error.localizedDescription)
                self.refreshStateViews()
            }
        }
    }

    private func appendPage(_ page: TimelinePage) {
        let fresh = newRows(from: page.items)
        // a page that adds no row is the end of the list
        bottom = fresh.isEmpty ? nil : page.bottom
        rows.append(contentsOf: fresh)
        rowsChanged()
    }

    /// Loads the cursor of a "more" row and puts the rows of its page in the row's place.
    func expandMore(_ row: MoreRow) {
        guard !row.isLoading, !isLoadingMore, !isLoadingFirst, rows.contains(where: { $0 === row }) else { return }
        isLoadingMore = true
        row.isLoading = true
        let token = generation
        tableView.reloadData()
        loader(row.cursor) { [weak self] result in
            guard let self = self, token == self.generation else { return }
            self.isLoadingMore = false
            row.isLoading = false
            switch result {
            case .success(let page):
                self.replaceMoreRow(row, with: page)
            case .failure(let error):
                Toast.show(error.localizedDescription)
                self.tableView.reloadData()
            }
            self.refreshStateViews()
        }
    }

    private func replaceMoreRow(_ row: MoreRow, with page: TimelinePage) {
        guard let index = rows.firstIndex(where: { $0 === row }) else { return }
        rows.replaceSubrange(index..<(index + 1), with: newRows(from: page.items))
        rowsChanged()
    }

    // MARK: - Rows

    /// The rows changed: the reply policy follows, then the table is redrawn.
    private func rowsChanged() {
        applyReplyPolicy()
        tableView.reloadData()
    }

    /// In the detail of a post (`.tweet`), a reply below the focal post shows no reply line when it answers the focal
    /// post, or the post directly above it in the same thread (ui-spec.md §4.3-4). The posts above the focal post
    /// (its ancestors) keep their reply line.
    private func applyReplyPolicy() {
        // keyed on the focal row, not on `source`: the detail screen loads through a custom loader (source is nil)
        guard let focalIndex = rows.firstIndex(where: { $0 is FocalTweetRow }),
              let focalID = tweetID(of: rows[focalIndex]) else {
            for case let row as TweetRow in rows {
                row.hidesReplyLine = false
            }
            return
        }
        for index in rows.indices {
            guard let row = rows[index] as? TweetRow else { continue }
            var hides = false
            if index > focalIndex {
                let replyTo = row.tweet.replyToID
                let aboveID = index > 0 ? tweetID(of: rows[index - 1]) : nil
                let answersFocal = replyTo == focalID
                let answersAbove = row.entry.above && replyTo != nil && replyTo == aboveID
                hides = answersFocal || answersAbove
            }
            row.hidesReplyLine = hides
        }
    }

    /// The rows of a page that is not the first one. A stand-alone post that is listed already is dropped;
    /// the posts of one conversation (above/below) are kept as the server sent them.
    private func newRows(from items: [TimelineItem]) -> [TimelineRow] {
        let listed = Set(rows.compactMap { $0.dedupeKey })
        let kept = transformed(items).filter { item -> Bool in
            guard case .tweet(let entry) = item, !entry.above, !entry.below else { return true }
            return !listed.contains(TweetRow.key(for: entry.tweet))
        }
        return TimelineRowFactory.rows(for: kept)
    }

    private func transformed(_ items: [TimelineItem]) -> [TimelineItem] {
        guard let transform = transformItems else { return items }
        return transform(items)
    }

    private func removeRows(ofTweet id: String) {
        let count = rows.count
        rows.removeAll { tweetID(of: $0) == id }
        guard rows.count != count else { return }
        rowsChanged()
        refreshStateViews()
    }

    private func tweetID(of row: TimelineRow) -> String? {
        if let tweetRow = row as? TweetRow {
            return tweetRow.tweet.id
        }
        if let focal = row as? FocalTweetRow {
            return focal.tweet.id
        }
        return nil
    }

    /// Re-applies the rows on screen (the repost context depends on the logged-in user).
    private func reconfigureVisibleRows() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard indexPath.row < rows.count, let cell = tableView.cellForRow(at: indexPath) else { continue }
            rows[indexPath.row].configure(cell, width: tableView.bounds.width)
        }
    }

    /// A post's layout changed (its translation came, went or changed): the rows that show it are laid out again and
    /// redrawn in place, without animation. A row above the screen changes the content below it, so the offset
    /// follows the change and the visible rows stay where they are (ui-spec.md §7).
    private func layoutDidChange(of tweet: Tweet) {
        let indexes = rows.indices.filter { tweetID(of: rows[$0]) == tweet.id }
        guard !indexes.isEmpty else { return }
        let width = tableView.bounds.width
        let firstVisible = tableView.indexPathsForVisibleRows?.map { $0.row }.min()
        var offsetChange: CGFloat = 0
        var paths: [IndexPath] = []
        for index in indexes {
            let row = rows[index]
            // the height before the change comes from the layout still cached for the row
            let before = row.height(for: width)
            dropLayout(of: row)
            let after = row.height(for: width)
            if let firstVisible = firstVisible, index < firstVisible {
                offsetChange += after - before
            }
            paths.append(IndexPath(row: index, section: 0))
        }
        UIView.performWithoutAnimation {
            tableView.reloadRows(at: paths, with: .none)
            if offsetChange != 0 {
                tableView.contentOffset.y += offsetChange
            }
        }
    }

    /// Forgets the layout of a row, so its next height query lays it out again.
    private func dropLayout(of row: TimelineRow) {
        if let tweetRow = row as? TweetRow {
            tweetRow.layoutCache = nil
        } else if let focal = row as? FocalTweetRow {
            focal.layoutCache = nil
        }
    }

    private func isHighlightable(_ row: TimelineRow) -> Bool {
        if row is HeaderRow || row is TombstoneRow || row is FocalTweetRow {
            return false
        }
        if let notification = row as? NotificationRow {
            return notification.hasTarget
        }
        return true
    }

    private func registerCells() {
        tableView.register(TweetCell.self, forCellReuseIdentifier: TimelineReuse.tweet)
        tableView.register(FocalTweetCell.self, forCellReuseIdentifier: TimelineReuse.focal)
        tableView.register(MoreCell.self, forCellReuseIdentifier: TimelineReuse.more)
        tableView.register(HeaderCell.self, forCellReuseIdentifier: TimelineReuse.header)
        tableView.register(TombstoneCell.self, forCellReuseIdentifier: TimelineReuse.tombstone)
        tableView.register(UserCell.self, forCellReuseIdentifier: TimelineReuse.user)
        tableView.register(NotificationCell.self, forCellReuseIdentifier: TimelineReuse.notification)
        tableView.register(TrendCell.self, forCellReuseIdentifier: TimelineReuse.trend)
    }

    private func observeNotifications() {
        let deleted = NotificationCenter.default.addObserver(forName: .tweetDeleted, object: nil,
                                                             queue: .main) { [weak self] note in
            guard let id = note.object as? String else { return }
            self?.removeRows(ofTweet: id)
        }
        let session = NotificationCenter.default.addObserver(forName: Session.didUpdate, object: nil,
                                                             queue: .main) { [weak self] _ in
            self?.reconfigureVisibleRows()
        }
        let layout = NotificationCenter.default.addObserver(forName: Tweet.layoutDidChange, object: nil,
                                                            queue: .main) { [weak self] note in
            guard let tweet = note.object as? Tweet else { return }
            self?.layoutDidChange(of: tweet)
        }
        notificationTokens = [deleted, session, layout]
    }

    // MARK: - Layout and state views

    private func applyInsets() {
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: extraBottomInset, right: 0)
        tableView.verticalScrollIndicatorInsets = tableView.contentInset
    }

    /// The header takes the table's width; UIKit lays it out again only when it is assigned.
    private func fitHeaderWidth() {
        guard let header = headerView, tableView.bounds.width > 0,
              header.frame.width != tableView.bounds.width else {
            return
        }
        header.frame.size.width = tableView.bounds.width
        tableView.tableHeaderView = header
    }

    /// The loading and message views cover the list below the header.
    private func layoutStateViews() {
        let top = tableView.tableHeaderView?.frame.height ?? 0
        let area = CGRect(x: 0, y: top, width: view.bounds.width, height: max(0, view.bounds.height - top))
        loadingView?.frame = area
        messageView?.frame = area
    }

    private func refreshStateViews() {
        guard isViewLoaded else { return }
        updateFooter()
        guard rows.isEmpty else {
            hideStateViews()
            return
        }
        if isLoadingFirst || isLoadingMore {
            showLoading()
        } else if let error = firstError {
            showMessage(error.localizedDescription, buttonTitle: "再試行") { [weak self] in
                self?.reload()
            }
        } else if isLoaded {
            showMessage(emptyText, buttonTitle: nil, action: nil)
        } else {
            hideStateViews()
        }
    }

    private func showLoading() {
        hideStateViews()
        let indicator = LoadingView(frame: .zero)
        view.addSubview(indicator)
        loadingView = indicator
        layoutStateViews()
    }

    private func showMessage(_ title: String, buttonTitle: String?, action: (() -> Void)?) {
        hideStateViews()
        let message = MessageView(title: title, detail: nil, buttonTitle: buttonTitle, action: action)
        view.addSubview(message)
        messageView = message
        layoutStateViews()
    }

    private func hideStateViews() {
        loadingView?.removeFromSuperview()
        loadingView = nil
        messageView?.removeFromSuperview()
        messageView = nil
    }

    /// The 44 pt footer with a spinner while a page is loading below the rows.
    private func updateFooter() {
        if isLoadingMore && !rows.isEmpty {
            footerView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 44)
            footerSpinner.center = CGPoint(x: footerView.bounds.midX, y: footerView.bounds.midY)
            footerSpinner.startAnimating()
            if tableView.tableFooterView !== footerView {
                tableView.tableFooterView = footerView
            }
        } else {
            footerSpinner.stopAnimating()
            if tableView.tableFooterView != nil {
                tableView.tableFooterView = nil
            }
        }
    }

    // MARK: - Pull to refresh

    @objc private func handleRefreshControl() {
        reload()
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: row.reuseIdentifier, for: indexPath)
        row.configure(cell, width: tableView.bounds.width)
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return rows[indexPath.row].height(for: tableView.bounds.width)
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        return isHighlightable(rows[indexPath.row])
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        rows[indexPath.row].didSelect(from: self)
        tableView.deselectRow(at: indexPath, animated: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScroll?(scrollView)
        loadMoreIfNeeded()
    }
}

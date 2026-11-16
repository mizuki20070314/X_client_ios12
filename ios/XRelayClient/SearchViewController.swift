import UIKit

final class SearchViewController: UITableViewController, UISearchBarDelegate {
    private let searchBar = UISearchBar()
    private let sortControl = UISegmentedControl(items: [SearchSort.top.title, SearchSort.latest.title])
    private let refresh = UIRefreshControl()
    private var posts: [TimelinePost] = []
    private var currentQuery = ""
    private var currentSort: SearchSort = .top

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "検索"
        view.backgroundColor = XTheme.background
        tableView.backgroundColor = XTheme.background
        tableView.separatorColor = XTheme.separator
        searchBar.placeholder = "Xを検索"
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.returnKeyType = .search
        searchBar.searchBarStyle = .minimal
        searchBar.backgroundImage = UIImage()
        searchBar.tintColor = XTheme.blue
        if #available(iOS 13.0, *) {
            searchBar.searchTextField.backgroundColor = XTheme.separator
            searchBar.searchTextField.layer.cornerRadius = 18
            searchBar.searchTextField.clipsToBounds = true
        }
        searchBar.delegate = self

        sortControl.selectedSegmentIndex = 0
        if #available(iOS 13.0, *) {
            sortControl.selectedSegmentTintColor = XTheme.blue
        }
        sortControl.setTitleTextAttributes([.foregroundColor: XTheme.secondaryText], for: .normal)
        sortControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        sortControl.addTarget(self, action: #selector(sortChanged), for: .valueChanged)

        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 102))
        header.addSubview(searchBar)
        header.addSubview(sortControl)
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        sortControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: header.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 58),
            sortControl.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 2),
            sortControl.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            sortControl.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            sortControl.heightAnchor.constraint(equalToConstant: 32)
        ])
        tableView.tableHeaderView = header
        tableView.register(PostCell.self, forCellReuseIdentifier: PostCell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 190
        refresh.addTarget(self, action: #selector(refreshResults), for: .valueChanged)
        tableView.refreshControl = refresh
        tableView.backgroundView = Self.emptyLabel("キーワードを入力して検索")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView, header.frame.width != tableView.bounds.width else { return }
        var frame = header.frame
        frame.size.width = tableView.bounds.width
        header.frame = frame
        tableView.tableHeaderView = header
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard let query = searchBar.text, !query.isEmpty else { return }
        searchBar.resignFirstResponder()
        performSearch(query)
    }

    @objc private func sortChanged() {
        currentSort = sortControl.selectedSegmentIndex == 0 ? .top : .latest
        if !currentQuery.isEmpty { performSearch(currentQuery) }
    }

    @objc private func refreshResults() {
        guard !currentQuery.isEmpty else {
            refresh.endRefreshing()
            return
        }
        performSearch(currentQuery)
    }

    private func performSearch(_ query: String) {
        currentQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentQuery.isEmpty else { return }
        guard RelayClient.shared.isConfigured else {
            refresh.endRefreshing()
            showError(APIError.server("設定からリレーURLと認証情報を設定してください。"))
            return
        }
        RelayClient.shared.search(currentQuery, sort: currentSort) { [weak self] result in
            guard let self = self else { return }
            self.refresh.endRefreshing()
            switch result {
            case .success(let posts):
                self.posts = posts
                self.tableView.backgroundView = posts.isEmpty ? Self.emptyLabel("検索結果がありません") : nil
                self.tableView.reloadData()
            case .failure(let error):
                self.showError(error)
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { posts.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: PostCell.reuseID, for: indexPath) as! PostCell
        let post = posts[indexPath.row]
        cell.configure(
            post,
            onReply: { [weak self] in self?.presentComposer(replyTo: post) },
            onRepost: { [weak self] in self?.showUnsupportedAction("リポスト") },
            onLike: { [weak self] in self?.showUnsupportedAction("いいね") },
            onViewDetails: { [weak self] in self?.showViewCount(post) },
            onShare: { [weak self] in self?.share(post) },
            onMore: { [weak self] in self?.showPostMenu(post) }
        )
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let url = posts[indexPath.row].permalink else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func presentComposer(replyTo post: TimelinePost) {
        let composer = ComposeViewController()
        composer.replyToPost = post
        composer.onPost = { [weak self] in
            guard let self = self, !self.currentQuery.isEmpty else { return }
            self.performSearch(self.currentQuery)
        }
        let navigationController = UINavigationController(rootViewController: composer)
        navigationController.modalPresentationStyle = .fullScreen
        present(navigationController, animated: true)
    }

    private func share(_ post: TimelinePost) {
        guard let url = post.permalink else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(activity, animated: true)
    }

    private func showPostMenu(_ post: TimelinePost) {
        let alert = UIAlertController(title: "ポスト", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "ポストを開く", style: .default) { [weak self] _ in
            guard let url = post.permalink else { return }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        })
        alert.addAction(UIAlertAction(title: "リンクを共有", style: .default) { [weak self] _ in self?.share(post) })
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(alert, animated: true)
    }

    private func showUnsupportedAction(_ name: String) {
        showError(APIError.server("\(name)機能は、現在のCGIではまだ利用できません。"), title: "未対応の機能")
    }

    private func showViewCount(_ post: TimelinePost) {
        guard let count = post.viewCount else {
            showUnsupportedAction("表示回数の詳細")
            return
        }
        let alert = UIAlertController(title: "表示回数", message: "\(count) 回", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "閉じる", style: .default))
        present(alert, animated: true)
    }

    private func showError(_ error: Error, title: String = "検索に失敗しました") {
        let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "閉じる", style: .default))
        present(alert, animated: true)
    }

    private static func emptyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = XTheme.secondaryText
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 15)
        label.layoutMargins = UIEdgeInsets(top: 0, left: 32, bottom: 0, right: 32)
        return label
    }
}

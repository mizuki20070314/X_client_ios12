import UIKit

final class TimelineViewController: UITableViewController {
    private var posts: [TimelinePost] = []
    private let refresh = UIRefreshControl()
    private let composeButton = UIButton(type: .system)
    private var loadedConfigurationRevision = -1

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = XTheme.background
        tableView.backgroundColor = XTheme.background
        tableView.separatorColor = XTheme.separator
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 72, bottom: 0, right: 0)
        navigationItem.title = "ホーム"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: XTheme.symbol("gearshape"),
            style: .plain,
            target: self,
            action: #selector(openSettings)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = "設定"
        tableView.register(PostCell.self, forCellReuseIdentifier: PostCell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 190
        refresh.addTarget(self, action: #selector(load), for: .valueChanged)
        tableView.refreshControl = refresh
        tableView.contentInset.bottom = 74
        tableView.scrollIndicatorInsets.bottom = 74
        setupComposeButton()

        if !RelayClient.shared.isConfigured {
            tableView.backgroundView = Self.emptyLabel("設定からリレーURLと認証情報を設定してください")
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard RelayClient.shared.isConfigured else {
            tableView.backgroundView = Self.emptyLabel("設定からリレーURLと認証情報を設定してください")
            return
        }
        guard loadedConfigurationRevision != RelayClient.shared.configurationRevision else { return }
        loadedConfigurationRevision = RelayClient.shared.configurationRevision
        load()
    }

    @objc private func load() {
        guard RelayClient.shared.isConfigured else {
            refresh.endRefreshing()
            tableView.backgroundView = Self.emptyLabel("設定からリレーURLと認証情報を設定してください")
            return
        }
        RelayClient.shared.getTimeline { [weak self] result in
            guard let self = self else { return }
            self.refresh.endRefreshing()
            switch result {
            case .success(let posts):
                self.posts = posts
                self.tableView.backgroundView = posts.isEmpty ? Self.emptyLabel("ポストがありません") : nil
                self.tableView.reloadData()
            case .failure(let error):
                self.showError(error, title: "読み込みに失敗しました")
            }
        }
    }

    @objc private func compose() {
        presentComposer(replyTo: nil)
    }

    private func presentComposer(replyTo post: TimelinePost?) {
        let composer = ComposeViewController()
        composer.replyToPost = post
        composer.onPost = { [weak self] in self?.load() }
        let navigationController = UINavigationController(rootViewController: composer)
        navigationController.modalPresentationStyle = .fullScreen
        present(navigationController, animated: true)
    }

    @objc private func openSettings() {
        if let tabs = tabBarController, let count = tabs.viewControllers?.count, count > 0 {
            tabs.selectedIndex = count - 1
        } else {
            navigationController?.pushViewController(SettingsViewController(), animated: true)
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
        openPost(posts[indexPath.row])
    }

    private func openPost(_ post: TimelinePost) {
        guard let url = post.permalink else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
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
        alert.addAction(UIAlertAction(title: "ポストを開く", style: .default) { [weak self] _ in self?.openPost(post) })
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

    private func showError(_ error: Error, title: String) {
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
        label.layoutMargins = UIEdgeInsets(top: 0, left: 36, bottom: 0, right: 36)
        return label
    }

    private func setupComposeButton() {
        composeButton.backgroundColor = XTheme.blue
        composeButton.tintColor = .white
        composeButton.layer.cornerRadius = 28
        composeButton.layer.shadowColor = UIColor.black.cgColor
        composeButton.layer.shadowOpacity = 0.22
        composeButton.layer.shadowRadius = 6
        composeButton.layer.shadowOffset = CGSize(width: 0, height: 3)
        composeButton.accessibilityLabel = "ポストを作成"
        if let image = XTheme.symbol("plus") {
            composeButton.setImage(image, for: .normal)
        } else {
            composeButton.setTitle("＋", for: .normal)
            composeButton.setTitleColor(.white, for: .normal)
            composeButton.titleLabel?.font = UIFont.systemFont(ofSize: 28, weight: .medium)
        }
        composeButton.addTarget(self, action: #selector(compose), for: .touchUpInside)
        composeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composeButton)
        NSLayoutConstraint.activate([
            composeButton.widthAnchor.constraint(equalToConstant: 56),
            composeButton.heightAnchor.constraint(equalToConstant: 56),
            composeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            composeButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18)
        ])
    }
}

final class PostCell: UITableViewCell {
    static let reuseID = "PostCell"
    private static let imageCache = NSCache<NSURL, UIImage>()
    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let verifiedLabel = UILabel()
    private let metadataLabel = UILabel()
    private let textLabelView = UILabel()
    private let mediaStack = UIStackView()
    private let actionsStack = UIStackView()
    private let moreButton = UIButton(type: .system)
    private var mediaHeightConstraint: NSLayoutConstraint?
    private var imageTasks: [URLSessionDataTask] = []
    private var mediaImageViews: [UIImageView] = []
    private var representedMediaURLs: [URL] = []
    private var representedAvatarURL: URL?
    private var onMore: (() -> Void)?

    var onReply: (() -> Void)?
    var onRepost: (() -> Void)?
    var onLike: (() -> Void)?
    var onViewDetails: (() -> Void)?
    var onShare: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = XTheme.background
        contentView.backgroundColor = XTheme.background
        selectionStyle = .none

        avatarView.backgroundColor = XTheme.avatarPlaceholder
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 22
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = UIFont.boldSystemFont(ofSize: 15)
        nameLabel.textColor = XTheme.text
        nameLabel.numberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        verifiedLabel.text = "✓"
        verifiedLabel.font = UIFont.boldSystemFont(ofSize: 12)
        verifiedLabel.textColor = XTheme.blue
        metadataLabel.font = UIFont.systemFont(ofSize: 13)
        metadataLabel.textColor = XTheme.secondaryText
        metadataLabel.numberOfLines = 1

        moreButton.setTitle("···", for: .normal)
        moreButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        moreButton.setTitleColor(XTheme.secondaryText, for: .normal)
        moreButton.accessibilityLabel = "ポストのメニュー"
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)

        textLabelView.font = UIFont.systemFont(ofSize: 15)
        textLabelView.textColor = XTheme.text
        textLabelView.numberOfLines = 0
        textLabelView.lineBreakMode = .byWordWrapping
        textLabelView.setContentCompressionResistancePriority(.required, for: .vertical)

        let titleRow = UIStackView(arrangedSubviews: [nameLabel, verifiedLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 4

        let headerText = UIStackView(arrangedSubviews: [titleRow, metadataLabel])
        headerText.axis = .vertical
        headerText.alignment = .leading
        headerText.spacing = 1

        let header = UIStackView(arrangedSubviews: [headerText, UIView(), moreButton])
        header.axis = .horizontal
        header.alignment = .top
        header.spacing = 4

        mediaStack.axis = .horizontal
        mediaStack.alignment = .fill
        mediaStack.distribution = .fillEqually
        mediaStack.spacing = 5
        mediaStack.clipsToBounds = true
        mediaStack.layer.cornerRadius = 13
        mediaStack.isHidden = true

        let replyButton = PostActionButton()
        replyButton.configure(symbol: "bubble", fallback: "返信", count: nil, accessibilityLabel: "返信") { [weak self] in self?.onReply?() }
        let repostButton = PostActionButton()
        repostButton.configure(symbol: "arrow.2.squarepath", fallback: "リポスト", count: nil, accessibilityLabel: "リポスト") { [weak self] in self?.onRepost?() }
        let likeButton = PostActionButton()
        likeButton.configure(symbol: "heart", fallback: "いいね", count: nil, accessibilityLabel: "いいね") { [weak self] in self?.onLike?() }
        let viewsButton = PostActionButton()
        viewsButton.configure(symbol: "chart.bar", fallback: "表示", count: nil, accessibilityLabel: "表示回数") { [weak self] in self?.onViewDetails?() }
        let shareButton = PostActionButton()
        shareButton.configure(symbol: "square.and.arrow.up", fallback: "共有", count: nil, accessibilityLabel: "共有") { [weak self] in self?.onShare?() }
        actionsStack.axis = .horizontal
        actionsStack.alignment = .center
        actionsStack.distribution = .fillEqually
        [replyButton, repostButton, likeButton, viewsButton, shareButton].forEach { actionsStack.addArrangedSubview($0) }

        let content = UIStackView(arrangedSubviews: [header, textLabelView, mediaStack, actionsStack])
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 7

        let row = UIStackView(arrangedSubviews: [avatarView, content])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        let mediaHeight = mediaStack.heightAnchor.constraint(equalToConstant: 0)
        mediaHeightConstraint = mediaHeight
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 44),
            avatarView.heightAnchor.constraint(equalToConstant: 44),
            moreButton.widthAnchor.constraint(equalToConstant: 32),
            moreButton.heightAnchor.constraint(equalToConstant: 28),
            mediaHeight,
            actionsStack.heightAnchor.constraint(equalToConstant: 30),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll()
        mediaStack.arrangedSubviews.forEach { view in
            mediaStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        mediaImageViews.removeAll()
        representedMediaURLs.removeAll()
        representedAvatarURL = nil
        avatarView.image = nil
        onReply = nil
        onRepost = nil
        onLike = nil
        onViewDetails = nil
        onShare = nil
        onMore = nil
    }

    func configure(
        _ post: TimelinePost,
        onReply: @escaping () -> Void,
        onRepost: @escaping () -> Void,
        onLike: @escaping () -> Void,
        onViewDetails: @escaping () -> Void,
        onShare: @escaping () -> Void,
        onMore: @escaping () -> Void
    ) {
        self.onReply = onReply
        self.onRepost = onRepost
        self.onLike = onLike
        self.onViewDetails = onViewDetails
        self.onShare = onShare
        self.onMore = onMore
        nameLabel.text = post.name
        verifiedLabel.isHidden = !post.isVerified
        let handle = post.handle.isEmpty ? "" : "@\(post.handle)"
        let timestamp = Self.timestamp(post.createdAt)
        metadataLabel.text = [handle, timestamp].filter { !$0.isEmpty }.joined(separator: " · ")
        textLabelView.text = post.text
        loadAvatar(from: post.avatarURL)
        loadMedia(post.media)
        let buttons = actionsStack.arrangedSubviews.compactMap { $0 as? PostActionButton }
        let counts: [Int?] = [post.replyCount, post.repostCount, post.likeCount, post.viewCount, nil]
        for (index, button) in buttons.enumerated() where index < counts.count {
            button.setCount(counts[index])
        }
        if buttons.count > 1 {
            buttons[1].setActive(post.isRetweeted, symbol: "arrow.2.squarepath", color: UIColor(red: 0.0, green: 0.58, blue: 0.36, alpha: 1))
        }
        if buttons.count > 2 {
            buttons[2].setActive(post.isLiked, symbol: "heart.fill", color: UIColor(red: 0.91, green: 0.22, blue: 0.36, alpha: 1))
        }
    }

    @objc private func moreTapped() { onMore?() }

    private func loadAvatar(from url: URL?) {
        representedAvatarURL = url
        avatarView.image = nil
        guard let url = url else { return }
        let cacheKey = url as NSURL
        if let cached = Self.imageCache.object(forKey: cacheKey) {
            avatarView.image = cached
            return
        }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            Self.imageCache.setObject(image, forKey: cacheKey)
            DispatchQueue.main.async {
                guard self?.representedAvatarURL == url else { return }
                self?.avatarView.image = image
            }
        }
        imageTasks.append(task)
        task.resume()
    }

    private func loadMedia(_ media: [TimelineMedia]) {
        let items = Array(media.prefix(4))
        representedMediaURLs = items.map { $0.url }
        mediaStack.isHidden = items.isEmpty
        mediaHeightConstraint?.constant = items.isEmpty ? 0 : 190
        for item in items {
            let imageView = UIImageView()
            imageView.backgroundColor = XTheme.separator
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.accessibilityLabel = item.altText.isEmpty ? "添付画像" : item.altText
            mediaStack.addArrangedSubview(imageView)
            mediaImageViews.append(imageView)
        }
        for (index, item) in items.enumerated() {
            let key = item.url as NSURL
            if let cached = Self.imageCache.object(forKey: key) {
                mediaImageViews[index].image = cached
                continue
            }
            let task = URLSession.shared.dataTask(with: item.url) { [weak self] data, _, _ in
                guard let data = data, let image = UIImage(data: data) else { return }
                Self.imageCache.setObject(image, forKey: key)
                DispatchQueue.main.async {
                    guard let self = self,
                          self.representedMediaURLs.indices.contains(index),
                          self.representedMediaURLs[index] == item.url else { return }
                    self.mediaImageViews[index].image = image
                }
            }
            imageTasks.append(task)
            task.resume()
        }
    }

    private static func timestamp(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "今" }
        if seconds < 3_600 { return "\(seconds / 60)分" }
        if seconds < 86_400 { return "\(seconds / 3_600)時間" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

private final class PostActionButton: UIButton {
    private var fallbackTitle = ""
    private var normalSymbol = ""
    private var value: Int?
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentHorizontalAlignment = .left
        titleLabel?.font = UIFont.systemFont(ofSize: 12)
        setTitleColor(XTheme.secondaryText, for: .normal)
        tintColor = XTheme.secondaryText
        imageView?.contentMode = .scaleAspectFit
        contentEdgeInsets = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        symbol: String,
        fallback: String,
        count: Int?,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        fallbackTitle = fallback
        normalSymbol = symbol
        value = count
        self.action = action
        self.accessibilityLabel = accessibilityLabel
        if let image = XTheme.symbol(symbol) {
            setImage(image, for: .normal)
            imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 5)
        } else {
            setImage(nil, for: .normal)
        }
        refreshTitle()
    }

    func setCount(_ count: Int?) {
        value = count
        refreshTitle()
    }

    func setActive(_ active: Bool, symbol: String, color: UIColor) {
        let color = active ? color : XTheme.secondaryText
        let symbolName = active ? symbol : normalSymbol
        if let image = XTheme.symbol(symbolName) {
            setImage(image, for: .normal)
        } else {
            setImage(nil, for: .normal)
        }
        tintColor = color
        setTitleColor(color, for: .normal)
        refreshTitle()
    }

    @objc private func tapped() { action?() }

    private func refreshTitle() {
        if image(for: .normal) == nil {
            let countText = value.map { " \(Self.compactCount($0))" } ?? ""
            setTitle(fallbackTitle + countText, for: .normal)
        } else if let value = value, value > 0 {
            setTitle(Self.compactCount(value), for: .normal)
        } else {
            setTitle(nil, for: .normal)
        }
    }

    private static func compactCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
        if value >= 10_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000).replacingOccurrences(of: ".0K", with: "K")
        }
        return String(value)
    }
}

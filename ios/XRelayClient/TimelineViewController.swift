import UIKit

final class TimelineViewController: UITableViewController {
    private var posts: [TimelinePost] = []
    private let refresh = UIRefreshControl()
    private let composeButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        tableView.backgroundColor = .white
        tableView.separatorColor = XTheme.separator
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 72, bottom: 0, right: 0)
        let logo = UILabel()
        logo.text = "X"
        logo.textColor = XTheme.text
        logo.font = UIFont.boldSystemFont(ofSize: 25)
        logo.accessibilityLabel = "X ホーム"
        navigationItem.titleView = logo
        tableView.register(PostCell.self, forCellReuseIdentifier: PostCell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
        refresh.addTarget(self, action: #selector(load), for: .valueChanged)
        tableView.refreshControl = refresh
        tableView.contentInset.bottom = 74
        tableView.scrollIndicatorInsets.bottom = 74
        setupComposeButton()

        if RelayClient.shared.isConfigured {
            load()
        } else {
            tableView.backgroundView = Self.emptyLabel("設定からリレーURLと認証情報を設定してください")
        }
    }

    @objc private func load() {
        RelayClient.shared.getTimeline { [weak self] result in
            self?.refresh.endRefreshing()
            switch result {
            case .success(let posts):
                self?.posts = posts
                self?.tableView.backgroundView = posts.isEmpty ? Self.emptyLabel("ポストがありません") : nil
                self?.tableView.reloadData()
            case .failure(let error):
                self?.showError(error, title: "読み込みに失敗しました")
            }
        }
    }

    @objc private func compose() {
        let composer = ComposeViewController()
        composer.onPost = { [weak self] in self?.load() }
        let navigationController = UINavigationController(rootViewController: composer)
        navigationController.modalPresentationStyle = .fullScreen
        present(navigationController, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { posts.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: PostCell.reuseID, for: indexPath) as! PostCell
        cell.configure(posts[indexPath.row])
        return cell
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
    private let handleLabel = UILabel()
    private let moreLabel = UILabel()
    private let textLabelView = UILabel()
    private var imageTask: URLSessionDataTask?
    private var representedAvatarURL: URL?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .white
        selectionStyle = .none

        avatarView.backgroundColor = XTheme.avatarPlaceholder
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 22
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = UIFont.boldSystemFont(ofSize: 16)
        nameLabel.textColor = XTheme.text
        nameLabel.numberOfLines = 1
        handleLabel.font = UIFont.systemFont(ofSize: 14)
        handleLabel.textColor = XTheme.secondaryText
        handleLabel.numberOfLines = 1
        handleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        moreLabel.text = "···"
        moreLabel.font = UIFont.boldSystemFont(ofSize: 16)
        moreLabel.textColor = XTheme.secondaryText
        moreLabel.textAlignment = .right
        moreLabel.setContentHuggingPriority(.required, for: .horizontal)

        textLabelView.font = UIFont.systemFont(ofSize: 15)
        textLabelView.textColor = XTheme.text
        textLabelView.numberOfLines = 0
        textLabelView.lineBreakMode = .byWordWrapping
        textLabelView.setContentCompressionResistancePriority(.required, for: .vertical)

        let header = UIStackView(arrangedSubviews: [nameLabel, handleLabel, UIView(), moreLabel])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 5

        let content = UIStackView(arrangedSubviews: [header, textLabelView])
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 5

        let row = UIStackView(arrangedSubviews: [avatarView, content])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 44),
            avatarView.heightAnchor.constraint(equalToConstant: 44),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        representedAvatarURL = nil
        avatarView.image = nil
    }

    func configure(_ post: TimelinePost) {
        nameLabel.text = post.name
        handleLabel.text = post.handle.isEmpty ? "" : "@\(post.handle)"
        textLabelView.text = post.text
        loadAvatar(from: post.avatarURL)
    }

    private func loadAvatar(from url: URL?) {
        representedAvatarURL = url
        avatarView.image = nil
        guard let url = url else { return }
        let cacheKey = url as NSURL
        if let cached = Self.imageCache.object(forKey: cacheKey) {
            avatarView.image = cached
            return
        }
        imageTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            Self.imageCache.setObject(image, forKey: cacheKey)
            DispatchQueue.main.async {
                guard self?.representedAvatarURL == url else { return }
                self?.avatarView.image = image
            }
        }
        imageTask?.resume()
    }
}

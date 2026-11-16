import UIKit

/// A deliberately plain screen that proves the data layer on CI: the home timeline as two-line rows, and a first row
/// that opens the icon gallery. It uses stock UIKit only (no Theme, no Icons), so it looks the same on every iOS.
final class PlaceholderViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private var posts: [Tweet] = []
    /// Shown in the status row while there are no posts: loading, the error, or the empty message.
    private var statusText = "読み込み中…"

    private static let nameFont = UIFont.systemFont(ofSize: 14, weight: .bold)
    private static let textFont = UIFont.systemFont(ofSize: 14)
    private static let galleryRowHeight: CGFloat = 52

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ホーム"
        view.backgroundColor = UIColor.white
        table.backgroundColor = UIColor.white
        table.dataSource = self
        table.delegate = self
        // rows and headers have fixed heights (see heightForRowAt); no estimates, no automatic sizing
        table.estimatedRowHeight = 0
        table.estimatedSectionHeaderHeight = 0
        table.estimatedSectionFooterHeight = 0
        if #available(iOS 11.0, *) {
            table.contentInsetAdjustmentBehavior = .never
        }
        if #available(iOS 15.0, *) {
            table.sectionHeaderTopPadding = 0
        }
        view.addSubview(table)
        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        var insets = UIEdgeInsets.zero
        if #available(iOS 11.0, *) {
            insets = view.safeAreaInsets
        }
        table.frame = view.bounds
        table.contentInset = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        // iOS 11.1+, so it needs no #available check on an iOS 12 target
        table.verticalScrollIndicatorInsets = table.contentInset
    }

    private func load() {
        RelayClient.shared.timeline(.home(following: false), cursor: nil) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let page):
                self.posts = PlaceholderViewController.tweets(in: page)
                self.statusText = "ポストがありません。"
            case .failure(let error):
                self.posts = []
                self.statusText = error.localizedDescription
            }
            self.table.reloadData()
        }
    }

    private static func tweets(in page: TimelinePage) -> [Tweet] {
        var tweets: [Tweet] = []
        for item in page.items {
            if case .tweet(let entry) = item {
                tweets.append(entry.tweet)
            }
        }
        return tweets
    }

    // MARK: - table

    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    /// Row 0 is the icon gallery; then the posts, or one status row while there are none.
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1 + max(1, posts.count)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row == 0 {
            return galleryCell(tableView)
        }
        if posts.isEmpty {
            return statusCell(tableView)
        }
        return postCell(tableView, posts[indexPath.row - 1])
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.row == 0 || posts.isEmpty {
            return PlaceholderViewController.galleryRowHeight
        }
        return PlaceholderViewController.height(of: posts[indexPath.row - 1], width: tableView.bounds.width)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == 0 {
            let gallery = IconGalleryViewController()
            gallery.modalPresentationStyle = .fullScreen
            present(gallery, animated: true, completion: nil)
        }
    }

    private func galleryCell(_ tableView: UITableView) -> UITableViewCell {
        let identifier = "gallery"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .default, reuseIdentifier: identifier)
        cell.textLabel?.text = "アイコン一覧"
        cell.textLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        cell.textLabel?.textColor = UIColor.black
        cell.backgroundColor = UIColor.white
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func statusCell(_ tableView: UITableView) -> UITableViewCell {
        let identifier = "status"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .default, reuseIdentifier: identifier)
        cell.textLabel?.text = statusText
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.font = PlaceholderViewController.textFont
        cell.textLabel?.textColor = UIColor.darkGray
        cell.backgroundColor = UIColor.white
        cell.selectionStyle = .none
        return cell
    }

    /// Two lines: "name @handle", then the text.
    private func postCell(_ tableView: UITableView, _ post: Tweet) -> UITableViewCell {
        let identifier = "post"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        cell.textLabel?.text = "\(post.user.name) @\(post.user.handle)"
        cell.textLabel?.font = PlaceholderViewController.nameFont
        cell.textLabel?.textColor = UIColor.black
        cell.detailTextLabel?.text = post.text
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.font = PlaceholderViewController.textFont
        cell.detailTextLabel?.textColor = UIColor.black
        cell.backgroundColor = UIColor.white
        cell.selectionStyle = .none
        return cell
    }

    /// The height of a post row, measured from its text (the rows are not Auto Layout).
    private static func height(of post: Tweet, width: CGFloat) -> CGFloat {
        let textWidth = max(120, width - 30)
        let bounds = NSString(string: post.text).boundingRect(
            with: CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: textFont],
            context: nil
        )
        // top and bottom padding, the name line and the gap above the text
        return 50 + ceil(bounds.height)
    }
}

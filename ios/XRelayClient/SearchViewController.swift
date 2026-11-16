import UIKit

final class SearchViewController: UITableViewController, UISearchBarDelegate {
    private let searchBar = UISearchBar()
    private var posts: [TimelinePost] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "検索"
        view.backgroundColor = .white
        tableView.backgroundColor = .white
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
        tableView.tableHeaderView = searchBar
        tableView.register(PostCell.self, forCellReuseIdentifier: PostCell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard let query = searchBar.text, !query.isEmpty else { return }
        searchBar.resignFirstResponder()
        RelayClient.shared.search(query) { [weak self] result in
            switch result {
            case .success(let posts):
                self?.posts = posts
                if posts.isEmpty {
                    let label = UILabel()
                    label.text = "検索結果がありません"
                    label.textColor = XTheme.secondaryText
                    label.textAlignment = .center
                    self?.tableView.backgroundView = label
                } else {
                    self?.tableView.backgroundView = nil
                }
                self?.tableView.reloadData()
            case .failure(let error):
                let alert = UIAlertController(title: "検索に失敗しました", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "閉じる", style: .default))
                self?.present(alert, animated: true)
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { posts.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: PostCell.reuseID, for: indexPath) as! PostCell
        cell.configure(posts[indexPath.row])
        return cell
    }
}

import UIKit

final class SettingsViewController: UITableViewController {
    private let urlField = UITextField()
    private let profileField = UITextField()
    private let tokenField = UITextField()
    private var isTestingConnection = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "設定"
        view.backgroundColor = XTheme.background
        tableView.backgroundColor = XTheme.background
        tableView.separatorColor = XTheme.separator
        urlField.text = RelayClient.shared.baseURL.absoluteString
        urlField.placeholder = "https://relay.example.com"
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.clearButtonMode = .whileEditing
        urlField.accessibilityLabel = "リレーURL"
        profileField.text = RelayClient.shared.profileName
        profileField.placeholder = "account1（任意）"
        profileField.autocapitalizationType = .none
        profileField.autocorrectionType = .no
        profileField.clearButtonMode = .whileEditing
        profileField.accessibilityLabel = "プロフィール名"
        tokenField.placeholder = "32文字以上のBearerトークン"
        tokenField.autocapitalizationType = .none
        tokenField.autocorrectionType = .no
        tokenField.isSecureTextEntry = true
        tokenField.clearButtonMode = .whileEditing
        tokenField.accessibilityLabel = "Bearerトークン"
        [urlField, profileField, tokenField].forEach {
            $0.textColor = XTheme.text
            $0.font = UIFont.systemFont(ofSize: 14)
        }
        do {
            tokenField.text = try RelayClient.shared.loadBearerToken()
        } catch {
            showAlert(title: "Keychainエラー", message: error.localizedDescription)
        }
        tableView.rowHeight = 58
        tableView.tableFooterView = UIView()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 5 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = XTheme.background
        switch indexPath.row {
        case 0:
            cell.textLabel?.text = "リレーURL"
            cell.textLabel?.textColor = XTheme.text
            cell.accessoryView = urlField
            urlField.frame = CGRect(x: 0, y: 0, width: 210, height: 36)
            cell.selectionStyle = .none
        case 1:
            cell.textLabel?.text = "プロフィール"
            cell.textLabel?.textColor = XTheme.text
            cell.accessoryView = profileField
            profileField.frame = CGRect(x: 0, y: 0, width: 170, height: 36)
            cell.selectionStyle = .none
        case 2:
            cell.textLabel?.text = "Bearerトークン"
            cell.textLabel?.textColor = XTheme.text
            cell.accessoryView = tokenField
            tokenField.frame = CGRect(x: 0, y: 0, width: 210, height: 36)
            cell.selectionStyle = .none
        case 3:
            cell.textLabel?.text = isTestingConnection ? "接続確認中…" : "接続テスト"
            cell.textLabel?.textAlignment = .center
            cell.textLabel?.textColor = XTheme.blue
            cell.textLabel?.font = UIFont.boldSystemFont(ofSize: 16)
            cell.selectionStyle = isTestingConnection ? .none : .default
        case 4:
            cell.textLabel?.text = "保存"
            cell.textLabel?.textAlignment = .center
            cell.textLabel?.textColor = XTheme.blue
            cell.textLabel?.font = UIFont.boldSystemFont(ofSize: 16)
            cell.selectionStyle = .default
        default:
            break
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.row {
        case 3:
            testConnection()
        case 4:
            saveSettings()
        default:
            break
        }
    }

    private func testConnection() {
        guard !isTestingConnection else { return }
        guard let url = validatedRelayURL() else { return }
        guard hasValidTokenLength() else { return }
        isTestingConnection = true
        tableView.reloadRows(at: [IndexPath(row: 3, section: 0)], with: .none)
        RelayClient.shared.testConnection(
            baseURL: url,
            profileName: profileField.text,
            bearerToken: tokenField.text
        ) { [weak self] result in
            guard let self = self else { return }
            self.isTestingConnection = false
            self.tableView.reloadRows(at: [IndexPath(row: 3, section: 0)], with: .none)
            switch result {
            case .success(let profiles):
                let selectedProfile = self.profileField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !selectedProfile.isEmpty && !profiles.contains(selectedProfile) {
                    self.showAlert(title: "プロフィールが見つかりません", message: "利用可能: \(profiles.joined(separator: ", "))")
                } else {
                    self.showAlert(title: "接続成功", message: "利用可能なプロフィール: \(profiles.joined(separator: ", "))")
                }
            case .failure(let error):
                self.showAlert(title: "接続に失敗しました", message: error.localizedDescription)
            }
        }
    }

    private func saveSettings() {
        guard let url = validatedRelayURL() else { return }
        guard hasValidTokenLength() else { return }
        do {
            try RelayClient.shared.saveSettings(
                baseURL: url,
                profileName: profileField.text,
                bearerToken: tokenField.text
            )
            if let tabBarController = tabBarController {
                tabBarController.selectedIndex = 0
            } else {
                navigationController?.popViewController(animated: true)
            }
        } catch {
            showAlert(title: "保存に失敗しました", message: error.localizedDescription)
        }
    }

    private func validatedRelayURL() -> URL? {
        let value = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              Self.isSafeBasePath(components.path),
              let url = components.url else {
            showAlert(title: "URLエラー", message: APIError.invalidURL.localizedDescription)
            return nil
        }
        if scheme == "http" && !Self.isTrustedLocalHost(host) {
            showAlert(
                title: "HTTPSが必要です",
                message: "インターネット上のリレーにはhttps://を使用してください。HTTPはlocalhostまたは信頼できるプライベートLANでの開発時だけ利用できます。"
            )
            return nil
        }
        return url
    }

    private static func isSafeBasePath(_ path: String) -> Bool {
        guard !path.contains("//") else { return false }
        return path.split(separator: "/").allSatisfy { segment in
            segment.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        }
    }

    private func hasValidTokenLength() -> Bool {
        let token = tokenField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard token.isEmpty || token.count >= 32 else {
            showAlert(title: "トークンエラー", message: "Bearerトークンは32文字以上にしてください。")
            return false
        }
        return true
    }

    private static func isTrustedLocalHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if normalized == "localhost" || normalized.hasSuffix(".localhost") || normalized.hasSuffix(".local") || normalized == "::1" {
            return true
        }
        let octets = normalized.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        if octets[0] == 10 || octets[0] == 127 { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        return octets[0] == 172 && (16...31).contains(octets[1])
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "閉じる", style: .default))
        present(alert, animated: true)
    }
}

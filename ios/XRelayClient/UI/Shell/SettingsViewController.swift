import UIKit

/// The settings screen (ui-spec §5.9). The relay checks and their messages are v1's (git 6ff5538,
/// SettingsViewController.swift), unchanged.
final class SettingsViewController: BaseViewController, UITextFieldDelegate {
    private let isInitialSetup: Bool
    private let scrollView = UIScrollView()
    private let introLabel = UILabel()
    private let urlField = UITextField()
    private let profileField = UITextField()
    private let keyField = UITextField()
    private let urlRow = SettingsRowControl(frame: .zero)
    private let profileRow = SettingsRowControl(frame: .zero)
    private let keyRow = SettingsRowControl(frame: .zero)
    private let testRow = SettingsRowControl(frame: .zero)
    private let saveRow = SettingsRowControl(frame: .zero)
    private let themeRow = SettingsRowControl(frame: .zero)
    private let cacheRow = SettingsRowControl(frame: .zero)
    private let versionRow = SettingsRowControl(frame: .zero)
    private let noteLabel = UILabel()
    /// Section titles in order: relay, display, data, about.
    private var headers: [UILabel] = []
    private var isTestingConnection = false
    /// How much of the scroll view the keyboard covers.
    private var keyboardInset: CGFloat = 0
    /// The stored key could not be read when the screen opened; saving an empty key would clear it.
    private var keyReadFailed = false

    init(isInitialSetup: Bool = false) {
        self.isInitialSetup = isInitialSetup
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if isInitialSetup {
            topBar.setCloseButton { [weak self] in
                self?.dismiss(animated: true, completion: nil)
            }
        } else {
            topBar.setBackButton { [weak self] in
                self?.navigationController?.popViewController(animated: true)
            }
        }
        topBar.title = "設定とプライバシー"

        if #available(iOS 11.0, *) {
            scrollView.contentInsetAdjustmentBehavior = .never
        }
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        view.addSubview(scrollView)

        if isInitialSetup {
            introLabel.text = "はじめに、リレーサーバーのURLとCGIキーを設定してください。"
            introLabel.font = Theme.font(15)
            introLabel.textColor = Theme.palette.secondaryText
            introLabel.numberOfLines = 0
            scrollView.addSubview(introLabel)
        }

        configureField(urlField, placeholder: "https://example.com/xclient")
        urlField.keyboardType = .URL
        configureField(profileField, placeholder: "account1（任意）")
        configureField(keyField, placeholder: "32文字以上のCGIキー")
        keyField.isSecureTextEntry = true

        // the saved settings; without a relay the URL stays empty rather than showing the local default
        if RelayClient.shared.isConfigured {
            urlField.text = RelayClient.shared.baseURL.absoluteString
        }
        profileField.text = RelayClient.shared.profileName
        // A failed read is not something the user can act on: the field stays empty, and no alert is shown.
        do {
            keyField.text = try RelayClient.shared.loadBearerToken()
        } catch {
            keyReadFailed = true
        }

        urlRow.configureField(title: "リレーURL", field: urlField)
        profileRow.configureField(title: "プロフィール名", field: profileField)
        keyRow.configureField(title: "CGIキー", field: keyField)
        testRow.configureAction(title: "接続テスト")
        testRow.onTap = { [weak self] in self?.testConnection() }
        saveRow.configureAction(title: "保存")
        saveRow.onTap = { [weak self] in self?.saveSettings() }
        themeRow.configureValue(title: "ダークモード", value: ThemeSheet.name(for: ThemeSheet.effectiveMode))
        themeRow.onTap = { [weak self] in ThemeSheet.present(from: self) }
        cacheRow.configureValue(title: "画像キャッシュを削除",
                                value: SettingsViewController.sizeText(ImageLoader.shared.diskUsage))
        cacheRow.onTap = { [weak self] in self?.clearImageCache() }
        versionRow.configureValue(title: "バージョン", value: SettingsViewController.versionText)

        for row in [urlRow, profileRow, keyRow, testRow, saveRow, themeRow, cacheRow, versionRow] {
            scrollView.addSubview(row)
        }

        for title in ["リレーサーバー", "画面表示", "データ", "このアプリについて"] {
            let header = UILabel()
            header.text = title
            header.font = Theme.font(13, .bold)
            header.textColor = Theme.palette.secondaryText
            scrollView.addSubview(header)
            headers.append(header)
        }

        noteLabel.text = "X の非公式クライアントです。X Corp. とは関係ありません。"
        noteLabel.font = Theme.font(13)
        noteLabel.textColor = Theme.palette.secondaryText
        noteLabel.numberOfLines = 0
        scrollView.addSubview(noteLabel)

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    override func layoutContent() {
        // the form lives in the content column (ui-spec §8.3): when it is presented full screen on a large screen,
        // its scroll view is the column; inside a tab the column is the view itself
        let column = Metrics.column(in: view.bounds)
        let width = column.width
        let pad = Metrics.pad(width)
        scrollView.frame = CGRect(x: column.minX, y: contentTop, width: width,
                                  height: max(0, view.bounds.height - contentTop))
        scrollView.contentInset.bottom = keyboardInset
        scrollView.scrollIndicatorInsets.bottom = keyboardInset

        var y: CGFloat = 8
        if isInitialSetup {
            let textWidth = width - 2 * pad
            let height = ceil(introLabel.sizeThatFits(CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)).height)
            introLabel.frame = CGRect(x: pad, y: 16, width: textWidth, height: height)
            y = 16 + height + 8
        }

        y = placeHeader(headers[0], at: y, width: width)
        for row in [urlRow, profileRow, keyRow, testRow, saveRow] {
            y = placeRow(row, at: y, width: width)
        }
        y = placeHeader(headers[1], at: y, width: width)
        y = placeRow(themeRow, at: y, width: width)
        y = placeHeader(headers[2], at: y, width: width)
        y = placeRow(cacheRow, at: y, width: width)
        y = placeHeader(headers[3], at: y, width: width)
        y = placeRow(versionRow, at: y, width: width)

        let noteWidth = width - 2 * pad
        let noteHeight = ceil(noteLabel.sizeThatFits(CGSize(width: noteWidth, height: CGFloat.greatestFiniteMagnitude)).height)
        noteLabel.frame = CGRect(x: pad, y: y + 8, width: noteWidth, height: noteHeight)
        scrollView.contentSize = CGSize(width: width, height: y + 8 + noteHeight + 24)
    }

    /// A section title: 36 pt including the space above it.
    private func placeHeader(_ label: UILabel, at y: CGFloat, width: CGFloat) -> CGFloat {
        let pad = Metrics.pad(width)
        label.frame = CGRect(x: pad, y: y + 14, width: width - 2 * pad, height: 18)
        return y + 36
    }

    /// A row of 52 pt, edge to edge. Its parts are placed by the row itself.
    private func placeRow(_ row: SettingsRowControl, at y: CGFloat, width: CGFloat) -> CGFloat {
        row.frame = CGRect(x: 0, y: y, width: width, height: 52)
        return y + 52
    }

    private func configureField(_ field: UITextField, placeholder: String) {
        let palette = Theme.palette
        field.placeholder = placeholder
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.tintColor = palette.accent
        field.delegate = self
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: - keyboard

    /// The scroll view keeps the area under the keyboard free, and the field being edited scrolls above it.
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        guard let frame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        let keyboardTop = view.convert(frame, from: nil).minY
        keyboardInset = max(0, view.bounds.maxY - keyboardTop)
        let options = UIView.AnimationOptions(rawValue: curve << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options, animations: {
            self.scrollView.contentInset.bottom = self.keyboardInset
            self.scrollView.scrollIndicatorInsets.bottom = self.keyboardInset
        }, completion: { _ in
            self.revealFocusedField()
        })
    }

    private func revealFocusedField() {
        let fields = [urlField, profileField, keyField]
        guard let focused = fields.first(where: { $0.isFirstResponder }) else { return }
        let rect = focused.convert(focused.bounds, to: scrollView).insetBy(dx: 0, dy: -24)
        scrollView.scrollRectToVisible(rect, animated: true)
    }

    // MARK: - actions

    private func testConnection() {
        guard !isTestingConnection else { return }
        guard let url = validatedRelayURL() else { return }
        guard hasValidTokenLength() else { return }
        isTestingConnection = true
        updateTestRow()
        RelayClient.shared.testConnection(
            baseURL: url,
            profileName: profileField.text,
            bearerToken: keyField.text
        ) { [weak self] result in
            guard let self = self else { return }
            self.isTestingConnection = false
            self.updateTestRow()
            switch result {
            case .success(let profiles):
                self.showProfiles(profiles)
            case .failure(let error):
                self.showAlert(title: "接続に失敗しました", message: error.localizedDescription)
            }
        }
    }

    private func updateTestRow() {
        testRow.setTitleText(isTestingConnection ? "接続確認中…" : "接続テスト")
    }

    /// v1: a chosen profile that the relay does not list is an error; otherwise the list is shown.
    private func showProfiles(_ profiles: [String]) {
        let selectedProfile = profileField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let list = profiles.joined(separator: ", ")
        if !selectedProfile.isEmpty && !profiles.contains(selectedProfile) {
            showAlert(title: "プロフィールが見つかりません", message: "利用可能: \(list)")
        } else {
            showAlert(title: "接続成功", message: "利用可能なプロフィール: \(list)")
        }
    }

    private func saveSettings() {
        guard let url = validatedRelayURL() else { return }
        guard hasValidTokenLength() else { return }
        // An empty key would clear the stored one, and that one could not be read: ask for the key first.
        if keyReadFailed && isKeyEmpty {
            showAlert(title: "CGIキーエラー", message: "CGIキーを入力してください。")
            return
        }
        do {
            try RelayClient.shared.saveSettings(
                baseURL: url,
                profileName: profileField.text,
                bearerToken: keyField.text
            )
        } catch {
            showAlert(title: "保存に失敗しました", message: error.localizedDescription)
            return
        }
        // the Keychain now holds what the field shows, so the earlier read failure no longer matters
        keyReadFailed = false
        Session.shared.refresh()
        Toast.show("保存しました")
        if isInitialSetup {
            dismiss(animated: true, completion: nil)
        }
    }

    private func clearImageCache() {
        ImageLoader.shared.clearCaches()
        cacheRow.setValueText(SettingsViewController.sizeText(ImageLoader.shared.diskUsage))
        Toast.show("削除しました")
    }

    // MARK: - validation (v1)

    private func validatedRelayURL() -> URL? {
        let value = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              SettingsViewController.isSafeBasePath(components.path),
              let url = components.url else {
            showAlert(title: "URLエラー", message: APIError.invalidURL.localizedDescription)
            return nil
        }
        if scheme == "http" && !SettingsViewController.isTrustedLocalHost(host) {
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

    private var isKeyEmpty: Bool {
        return (keyField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    private func hasValidTokenLength() -> Bool {
        let token = keyField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard token.isEmpty || token.count >= 32 else {
            showAlert(title: "CGIキーエラー", message: "CGIキーは32文字以上にしてください。")
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
        alert.addAction(UIAlertAction(title: "閉じる", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    // MARK: - text

    /// Storage in decimal units, as the system settings show it: "12.3 MB", "512 KB".
    private static func sizeText(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        }
        return "\(bytes / 1_000) KB"
    }

    /// The version from the bundle, for example "2.0 (123)".
    private static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "-"
        let build = (info["CFBundleVersion"] as? String) ?? "-"
        return "\(version) (\(build))"
    }
}

/// One row of the settings form: a title, and at the right a text field, a value, or (centred) an action.
private final class SettingsRowControl: UIControl {
    /// The title column of the rows that hold a text field.
    private static let fieldTitleWidth: CGFloat = 112

    private enum Style {
        case field, value, action
    }

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let hairline = UIView()
    private var style = Style.value
    private var field: UITextField?
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    private func setUp() {
        titleLabel.font = Theme.font(15)
        titleLabel.textColor = Theme.palette.text
        titleLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = Theme.font(15)
        valueLabel.textColor = Theme.palette.secondaryText
        valueLabel.textAlignment = .right
        hairline.backgroundColor = Theme.palette.separator
        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(hairline)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    func configureField(title: String, field: UITextField) {
        style = .field
        self.field = field
        titleLabel.text = title
        titleLabel.textAlignment = .left
        valueLabel.isHidden = true
        field.font = Theme.font(15)
        field.textColor = Theme.palette.text
        addSubview(field)
    }

    func configureValue(title: String, value: String) {
        style = .value
        titleLabel.text = title
        titleLabel.textAlignment = .left
        valueLabel.text = value
        valueLabel.isHidden = false
    }

    func configureAction(title: String) {
        style = .action
        titleLabel.text = title
        titleLabel.font = Theme.font(15, .bold)
        titleLabel.textColor = Theme.palette.accent
        titleLabel.textAlignment = .center
        valueLabel.isHidden = true
    }

    func setTitleText(_ text: String) {
        titleLabel.text = text
    }

    func setValueText(_ text: String) {
        valueLabel.text = text
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        let pad = Metrics.pad(width)
        hairline.frame = CGRect(x: 0, y: height - Metrics.hairline, width: width, height: Metrics.hairline)
        switch style {
        case .field:
            let fieldX = pad + SettingsRowControl.fieldTitleWidth + 8
            titleLabel.frame = CGRect(x: pad, y: 0, width: SettingsRowControl.fieldTitleWidth, height: height)
            field?.frame = CGRect(x: fieldX, y: 0, width: max(0, width - fieldX - pad), height: height)
        case .value:
            let valueWidth = ceil(valueLabel.sizeThatFits(CGSize(width: width, height: height)).width)
            valueLabel.frame = CGRect(x: width - pad - valueWidth, y: 0, width: valueWidth, height: height)
            titleLabel.frame = CGRect(x: pad, y: 0, width: max(0, width - 2 * pad - valueWidth - 8), height: height)
        case .action:
            titleLabel.frame = CGRect(x: pad, y: 0, width: max(0, width - 2 * pad), height: height)
        }
    }

    @objc private func tapped() {
        onTap?()
    }
}

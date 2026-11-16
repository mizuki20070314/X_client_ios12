import UIKit

final class ComposeViewController: UIViewController, UITextViewDelegate {
    var onPost: (() -> Void)?
    var replyToPost: TimelinePost?

    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let replyContextLabel = UILabel()
    private let characterCountLabel = UILabel()
    private let postButton = UIButton(type: .system)
    private var isSubmitting = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = replyToPost == nil ? "新しいポスト" : "返信"
        view.backgroundColor = XTheme.background

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "キャンセル",
            style: .plain,
            target: self,
            action: #selector(cancel)
        )
        navigationItem.leftBarButtonItem?.tintColor = XTheme.text
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: postButton)

        postButton.setTitle("ポスト", for: .normal)
        postButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        postButton.setTitleColor(.white, for: .normal)
        postButton.backgroundColor = XTheme.blue
        postButton.layer.cornerRadius = 17
        postButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 15, bottom: 7, right: 15)
        postButton.accessibilityLabel = "ポストを送信"
        postButton.addTarget(self, action: #selector(sendPost), for: .touchUpInside)

        let avatar = makeAvatar()
        textView.font = UIFont.systemFont(ofSize: 18)
        textView.textColor = XTheme.text
        textView.backgroundColor = XTheme.background
        textView.delegate = self
        textView.returnKeyType = .default
        textView.autocorrectionType = .yes
        textView.textContainerInset = UIEdgeInsets(top: 7, left: 4, bottom: 7, right: 4)
        textView.accessibilityLabel = "ポスト本文"

        placeholderLabel.text = replyToPost == nil ? "いまどうしてる？" : "返信をポスト"
        placeholderLabel.font = textView.font
        placeholderLabel.textColor = XTheme.secondaryText
        placeholderLabel.isUserInteractionEnabled = false

        replyContextLabel.text = replyToPost.map { "返信先: @\($0.handle)" }
        replyContextLabel.font = UIFont.systemFont(ofSize: 13)
        replyContextLabel.textColor = XTheme.blue
        replyContextLabel.numberOfLines = 1
        replyContextLabel.isHidden = replyToPost == nil

        characterCountLabel.font = UIFont.systemFont(ofSize: 13)
        characterCountLabel.textColor = XTheme.secondaryText
        characterCountLabel.textAlignment = .right
        characterCountLabel.accessibilityLabel = "文字数"

        view.addSubview(avatar)
        view.addSubview(textView)
        view.addSubview(replyContextLabel)
        textView.addSubview(placeholderLabel)
        view.addSubview(characterCountLabel)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        replyContextLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        characterCountLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            avatar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            avatar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            avatar.widthAnchor.constraint(equalToConstant: 44),
            avatar.heightAnchor.constraint(equalToConstant: 44),
            replyContextLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            replyContextLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            replyContextLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            replyContextLabel.heightAnchor.constraint(equalToConstant: replyToPost == nil ? 0 : 18),
            textView.topAnchor.constraint(equalTo: replyContextLabel.bottomAnchor, constant: 6),
            textView.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: characterCountLabel.topAnchor, constant: -12),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 7),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 9),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -8),
            characterCountLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            characterCountLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            characterCountLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18)
        ])

        updateComposerState()
        textView.becomeFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        updateComposerState()
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    @objc private func sendPost() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 280, !isSubmitting else { return }
        guard RelayClient.shared.isConfigured else {
            showError(APIError.server("設定からリレーURLと認証情報を設定してください。"))
            return
        }
        isSubmitting = true
        updateComposerState()
        RelayClient.shared.post(text: text, replyToID: replyToPost?.id) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.dismiss(animated: true) { self.onPost?() }
            case .failure(let error):
                self.isSubmitting = false
                self.updateComposerState()
                self.showError(error)
            }
        }
    }

    private func updateComposerState() {
        let count = textView.text.count
        placeholderLabel.isHidden = !textView.text.isEmpty
        characterCountLabel.text = "\(count)/280"
        if count > 280 {
            characterCountLabel.textColor = .red
        } else {
            characterCountLabel.textColor = XTheme.secondaryText
        }
        postButton.isEnabled = count > 0 && count <= 280 && !isSubmitting
        postButton.alpha = postButton.isEnabled ? 1 : 0.55
    }

    private func makeAvatar() -> UIView {
        let container = UIView()
        container.backgroundColor = XTheme.avatarPlaceholder
        container.layer.cornerRadius = 22
        container.clipsToBounds = true

        let label = UILabel()
        label.text = "X"
        label.textColor = .white
        label.font = UIFont.boldSystemFont(ofSize: 20)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "投稿に失敗しました", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "閉じる", style: .default))
        present(alert, animated: true)
    }
}

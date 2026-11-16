import UIKit

/// The messages tab (ui-spec §5.7): a message until the relay supports direct messages.
final class MessagesViewController: BaseViewController {
    private let message = MessageView(
        title: "メッセージ",
        detail: "ダイレクトメッセージには、まだ対応していません。",
        buttonTitle: nil,
        action: nil
    )

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        topBar.setAvatarButton()
        topBar.title = "メッセージ"
        view.addSubview(message)
    }

    override func layoutContent() {
        message.frame = CGRect(x: 0, y: contentTop, width: view.bounds.width,
                               height: max(0, view.bounds.height - contentTop))
    }
}

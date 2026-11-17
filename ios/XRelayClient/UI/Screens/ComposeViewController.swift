import UIKit

/// The composer: a new post, a reply, or a quote. Presented full screen in a navigation controller.
final class ComposeViewController: BaseViewController, UITextViewDelegate {
    private static let counterBarHeight: CGFloat = 44
    private static let ringSide: CGFloat = 22
    private static let warningThreshold = 260

    private let replyTo: Tweet?
    private let quote: Tweet?

    private let body = UIScrollView()
    private let replyLabel = UILabel()
    private let avatar = AvatarView()
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let quoteView = QuoteView()

    private let counterBar = UIView()
    private let counterHairline = UIView()
    private let ring = UIView()
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private let countLabel = UILabel()

    private let postButton = UIButton(type: .custom)
    private let postTitle: String
    private var spinner: UIActivityIndicatorView?
    private var isSending = false
    /// The keyboard's end frame in screen coordinates, as UIKit reports it. It is converted in layout, because
    /// the view may not be in a window yet when the notification arrives.
    private var keyboardScreenFrame: CGRect?

    init(replyTo: Tweet?, quote: Tweet?) {
        self.replyTo = replyTo
        self.quote = quote
        postTitle = replyTo != nil ? "返信" : "ポストする"
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        topBar.setCloseButton { [weak self] in
            self?.closeTapped()
        }
        topBar.title = nil
        topBar.showsSeparator = false
        setUpPostButton()
        topBar.rightViews = [postButton]

        setUpBody()
        setUpCounterBar()
        updateCounter()

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // the view is in its window now, so the bar can be placed against the keyboard's frame
        view.setNeedsLayout()
        // the keyboard opens with the screen
        textView.becomeFirstResponder()
    }

    override func layoutContent() {
        // the text, the reply line and the quote live in the content column (ui-spec §8.3); the bars span the screen
        let column = Metrics.column(in: view.bounds)
        let width = column.width
        let pad = Metrics.pad(width)
        let contentX = Metrics.contentX(width)
        let contentWidth = Metrics.contentWidth(width)

        // the counter bar's bottom is the keyboard's top, or the bottom safe area edge while the keyboard is hidden
        let bottomLimit = view.bounds.height - view.safeAreaInsets.bottom
        let barBottom = min(bottomLimit, keyboardTopInView() ?? bottomLimit)
        let barY = barBottom - ComposeViewController.counterBarHeight
        let top = contentTop
        body.frame = CGRect(x: column.minX, y: top, width: width, height: max(0, barY - top))
        counterBar.frame = CGRect(x: 0, y: barY, width: view.bounds.width, height: ComposeViewController.counterBarHeight)
        counterHairline.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: Metrics.hairline)
        let ringSide = ComposeViewController.ringSide
        ring.frame = CGRect(x: column.maxX - pad - ringSide, y: (ComposeViewController.counterBarHeight - ringSide) / 2,
                            width: ringSide, height: ringSide)
        countLabel.frame = ring.bounds

        // the body: [reply line] avatar + text, [quote], all measured from the width
        var y: CGFloat = 12
        if replyTo != nil {
            replyLabel.frame = CGRect(x: contentX, y: y, width: contentWidth, height: 20)
            y += 20 + 8
        }
        let rowY = y
        avatar.frame = CGRect(x: pad, y: rowY, width: Metrics.avatar, height: Metrics.avatar)
        let textHeight = measuredTextHeight(width: contentWidth)
        textView.frame = CGRect(x: contentX, y: rowY, width: contentWidth, height: textHeight)
        placeholder.frame = CGRect(x: contentX, y: rowY, width: contentWidth, height: textView.font?.lineHeight ?? 24)
        y = rowY + textHeight + 12
        if let quote = quote {
            // configured here, not in setUp: the quote lays itself out for a real width
            quoteView.configure(tweet: quote, unavailable: nil, width: contentWidth)
            let height = QuoteView.height(tweet: quote, unavailable: nil, width: contentWidth)
            quoteView.frame = CGRect(x: contentX, y: y, width: contentWidth, height: height)
            y += height + 12
        }
        body.contentSize = CGSize(width: width, height: max(body.bounds.height, y))
    }

    // MARK: - setup

    private func setUpPostButton() {
        let palette = Theme.palette
        let label = UILabel()
        label.text = postTitle
        label.font = Theme.font(14, .bold)
        // the pill is 32 pt high with 16 pt side padding around the title
        let titleWidth = ceil(label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 32)).width)
        postButton.frame = CGRect(x: 0, y: 0, width: titleWidth + 32, height: 32)
        postButton.backgroundColor = palette.accent
        postButton.layer.cornerRadius = 16
        postButton.setTitle(postTitle, for: .normal)
        postButton.setTitleColor(UIColor.white, for: .normal)
        postButton.titleLabel?.font = Theme.font(14, .bold)
        postButton.addTarget(self, action: #selector(postTapped), for: .touchUpInside)
    }

    private func setUpBody() {
        let palette = Theme.palette
        if #available(iOS 11.0, *) {
            body.contentInsetAdjustmentBehavior = .never
        }
        body.backgroundColor = palette.background
        view.addSubview(body)

        if let replyTo = replyTo {
            replyLabel.attributedText = makeReplyLine(replyTo)
            body.addSubview(replyLabel)
        }

        avatar.set(user: Session.shared.me, size: Metrics.avatar)
        body.addSubview(avatar)

        textView.font = Theme.font(17)
        textView.textColor = palette.text
        textView.backgroundColor = UIColor.clear
        textView.textContainerInset = UIEdgeInsets.zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.delegate = self
        body.addSubview(textView)

        placeholder.text = placeholderText()
        placeholder.font = Theme.font(17)
        placeholder.textColor = palette.secondaryText
        placeholder.isUserInteractionEnabled = false
        body.addSubview(placeholder)

        if quote != nil {
            body.addSubview(quoteView)
        }
    }

    private func setUpCounterBar() {
        let palette = Theme.palette
        counterBar.backgroundColor = palette.background
        counterHairline.backgroundColor = palette.separator
        counterBar.addSubview(counterHairline)

        let radius: CGFloat = 10
        let center = CGPoint(x: ComposeViewController.ringSide / 2, y: ComposeViewController.ringSide / 2)
        let path = UIBezierPath(arcCenter: center, radius: radius, startAngle: -CGFloat.pi / 2,
                                endAngle: 1.5 * CGFloat.pi, clockwise: true)
        let side = ComposeViewController.ringSide
        for layer in [trackLayer, progressLayer] {
            layer.frame = CGRect(x: 0, y: 0, width: side, height: side)
            layer.path = path.cgPath
            layer.fillColor = nil
            layer.lineWidth = 2
            ring.layer.addSublayer(layer)
        }
        trackLayer.strokeColor = palette.separator.cgColor
        progressLayer.strokeColor = palette.accent.cgColor
        progressLayer.strokeEnd = 0

        countLabel.font = Theme.font(11)
        countLabel.textAlignment = .center
        countLabel.numberOfLines = 1
        ring.addSubview(countLabel)
        counterBar.addSubview(ring)
        view.addSubview(counterBar)
    }

    // MARK: - keyboard

    /// The keyboard moved: the bar follows it in the same animation. UIKit gives the end frame in screen coordinates,
    /// which is kept and converted when the view is laid out.
    @objc private func keyboardChanged(_ notification: Notification) {
        guard let info = notification.userInfo else { return }
        let endValue = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        keyboardScreenFrame = endValue?.cgRectValue
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        // the curve is passed as UIView.AnimationOptions shifted by 16 bits, as UIKit does it
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: curve << 16),
                       animations: {
                           self.view.setNeedsLayout()
                           self.view.layoutIfNeeded()
                       }, completion: nil)
    }

    /// The top of the keyboard in this view's coordinates, or nil while the view is not in a window or UIKit gave
    /// no frame. The window need not cover the screen (the CI preview window is smaller than the simulator
    /// screen), so the frame goes screen -> window -> view. On a full-screen window the first step is the identity.
    private func keyboardTopInView() -> CGFloat? {
        guard let screenFrame = keyboardScreenFrame, let window = view.window else { return nil }
        let inWindow = window.convert(screenFrame, from: window.screen.coordinateSpace)
        return view.convert(inWindow, from: window).minY
    }

    // MARK: - text helpers

    private func currentText() -> String {
        return textView.text ?? ""
    }

    private func placeholderText() -> String {
        if replyTo != nil { return "返信をポスト" }
        if quote != nil { return "コメントを追加" }
        return "いまどうしてる？"
    }

    private func makeReplyLine(_ tweet: Tweet) -> NSAttributedString {
        let palette = Theme.palette
        let font = Theme.font(15)
        let line = NSMutableAttributedString(string: "返信先: ",
                                             attributes: [.font: font, .foregroundColor: palette.secondaryText])
        line.append(NSAttributedString(string: "@" + tweet.user.handle,
                                       attributes: [.font: font, .foregroundColor: palette.accent]))
        line.append(NSAttributedString(string: " さん",
                                       attributes: [.font: font, .foregroundColor: palette.secondaryText]))
        return line
    }

    /// The text view grows with its text; never shorter than one line.
    private func measuredTextHeight(width: CGFloat) -> CGFloat {
        let lineHeight: CGFloat = 24
        let fitted = textView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return max(lineHeight, ceil(fitted.height))
    }

    // MARK: - counter

    /// The length ring: the track is the full circle, the progress is weighted length / 280.
    private func updateCounter() {
        let palette = Theme.palette
        let text = currentText()
        let length = TwitterText.weightedLength(text)
        let limit = TwitterText.limit
        progressLayer.strokeEnd = min(1, CGFloat(length) / CGFloat(limit))
        let ringColor: UIColor
        if length > limit {
            ringColor = palette.danger
        } else if length >= ComposeViewController.warningThreshold {
            ringColor = UIColor(hex: 0xFFD400)
        } else {
            ringColor = palette.accent
        }
        progressLayer.strokeColor = ringColor.cgColor
        if length >= ComposeViewController.warningThreshold {
            countLabel.text = "\(limit - length)"
            countLabel.textColor = length > limit ? palette.danger : palette.secondaryText
        } else {
            countLabel.text = ""
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let canPost = !trimmed.isEmpty && length <= limit && !isSending
        postButton.isEnabled = canPost
        postButton.alpha = (canPost || isSending) ? 1 : 0.5
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !currentText().isEmpty
        updateCounter()
        // the text view has to be laid out first, or the caret is measured at its old height
        view.setNeedsLayout()
        view.layoutIfNeeded()
        scrollCaretVisible()
    }

    /// Keeps the line being typed inside the body when the text grows past the bottom.
    private func scrollCaretVisible() {
        let caret = textView.caretRect(for: textView.endOfDocument)
        let inBody = textView.convert(caret, to: body)
        body.scrollRectToVisible(inBody.insetBy(dx: 0, dy: -12), animated: false)
    }

    /// Used by the debug route `type:<text>`.
    func setDraft(_ text: String) {
        textView.text = text
        textViewDidChange(textView)
    }

    // MARK: - posting and closing

    @objc private func postTapped() {
        guard !isSending else { return }
        let text = currentText().trimmingCharacters(in: .whitespacesAndNewlines)
        setSending(true)
        RelayClient.shared.createTweet(text: text, replyTo: replyTo?.id, quote: quote?.id) { [weak self] result in
            guard let self = self else { return }
            self.setSending(false)
            switch result {
            case .success(let tweet):
                self.finishPosting(tweet)
            case .failure(let error):
                // the text stays in the composer, so the post can be sent again
                self.showError(error.localizedDescription)
            }
        }
    }

    private func finishPosting(_ tweet: Tweet?) {
        var info: [AnyHashable: Any]?
        if let replyID = replyTo?.id {
            info = ["replyTo": replyID]
        }
        NotificationCenter.default.post(name: .tweetCreated, object: tweet, userInfo: info)
        Toast.show("ポストしました")
        dismiss(animated: true, completion: nil)
    }

    private func setSending(_ sending: Bool) {
        isSending = sending
        textView.isEditable = !sending
        if sending {
            postButton.setTitle("", for: .normal)
            let indicator = UIActivityIndicatorView(style: spinnerStyle())
            indicator.color = UIColor.white
            indicator.frame = postButton.bounds
            postButton.addSubview(indicator)
            indicator.startAnimating()
            spinner = indicator
        } else {
            spinner?.stopAnimating()
            spinner?.removeFromSuperview()
            spinner = nil
            postButton.setTitle(postTitle, for: .normal)
        }
        updateCounter()
    }

    private func spinnerStyle() -> UIActivityIndicatorView.Style {
        if #available(iOS 13.0, *) {
            return .medium
        }
        return .white
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "閉じる", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    /// Closing with text in the composer asks first; an empty composer just closes.
    private func closeTapped() {
        let text = currentText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            dismiss(animated: true, completion: nil)
            return
        }
        let alert = UIAlertController(title: nil, message: "ポストを破棄しますか？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "破棄", style: .destructive, handler: { [weak self] _ in
            self?.dismiss(animated: true, completion: nil)
        }))
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel, handler: nil))
        present(alert, animated: true, completion: nil)
    }
}

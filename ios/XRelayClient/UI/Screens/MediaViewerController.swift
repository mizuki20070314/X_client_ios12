import UIKit
import AVKit
import AVFoundation

/// The full-screen media viewer of a post. Photos page sideways, each one zoomable; a video or GIF shows its
/// poster with a play button, and a video that was tapped in the timeline plays at once.
final class MediaViewerController: BaseViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private static let maxZoom: CGFloat = 2.5
    private static let dismissDistance: CGFloat = 120
    private static let actionBarHeight: CGFloat = 48

    private let tweet: Tweet
    private let pagingScroll = UIScrollView()
    private var pages: [MediaPageView] = []
    private var currentIndex: Int
    private var lastWidth: CGFloat = 0

    private let closeButton = UIButton(type: .custom)
    private let counterLabel = UILabel()
    private let actionBar = ViewerActionBar()
    private var chromeVisible = true
    private var dismissing = false

    /// A video or GIF opened from the timeline plays at once; closing that player closes the viewer too.
    private var autoPlayPending: Bool
    private var closesViewerWhenDone = false
    private var loopObserver: NSObjectProtocol?

    /// `index` is the position of the tapped media in `tweet.media`.
    init(tweet: Tweet, index: Int) {
        self.tweet = tweet
        let clamped = min(max(index, 0), max(0, tweet.media.count - 1))
        currentIndex = clamped
        autoPlayPending = tweet.media.indices.contains(clamped) && tweet.media[clamped].kind != .photo
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let token = loopObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    override var showsTopBar: Bool {
        return false
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black
        setUpPaging()
        setUpChrome()
        setUpDismissGesture()
        NotificationCenter.default.addObserver(self, selector: #selector(tweetChanged(_:)),
                                               name: Tweet.didChange, object: tweet)
        actionBar.update(tweet: tweet)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if autoPlayPending {
            autoPlayPending = false
            if tweet.media.indices.contains(currentIndex) {
                openPlayer(for: tweet.media[currentIndex], closesViewerWhenDone: true)
            }
            return
        }
        // the player that opened from here has been closed
        if closesViewerWhenDone && presentedViewController == nil {
            closesViewerWhenDone = false
            dismiss(animated: false, completion: nil)
        }
    }

    override func layoutContent() {
        let width = view.bounds.width
        let height = view.bounds.height
        let pad = Metrics.pad(width)
        let safeTop = view.safeAreaInsets.top
        let safeBottom = view.safeAreaInsets.bottom

        pagingScroll.frame = view.bounds
        pagingScroll.contentSize = CGSize(width: width * CGFloat(pages.count), height: height)
        for (index, page) in pages.enumerated() {
            page.frame = CGRect(x: width * CGFloat(index), y: 0, width: width, height: height)
        }
        // on the first layout (and after a rotation) the paging is placed on the current page
        if width != lastWidth {
            lastWidth = width
            pagingScroll.contentOffset = CGPoint(x: width * CGFloat(currentIndex), y: 0)
        }

        closeButton.frame = CGRect(x: pad, y: safeTop + 8, width: 36, height: 36)
        counterLabel.frame = CGRect(x: 0, y: safeTop + 8, width: width, height: 36)
        actionBar.frame = CGRect(x: 0, y: height - safeBottom - MediaViewerController.actionBarHeight,
                                 width: width, height: MediaViewerController.actionBarHeight)
    }

    // MARK: - setup

    private func setUpPaging() {
        if #available(iOS 11.0, *) {
            pagingScroll.contentInsetAdjustmentBehavior = .never
        }
        pagingScroll.isPagingEnabled = true
        pagingScroll.showsHorizontalScrollIndicator = false
        pagingScroll.showsVerticalScrollIndicator = false
        pagingScroll.delegate = self
        view.addSubview(pagingScroll)

        for (index, media) in tweet.media.enumerated() {
            let page = MediaPageView(media: media, maxZoom: MediaViewerController.maxZoom)
            // a double tap zooms, and the single tap waits for it: it only toggles the buttons
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(pageDoubleTapped(_:)))
            doubleTap.numberOfTapsRequired = 2
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(pageSingleTapped(_:)))
            singleTap.require(toFail: doubleTap)
            page.addGestureRecognizer(doubleTap)
            page.addGestureRecognizer(singleTap)
            // the viewer answers viewForZooming and scrollViewDidZoom for every page
            page.delegate = self
            page.playButton?.tag = index
            page.playButton?.addTarget(self, action: #selector(playTapped(_:)), for: .touchUpInside)
            pagingScroll.addSubview(page)
            pages.append(page)
        }
    }

    private func setUpChrome() {
        closeButton.backgroundColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        closeButton.layer.cornerRadius = 18
        closeButton.tintColor = UIColor.white
        closeButton.setImage(Icons.image(.close, size: 20), for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        counterLabel.font = Theme.font(15, .medium)
        counterLabel.textColor = UIColor.white
        counterLabel.textAlignment = .center
        counterLabel.numberOfLines = 1
        counterLabel.text = counterText()
        counterLabel.isHidden = pages.count < 2
        view.addSubview(counterLabel)

        actionBar.onSelect = { [weak self] index in
            self?.actionTapped(index)
        }
        view.addSubview(actionBar)
    }

    /// Dismisses by a vertical drag while the picture is not zoomed in.
    private func setUpDismissGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    // MARK: - pages

    private var currentPage: MediaPageView? {
        return pages.indices.contains(currentIndex) ? pages[currentIndex] : nil
    }

    private func counterText() -> String {
        return "\(currentIndex + 1)/\(pages.count)"
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pagingScroll else { return }
        let width = scrollView.bounds.width
        guard width > 0, !pages.isEmpty else { return }
        let position = Int((scrollView.contentOffset.x / width).rounded())
        let index = min(max(position, 0), pages.count - 1)
        guard index != currentIndex else { return }
        // the picture being left goes back to its normal size
        let previous = pages[currentIndex]
        previous.setZoomScale(previous.minimumZoomScale, animated: false)
        currentIndex = index
        counterLabel.text = counterText()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return (scrollView as? MediaPageView)?.imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        (scrollView as? MediaPageView)?.centerImage()
    }

    @objc private func pageDoubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard let page = recognizer.view as? MediaPageView, page.maximumZoomScale > page.minimumZoomScale else { return }
        if page.zoomScale > page.minimumZoomScale {
            page.setZoomScale(page.minimumZoomScale, animated: true)
            return
        }
        // the zoom rectangle is centred on the tapped point of the picture (the same as Apple's zoom sample)
        let point = recognizer.location(in: page.imageView)
        let width = page.bounds.width / MediaViewerController.maxZoom
        let height = page.bounds.height / MediaViewerController.maxZoom
        page.zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
                  animated: true)
    }

    @objc private func pageSingleTapped(_ recognizer: UITapGestureRecognizer) {
        setChromeVisible(!chromeVisible)
    }

    private func setChromeVisible(_ visible: Bool) {
        chromeVisible = visible
        let alpha: CGFloat = visible ? 1 : 0
        UIView.animate(withDuration: 0.2, delay: 0, options: [], animations: {
            self.closeButton.alpha = alpha
            self.counterLabel.alpha = alpha
            self.actionBar.alpha = alpha
        }, completion: nil)
    }

    // MARK: - dismissal

    @objc private func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
        guard let page = currentPage else { return }
        let translation = recognizer.translation(in: view)
        switch recognizer.state {
        case .changed:
            page.transform = CGAffineTransform(translationX: 0, y: translation.y)
            view.backgroundColor = UIColor.black.withAlphaComponent(max(0, 1 - abs(translation.y) / 300))
        case .ended, .cancelled, .failed:
            let velocity = recognizer.velocity(in: view)
            if abs(translation.y) > MediaViewerController.dismissDistance || abs(velocity.y) > 800 {
                dismissDragged(offsetY: translation.y)
            } else {
                UIView.animate(withDuration: 0.2, delay: 0, options: [], animations: {
                    page.transform = CGAffineTransform.identity
                    self.view.backgroundColor = UIColor.black
                }, completion: nil)
            }
        default:
            break
        }
    }

    /// The picture slides off in the direction of the drag, and the background fades with it.
    private func dismissDragged(offsetY: CGFloat) {
        guard !dismissing, let page = currentPage else { return }
        dismissing = true
        let distance = view.bounds.height * (offsetY < 0 ? -1 : 1)
        UIView.animate(withDuration: 0.2, delay: 0, options: [], animations: {
            page.transform = CGAffineTransform(translationX: 0, y: distance)
            self.view.backgroundColor = UIColor.clear
        }, completion: { _ in
            self.dismiss(animated: false, completion: nil)
        })
    }

    /// Only a vertical drag on a picture that is not zoomed in starts the dismissal.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let page = currentPage else { return false }
        let velocity = pan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x) && page.zoomScale <= page.minimumZoomScale
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    @objc private func closeTapped() {
        dismiss(animated: true, completion: nil)
    }

    // MARK: - actions and playback

    @objc private func tweetChanged(_ notification: Notification) {
        actionBar.update(tweet: tweet)
    }

    private func actionTapped(_ index: Int) {
        switch index {
        case 0:
            TweetActions.reply(to: tweet)
        case 1:
            TweetActions.showRepostMenu(for: tweet)
        case 2:
            TweetActions.toggleLike(tweet)
        case 3:
            TweetActions.toggleBookmark(tweet)
        default:
            TweetActions.showShareMenu(for: tweet)
        }
    }

    @objc private func playTapped(_ sender: UIButton) {
        guard tweet.media.indices.contains(sender.tag) else { return }
        openPlayer(for: tweet.media[sender.tag], closesViewerWhenDone: false)
    }

    /// Presents the system player. In demo mode the media is only a poster, so the player is not opened.
    private func openPlayer(for media: Media, closesViewerWhenDone: Bool) {
        if CoreEnvironment.isDemo {
            Toast.show("デモでは再生できません")
            return
        }
        guard let url = media.hlsURL ?? media.mp4URL else { return }
        if media.kind == .video {
            configureAudioSession()
        }
        let player = AVPlayer(url: url)
        if media.kind == .gif {
            // a GIF is a short silent loop; an observer left by an earlier GIF is removed first
            player.isMuted = true
            if let token = loopObserver {
                NotificationCenter.default.removeObserver(token)
            }
            loopObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: player.currentItem,
                queue: OperationQueue.main
            ) { [weak player] _ in
                player?.seek(to: CMTime.zero)
                player?.play()
            }
        }
        let controller = AVPlayerViewController()
        controller.player = player
        controller.modalPresentationStyle = .fullScreen
        self.closesViewerWhenDone = closesViewerWhenDone
        present(controller, animated: true, completion: {
            player.play()
        })
    }

    /// Playback category, so the video sounds with the mute switch on. Without it the video still plays.
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        } catch {
            // the video plays with the session as it is
        }
    }
}

/// One page of the viewer: a picture that zooms, or the poster of a video or GIF with a play button.
private final class MediaPageView: UIScrollView {
    let media: Media
    let imageView = UIImageView()
    private(set) var playButton: UIButton?
    private var aspect: CGFloat
    private var hasFullImage = false
    private var previewRequest: ImageRequest?
    private var fullRequest: ImageRequest?

    init(media: Media, maxZoom: CGFloat) {
        self.media = media
        aspect = media.aspect
        super.init(frame: .zero)
        backgroundColor = UIColor.clear
        minimumZoomScale = 1
        // only pictures zoom; a video poster stays where it is under its play button
        maximumZoomScale = media.kind == .photo ? maxZoom : 1
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        if #available(iOS 11.0, *) {
            contentInsetAdjustmentBehavior = .never
        }
        addSubview(imageView)
        if media.kind != .photo {
            makePlayButton()
        }
        loadImages()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        previewRequest?.cancel()
        fullRequest?.cancel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fitImage()
    }

    /// At zoom 1 the picture fills the page as far as its aspect allows, centred.
    private func fitImage() {
        guard zoomScale == minimumZoomScale else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0, aspect > 0 else { return }
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        imageView.frame = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                                 width: width, height: height)
        contentSize = size
        playButton?.center = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Keeps a picture that is smaller than the page in the middle while it is zoomed.
    func centerImage() {
        let size = bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.width < size.width ? (size.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < size.height ? (size.height - frame.height) / 2 : 0
        imageView.frame = frame
    }

    private func loadImages() {
        // the small picture shows first; the medium one replaces it when it has arrived
        if let small = media.imageURL(.small) {
            previewRequest = ImageLoader.shared.load(small, maxPixel: 1024) { [weak self] image in
                guard let self = self, !self.hasFullImage, let image = image else { return }
                self.show(image)
            }
        }
        if let medium = media.imageURL(.medium) {
            fullRequest = ImageLoader.shared.load(medium, maxPixel: 2048) { [weak self] image in
                guard let self = self, let image = image else { return }
                self.hasFullImage = true
                self.show(image)
            }
        }
    }

    private func show(_ image: UIImage) {
        imageView.image = image
        if image.size.width > 0 && image.size.height > 0 {
            aspect = image.size.width / image.size.height
            setNeedsLayout()
        }
    }

    private func makePlayButton() {
        let button = UIButton(type: .custom)
        button.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        button.backgroundColor = Theme.palette.accent
        button.layer.cornerRadius = 24
        button.layer.borderWidth = 3
        button.layer.borderColor = UIColor.white.cgColor
        button.tintColor = UIColor.white
        button.setImage(Icons.image(.play, size: 22), for: .normal)
        addSubview(button)
        playButton = button
    }
}

/// The row under the picture: reply, repost, like, bookmark and share, in white, five equal slots. The states
/// (liked, reposted, bookmarked) show in their colours, and the counts follow the post.
private final class ViewerActionBar: UIView {
    /// 0 reply, 1 repost, 2 like, 3 bookmark, 4 share.
    var onSelect: ((Int) -> Void)?

    private static let slotCount = 5
    private static let iconSide: CGFloat = 22
    private static let iconGap: CGFloat = 4
    private static let countHeight: CGFloat = 16

    private var buttons: [UIButton] = []
    private var icons: [UIImageView] = []
    private var counts: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        build()
    }

    private func build() {
        for index in 0..<ViewerActionBar.slotCount {
            let button = UIButton(type: .custom)
            button.tag = index
            button.addTarget(self, action: #selector(slotTapped(_:)), for: .touchUpInside)
            let icon = UIImageView()
            icon.isUserInteractionEnabled = false
            let count = UILabel()
            count.font = Theme.font(13)
            count.numberOfLines = 1
            count.isUserInteractionEnabled = false
            button.addSubview(icon)
            button.addSubview(count)
            addSubview(button)
            buttons.append(button)
            icons.append(icon)
            counts.append(count)
        }
    }

    /// Sets the icons, colours and counts for `tweet`. A zero count is not shown.
    func update(tweet: Tweet) {
        let palette = Theme.palette
        let plain = UIColor.white
        var entries: [(icon: IconName, color: UIColor, count: Int)] = []
        entries.append((icon: .reply, color: plain, count: tweet.replyCount))
        entries.append((icon: .repost, color: tweet.retweeted ? palette.repost : plain, count: tweet.retweetCount))
        entries.append((icon: tweet.liked ? .heartFill : .heart, color: tweet.liked ? palette.like : plain,
                        count: tweet.likeCount))
        entries.append((icon: tweet.bookmarked ? .bookmarkFill : .bookmark,
                        color: tweet.bookmarked ? palette.accent : plain, count: tweet.bookmarkCount))
        entries.append((icon: .share, color: plain, count: 0))
        for (index, entry) in entries.enumerated() {
            icons[index].image = Icons.image(entry.icon, size: ViewerActionBar.iconSide)
            icons[index].tintColor = entry.color
            counts[index].text = entry.count > 0 ? Format.count(entry.count) : ""
            counts[index].textColor = entry.color
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let slotWidth = bounds.width / CGFloat(ViewerActionBar.slotCount)
        let side = ViewerActionBar.iconSide
        let gap = ViewerActionBar.iconGap
        let rowHeight = ViewerActionBar.countHeight
        for index in 0..<buttons.count {
            buttons[index].frame = CGRect(x: slotWidth * CGFloat(index), y: 0,
                                          width: slotWidth, height: bounds.height)
            // the icon and its count are centred as one group inside the slot
            let hasCount = !(counts[index].text ?? "").isEmpty
            let countWidth: CGFloat = hasCount
                ? ceil(counts[index].sizeThatFits(CGSize(width: slotWidth, height: rowHeight)).width)
                : 0
            let groupWidth = side + (countWidth > 0 ? gap + countWidth : 0)
            let startX = (slotWidth - groupWidth) / 2
            icons[index].frame = CGRect(x: startX, y: (bounds.height - side) / 2, width: side, height: side)
            counts[index].frame = CGRect(x: startX + side + gap, y: (bounds.height - rowHeight) / 2,
                                         width: countWidth, height: rowHeight)
        }
    }

    @objc private func slotTapped(_ sender: UIButton) {
        onSelect?(sender.tag)
    }
}

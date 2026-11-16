import UIKit

/// The post detail: the post and its conversation in a timeline, with a reply bar at the bottom.
final class TweetDetailViewController: BaseViewController {
    private static let replyBarHeight: CGFloat = 52

    private let focalID: String
    /// The post the screen is about: the given one, the one in the store, or the one in the answer.
    private var focalTweet: Tweet?
    private var timeline: TimelineViewController?
    private let replyBar = UIView()
    private let replyHairline = UIView()
    private let replyPill = UIView()
    private let replyLabel = UILabel()

    /// The focal post is shown at once on the first load, and the real page replaces it.
    private var preliminaryDelivered = false
    private var timelineStarted = false
    private var focalScrolled = false

    init(tweet: Tweet) {
        focalID = tweet.id
        focalTweet = tweet
        super.init(nibName: nil, bundle: nil)
    }

    init(tweetID: String) {
        focalID = tweetID
        focalTweet = TweetStore.shared.tweet(id: tweetID)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        topBar.title = "ポスト"
        topBar.setBackButton { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }

        let timeline = TimelineViewController(loader: { [weak self] cursor, completion in
            guard let self = self else {
                completion(.success(TimelinePage(json: JSON(nil))))
                return
            }
            self.loadThread(cursor: cursor, completion: completion)
        })
        addChild(timeline)
        view.addSubview(timeline.view)
        timeline.didMove(toParent: self)
        self.timeline = timeline

        setUpReplyBar()
        NotificationCenter.default.addObserver(self, selector: #selector(tweetCreated(_:)),
                                               name: .tweetCreated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(tweetDeleted(_:)),
                                               name: .tweetDeleted, object: nil)
    }

    override func layoutContent() {
        let width = view.bounds.width
        let barY = view.bounds.height - TweetDetailViewController.replyBarHeight
        let top = contentTop
        timeline?.view.frame = CGRect(x: 0, y: top, width: width, height: max(0, barY - top))

        replyBar.frame = CGRect(x: 0, y: barY, width: width, height: TweetDetailViewController.replyBarHeight)
        replyHairline.frame = CGRect(x: 0, y: 0, width: width, height: Metrics.hairline)
        let pad = Metrics.pad(width)
        replyPill.frame = CGRect(x: pad, y: 8, width: max(0, width - 2 * pad), height: 36)
        replyLabel.frame = CGRect(x: 16, y: 0, width: max(0, replyPill.frame.width - 32), height: 36)
        view.bringSubviewToFront(replyBar)

        // the first load waits for a real width, so the rows are measured once
        if !timelineStarted && width > 0 {
            timelineStarted = true
            timeline?.loadIfNeeded()
        }
    }

    // MARK: - loading

    private func loadThread(cursor: String?, completion: @escaping (Result<TimelinePage, Error>) -> Void) {
        if cursor == nil && !preliminaryDelivered, let tweet = focalTweet {
            preliminaryDelivered = true
            // delivered on a later turn, so the timeline has set its loading state first; the main queue
            // keeps this ahead of the network answer that is requested below
            let preliminary = TweetDetailViewController.preliminaryPage(for: tweet)
            DispatchQueue.main.async {
                completion(.success(preliminary))
            }
        }
        RelayClient.shared.timeline(.tweet(id: focalID), cursor: cursor) { [weak self] result in
            if cursor == nil, case .success(let page) = result {
                self?.noteFirstPage(page)
            }
            completion(result)
        }
    }

    /// The focal post is taken from the answer. When rows come before it, it is scrolled to the top once.
    private func noteFirstPage(_ page: TimelinePage) {
        var focalIndex: Int?
        for (index, item) in page.items.enumerated() {
            if case .tweet(let entry) = item, entry.focal {
                focalIndex = index
                focalTweet = entry.tweet
                break
            }
        }
        guard let index = focalIndex, index > 0, !focalScrolled else { return }
        focalScrolled = true
        // the timeline applies the rows right after this completion, so the scroll waits one turn
        DispatchQueue.main.async { [weak self] in
            self?.timeline?.tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .top, animated: false)
        }
    }

    private static func preliminaryPage(for tweet: Tweet) -> TimelinePage {
        var page = TimelinePage(json: JSON(nil))
        let entry = TweetEntry(tweet: tweet, contextKind: nil, contextText: nil,
                               above: false, below: false, focal: true)
        page.items = [.tweet(entry)]
        return page
    }

    // MARK: - reply bar

    private func setUpReplyBar() {
        let palette = Theme.palette
        replyBar.backgroundColor = palette.background
        replyHairline.backgroundColor = palette.separator
        replyBar.addSubview(replyHairline)

        replyPill.backgroundColor = palette.surface
        replyPill.layer.cornerRadius = 18
        replyPill.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(replyTapped)))
        replyLabel.text = "返信をポスト"
        replyLabel.font = Theme.font(15)
        replyLabel.textColor = palette.secondaryText
        replyPill.addSubview(replyLabel)
        replyBar.addSubview(replyPill)
        view.addSubview(replyBar)
    }

    @objc private func replyTapped() {
        guard let tweet = focalTweet else { return }
        TweetActions.reply(to: tweet)
    }

    // MARK: - notifications

    /// A reply to this post was made: the conversation is loaded again.
    @objc private func tweetCreated(_ notification: Notification) {
        guard let replyID = notification.userInfo?["replyTo"] as? String, replyID == focalID else { return }
        timeline?.reload()
    }

    /// The post was deleted from here or elsewhere: nothing is left to show, so the screen closes.
    @objc private func tweetDeleted(_ notification: Notification) {
        guard let deletedID = notification.object as? String, deletedID == focalID else { return }
        navigationController?.popViewController(animated: true)
    }
}

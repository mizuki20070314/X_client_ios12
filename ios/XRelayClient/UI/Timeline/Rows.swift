import UIKit

/// Reuse identifiers, one per cell class.
enum TimelineReuse {
    static let tweet = "tweet"
    static let focal = "focal"
    static let more = "more"
    static let header = "header"
    static let tombstone = "tombstone"
    static let user = "user"
    static let notification = "notification"
    static let trend = "trend"
}

/// Numbers shared by several timeline rows (ui-spec.md §4.3–4.5). Numbers of one row stay in its own file.
enum TimelineSpec {
    static let topPadding: CGFloat = 12
    static let attachmentGap: CGFloat = 12
    /// The gap before an attachment that directly follows the name line (no reply line, no text).
    static let nameAttachmentGap: CGFloat = 10
    static let nameLineHeight: CGFloat = 20
    static let actionBarHeight: CGFloat = 32
    static let focalActionBarHeight: CGFloat = 48
    static let threadWidth: CGFloat = 2
    /// Space between the avatar and a conversation line.
    static let threadGap: CGFloat = 4
    static let overflowTouchSize: CGFloat = 36
    static let overflowIconSize: CGFloat = 18

    /// The width of FollowButton, which is the same in every state: the widest of its titles plus padding, at least
    /// 96 pt. The titles are FollowButton's (FollowButton.swift); the rows reserve this space before the button exists.
    static let followWidth: CGFloat = {
        let font = Theme.font(14, .bold)
        var widest: CGFloat = 0
        for title in ["フォローする", "フォロー中", "承認待ち", "ブロック中"] {
            let size = NSString(string: title).size(withAttributes: [NSAttributedString.Key.font: font])
            widest = max(widest, size.width)
        }
        return max(96, ceil(widest) + 32)
    }()

    /// The overflow button: a 36 pt touch area whose 18 pt icon ends at `width - pad`, centred on `centerY`.
    static func overflowFrame(width: CGFloat, pad: CGFloat, centerY: CGFloat) -> CGRect {
        let touch = overflowTouchSize
        let x = width - pad - overflowIconSize - (touch - overflowIconSize) / 2
        return CGRect(x: x, y: centerY - touch / 2, width: touch, height: touch)
    }
}

/// One row of a timeline: its model (the layout is cached per width) and the cell that shows it.
protocol TimelineRow: AnyObject {
    var reuseIdentifier: String { get }
    var cellClass: UITableViewCell.Type { get }
    /// Cached per width: the cell only applies the layout.
    func height(for width: CGFloat) -> CGFloat
    func configure(_ cell: UITableViewCell, width: CGFloat)
    /// Called when the row is tapped. The default does nothing.
    func didSelect(from controller: UIViewController)
    /// Posts: the id (and the repost id); other rows have none.
    var dedupeKey: String? { get }
}

extension TimelineRow {
    func didSelect(from controller: UIViewController) {}
}

enum TimelineRowFactory {
    static func rows(for items: [TimelineItem]) -> [TimelineRow] {
        return items.map { TimelineRowFactory.makeRow(for: $0) }
    }

    private static func makeRow(for item: TimelineItem) -> TimelineRow {
        switch item {
        case .tweet(let entry):
            if entry.focal {
                return FocalTweetRow(entry: entry)
            }
            return TweetRow(entry: entry)
        case .more(let cursor, let label):
            return MoreRow(cursor: cursor, label: label)
        case .header(let text):
            return HeaderRow(text: text)
        case .tombstone(let text, let above, let below):
            return TombstoneRow(text: text, above: above, below: below)
        case .user(let user):
            return UserRow(user: user)
        case .notification(let entry):
            return NotificationRow(entry: entry)
        case .trend(let trend):
            return TrendRow(trend: trend)
        }
    }
}

// MARK: - Row models

/// A post in a list (the focal post of a detail screen is a FocalTweetRow).
final class TweetRow: TimelineRow {
    let entry: TweetEntry
    /// Filled by `layout(for:)` in TweetCell.swift.
    var layoutCache: TweetLayout?

    init(entry: TweetEntry) {
        self.entry = entry
    }

    var tweet: Tweet { return entry.tweet }
    var reuseIdentifier: String { return TimelineReuse.tweet }
    var cellClass: UITableViewCell.Type { return TweetCell.self }
    var dedupeKey: String? { return TweetRow.key(for: entry.tweet) }

    func height(for width: CGFloat) -> CGFloat {
        return layout(for: width).height
    }

    func configure(_ cell: UITableViewCell, width: CGFloat) {
        guard let cell = cell as? TweetCell else { return }
        cell.configure(self, layout: layout(for: width))
    }

    func didSelect(from controller: UIViewController) {
        Router.openTweet(tweet)
    }

    /// Two rows with the same key are the same post (a repost of it counts as another row).
    static func key(for tweet: Tweet) -> String {
        return tweet.id + "|" + (tweet.retweetID ?? "")
    }
}

/// The focal post of a detail screen: large text, the time line and the large action bar.
final class FocalTweetRow: TimelineRow {
    let entry: TweetEntry
    /// Filled by `layout(for:)` in FocalTweetCell.swift.
    var layoutCache: FocalTweetLayout?

    init(entry: TweetEntry) {
        self.entry = entry
    }

    var tweet: Tweet { return entry.tweet }
    var reuseIdentifier: String { return TimelineReuse.focal }
    var cellClass: UITableViewCell.Type { return FocalTweetCell.self }
    var dedupeKey: String? { return TweetRow.key(for: entry.tweet) }

    func height(for width: CGFloat) -> CGFloat {
        return layout(for: width).height
    }

    func configure(_ cell: UITableViewCell, width: CGFloat) {
        guard let cell = cell as? FocalTweetCell else { return }
        cell.configure(self, layout: layout(for: width))
    }
}

/// "返信をさらに表示" and the like: loads its cursor and is replaced by the page's rows.
final class MoreRow: TimelineRow {
    let cursor: String
    let label: String
    /// Set by TimelineViewController while the cursor loads; the cell then shows a spinner.
    var isLoading = false

    init(cursor: String, label: String) {
        self.cursor = cursor
        self.label = label
    }

    var reuseIdentifier: String { return TimelineReuse.more }
    var cellClass: UITableViewCell.Type { return MoreCell.self }
    var dedupeKey: String? { return nil }

    func height(for width: CGFloat) -> CGFloat {
        return MoreCell.rowHeight
    }

    func configure(_ cell: UITableViewCell, width: CGFloat) {
        (cell as? MoreCell)?.configure(self, width: width)
    }

    func didSelect(from controller: UIViewController) {
        (controller as? TimelineViewController)?.expandMore(self)
    }
}

/// A section title ("もっと見つける").
final class HeaderRow: TimelineRow {
    let text: String

    init(text: String) {
        self.text = text
    }

    var reuseIdentifier: String { return TimelineReuse.header }
    var cellClass: UITableViewCell.Type { return HeaderCell.self }
    var dedupeKey: String? { return nil }

    func height(for width: CGFloat) -> CGFloat {
        return HeaderCell.rowHeight
    }

    func configure(_ cell: UITableViewCell, width: CGFloat) {
        (cell as? HeaderCell)?.configure(self, width: width)
    }
}

/// Placeholder for a post that cannot be shown.
final class TombstoneRow: TimelineRow {
    let text: String
    let above: Bool
    let below: Bool
    /// Filled by `layout(for:)` in SimpleCells.swift.
    var layoutCache: TombstoneLayout?

    init(text: String, above: Bool, below: Bool) {
        self.text = text
        self.above = above
        self.below = below
    }

    var reuseIdentifier: String { return TimelineReuse.tombstone }
    var cellClass: UITableViewCell.Type { return TombstoneCell.self }
    var dedupeKey: String? { return nil }

    func height(for width: CGFloat) -> CGFloat {
        return layout(for: width).height
    }

    func configure(_ cell: UITableViewCell, width: CGFloat) {
        guard let cell = cell as? TombstoneCell else { return }
        cell.configure(self, layout: layout(for: width))
    }
}

/// A user in a list (followers, search results).
final class UserRow: TimelineRow {
    let user: User
    /// Filled by `layout(for:)` in SimpleCells.swift.
    var layoutCache: UserLayout?

    init(user: User) {
        self.user = user
    }

    var reuseIdentifier: String { return TimelineReuse.user }
    var cellClass: UITableViewCell.Type { return UserCell.self }
    var dedupeKey: String? { return nil }

    func height(for width: CGFloat) -> CGFloat {
        return layout(for: width).height
    }

    func configure(_ cell: UITableViewCell, width: CGFloat) {
        guard let cell = cell as? UserCell else { return }
        cell.configure(self, layout: layout(for: width))
    }

    func didSelect(from controller: UIViewController) {
        Router.openProfile(user: user)
    }
}

/// An entry of the notifications list.
final class NotificationRow: TimelineRow {
    let entry: NotificationEntry
    /// Filled by `layout(for:)` in NotificationCell.swift.
    var layoutCache: NotificationLayout?

    init(entry: NotificationEntry) {
        self.entry = entry
    }

    /// A tap has somewhere to go: the post, or the link of the notification.
    var hasTarget: Bool { return entry.tweet != nil || entry.url != nil }
    var reuseIdentifier: String { return TimelineReuse.notification }
    var cellClass: UITableViewCell.Type { return NotificationCell.self }
    var dedupeKey: String? { return nil }

    func height(for width: CGFloat) -> CGFloat {
        return layout(for: width).height
    }

    func configure(_ cell: UITableViewCell, width: CGFloat) {
        guard let cell = cell as? NotificationCell else { return }
        cell.configure(self, layout: layout(for: width))
    }

    func didSelect(from controller: UIViewController) {
        if let tweet = entry.tweet {
            Router.openTweet(tweet)
        } else if let url = entry.url {
            Router.openURL(url)
        }
    }
}

/// A trend in the explore list.
final class TrendRow: TimelineRow {
    let trend: Trend
    /// Filled by `layout(for:)` in TrendCell.swift.
    var layoutCache: TrendLayout?

    init(trend: Trend) {
        self.trend = trend
    }

    var reuseIdentifier: String { return TimelineReuse.trend }
    var cellClass: UITableViewCell.Type { return TrendCell.self }
    var dedupeKey: String? { return nil }

    func height(for width: CGFloat) -> CGFloat {
        return layout(for: width).height
    }

    func configure(_ cell: UITableViewCell, width: CGFloat) {
        guard let cell = cell as? TrendCell else { return }
        cell.configure(self, layout: layout(for: width))
    }

    func didSelect(from controller: UIViewController) {
        Router.openSearch(query: trend.query)
    }
}

// MARK: - Cell plumbing

/// The part every timeline cell shares: the pressed background, the bottom hairline and the two pieces of the
/// conversation line. Subclasses add their subviews once in `setUpContent()` and only apply frames later.
class TimelineCellBase: UITableViewCell {
    /// The bottom hairline (full width, `palette.separator`). Shown only when a row places it.
    let hairline = UIView()
    /// Conversation line above the avatar and below it (2 pt wide, `palette.border`).
    let threadAbove = UIView()
    let threadBelow = UIView()
    /// Rows that cannot be pressed (the focal post) switch this off.
    var highlightsOnPress = true
    /// Drawn under the content while the finger is down: the cell uses no UIKit selection look.
    private let pressedView = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = Theme.palette.background
        let palette = Theme.palette
        pressedView.isHidden = true
        contentView.addSubview(pressedView)
        for line in [threadAbove, threadBelow] {
            line.backgroundColor = palette.border
            line.isHidden = true
            contentView.addSubview(line)
        }
        hairline.backgroundColor = palette.separator
        hairline.isHidden = true
        contentView.addSubview(hairline)
        setUpContent()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Creates the subviews of the cell. Called once, from init.
    func setUpContent() {}

    override func layoutSubviews() {
        super.layoutSubviews()
        pressedView.frame = contentView.bounds
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        guard highlightsOnPress else { return }
        pressedView.backgroundColor = Theme.palette.highlight
        pressedView.isHidden = !highlighted
    }

    // A touch that starts on a link (an entity of a LinkLabel) belongs to the link. LinkLabel passes its touches
    // on to the cell, so the cell must keep them: otherwise a tap on a mention would also open the post.
    private var touchIsOnLink = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchIsOnLink = touches.first.map { isOnLink($0) } ?? false
        if touchIsOnLink {
            return
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touchIsOnLink {
            return
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touchIsOnLink {
            touchIsOnLink = false
            return
        }
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touchIsOnLink {
            touchIsOnLink = false
            return
        }
        super.touchesCancelled(touches, with: event)
    }

    /// Whether the touch is on an entity of one of the cell's link labels.
    private func isOnLink(_ touch: UITouch) -> Bool {
        for view in contentView.subviews {
            guard let label = view as? LinkLabel, !label.isHidden, let layout = label.textLayout else { continue }
            let point = touch.location(in: label)
            if label.bounds.contains(point) && layout.entity(at: point) != nil {
                return true
            }
        }
        return false
    }
}

extension UIView {
    /// Shows the view at `frame`, or hides it when the row has no frame for it.
    func timelinePlace(_ frame: CGRect?) {
        if let frame = frame {
            self.frame = frame
            isHidden = false
        } else {
            isHidden = true
        }
    }
}

/// The small spinner of the timeline (footer, "more" row). Secondary colour.
enum TimelineSpinner {
    static func make() -> UIActivityIndicatorView {
        let spinner: UIActivityIndicatorView
        if #available(iOS 13.0, *) {
            spinner = UIActivityIndicatorView(style: .medium)
        } else {
            spinner = UIActivityIndicatorView(style: .gray)
        }
        spinner.color = Theme.palette.secondaryText
        return spinner
    }
}

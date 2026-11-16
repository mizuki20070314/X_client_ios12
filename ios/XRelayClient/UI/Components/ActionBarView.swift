import UIKit

/// The icon and count of one action. The control is the touch target; its icon and count are drawn inside it.
fileprivate final class ActionItem: UIControl {
    let iconView = UIImageView()
    let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        countLabel.font = Theme.font(13)
        countLabel.numberOfLines = 1
        addSubview(iconView)
        addSubview(countLabel)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The like animation: the heart goes from 0.8 to 1.2 and settles at 1 in 0.25 s, with a light impact.
fileprivate enum LikeFeedback {
    static func play(on heart: UIView) {
        heart.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        UIView.animateKeyframes(withDuration: 0.25, delay: 0, options: [], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.5) {
                heart.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.5, relativeDuration: 0.5) {
                heart.transform = CGAffineTransform.identity
            }
        }, completion: nil)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// The action row under a post in a list (ui-spec §3.9): reply, repost, like, views, bookmark and share in a 32 pt
/// row. It observes nothing itself: the cell calls `configure` again when the post changes.
final class ActionBarView: UIView {
    var onReply: (() -> Void)?
    var onRepost: (() -> Void)?
    var onLike: (() -> Void)?
    var onBookmark: (() -> Void)?
    var onShare: (() -> Void)?

    private static let rowHeight: CGFloat = 32
    /// The targets are 36 pt high, so they reach 2 pt beyond the row on each side.
    private static let overflow: CGFloat = 2

    private weak var tweet: Tweet?
    private let replyItem = ActionItem(frame: .zero)
    private let repostItem = ActionItem(frame: .zero)
    private let likeItem = ActionItem(frame: .zero)
    private let viewsItem = ActionItem(frame: .zero)
    private let bookmarkItem = ActionItem(frame: .zero)
    private let shareItem = ActionItem(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    private func setUp() {
        backgroundColor = UIColor.clear
        let items: [ActionItem] = [replyItem, repostItem, likeItem, viewsItem, bookmarkItem, shareItem]
        for item in items {
            addSubview(item)
        }
        // views are shown only; the touch falls through to the row. Share is added after bookmark, so where the
        // two targets overlap, share takes the touch.
        viewsItem.isUserInteractionEnabled = false
        replyItem.addTarget(self, action: #selector(replyTapped), for: .touchUpInside)
        repostItem.addTarget(self, action: #selector(repostTapped), for: .touchUpInside)
        likeItem.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        bookmarkItem.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        shareItem.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
    }

    /// The touch targets reach 2 pt beyond the row.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return bounds.insetBy(dx: 0, dy: -ActionBarView.overflow).contains(point)
    }

    /// Shows the counts and states of `tweet` in a row `width` points wide. Slots are `floor((width - 52) / 4)`.
    func configure(tweet: Tweet, width: CGFloat) {
        self.tweet = tweet
        let palette = Theme.palette
        let secondary = palette.secondaryText
        let slot = floor((width - 52) / 4)

        let repostColor: UIColor = tweet.retweeted ? palette.repost : secondary
        let likeColor: UIColor = tweet.liked ? palette.like : secondary
        let likeIcon: IconName = tweet.liked ? .heartFill : .heart
        let bookmarkColor: UIColor = tweet.bookmarked ? palette.accent : secondary
        let bookmarkIcon: IconName = tweet.bookmarked ? .bookmarkFill : .bookmark

        layoutItem(replyItem, x: 0, width: slot, iconX: 0, icon: .reply, color: secondary,
                   count: tweet.replyCount)
        layoutItem(repostItem, x: slot, width: slot, iconX: 0, icon: .repost, color: repostColor,
                   count: tweet.retweetCount)
        layoutItem(likeItem, x: slot * 2, width: slot, iconX: 0, icon: likeIcon, color: likeColor,
                   count: tweet.likeCount)
        // views exist only when the server counts them; a count of 0 shows the icon alone
        viewsItem.isHidden = tweet.viewCount == nil
        layoutItem(viewsItem, x: slot * 3, width: slot, iconX: 0, icon: .views, color: secondary,
                   count: tweet.viewCount ?? 0)
        // bookmark and share show no count. Their icons sit at width - 52 and width - 18 (ui-spec §3.9).
        layoutItem(bookmarkItem, x: width - 61, width: 36, iconX: 9, icon: bookmarkIcon, color: bookmarkColor,
                   count: 0)
        layoutItem(shareItem, x: width - 27, width: 27, iconX: 9, icon: .share, color: secondary, count: 0)
    }

    /// Places one action: `x` and `width` of its target, the icon at `iconX` inside it, the count 4 pt right of it.
    private func layoutItem(_ item: ActionItem, x: CGFloat, width: CGFloat, iconX: CGFloat, icon: IconName,
                            color: UIColor, count: Int) {
        let overflow = ActionBarView.overflow
        let height = ActionBarView.rowHeight + 2 * overflow
        item.frame = CGRect(x: x, y: -overflow, width: width, height: height)
        item.iconView.image = Icons.image(icon, size: 18)
        item.iconView.tintColor = color
        // the icon is 7 pt from the top of the row
        item.iconView.frame = CGRect(x: iconX, y: overflow + 7, width: 18, height: 18)

        let text = count > 0 ? Format.count(count) : ""
        item.countLabel.text = text
        item.countLabel.textColor = color
        item.countLabel.isHidden = text.isEmpty
        let fitted = item.countLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: height))
        item.countLabel.frame = CGRect(x: iconX + 22, y: 0, width: ceil(fitted.width), height: height)
    }

    @objc private func replyTapped() {
        onReply?()
    }

    @objc private func repostTapped() {
        onRepost?()
    }

    @objc private func likeTapped() {
        // the heart bounces when the post is being liked, not when the like is taken back
        if let tweet = tweet, !tweet.liked {
            LikeFeedback.play(on: likeItem.iconView)
        }
        onLike?()
    }

    @objc private func bookmarkTapped() {
        onBookmark?()
    }

    @objc private func shareTapped() {
        onShare?()
    }
}

/// The action row of the focal post (ui-spec §3.9): five equal slots across 48 pt, each with a 22 pt icon and its
/// count, centred as one group. Bookmark shows its count here, share none.
final class FocalActionBarView: UIView {
    var onReply: (() -> Void)?
    var onRepost: (() -> Void)?
    var onLike: (() -> Void)?
    var onBookmark: (() -> Void)?
    var onShare: (() -> Void)?

    private static let rowHeight: CGFloat = 48

    private weak var tweet: Tweet?
    private let replyItem = ActionItem(frame: .zero)
    private let repostItem = ActionItem(frame: .zero)
    private let likeItem = ActionItem(frame: .zero)
    private let bookmarkItem = ActionItem(frame: .zero)
    private let shareItem = ActionItem(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setUp()
    }

    private func setUp() {
        backgroundColor = UIColor.clear
        let items: [ActionItem] = [replyItem, repostItem, likeItem, bookmarkItem, shareItem]
        for item in items {
            addSubview(item)
        }
        replyItem.addTarget(self, action: #selector(replyTapped), for: .touchUpInside)
        repostItem.addTarget(self, action: #selector(repostTapped), for: .touchUpInside)
        likeItem.addTarget(self, action: #selector(likeTapped), for: .touchUpInside)
        bookmarkItem.addTarget(self, action: #selector(bookmarkTapped), for: .touchUpInside)
        shareItem.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
    }

    /// Shows the counts and states of `tweet` across `width` points.
    func configure(tweet: Tweet, width: CGFloat) {
        self.tweet = tweet
        let palette = Theme.palette
        let secondary = palette.secondaryText
        let slot = width / 5

        let repostColor: UIColor = tweet.retweeted ? palette.repost : secondary
        let likeIcon: IconName = tweet.liked ? .heartFill : .heart
        let likeColor: UIColor = tweet.liked ? palette.like : secondary
        let bookmarkIcon: IconName = tweet.bookmarked ? .bookmarkFill : .bookmark
        let bookmarkColor: UIColor = tweet.bookmarked ? palette.accent : secondary

        layoutSlot(replyItem, index: 0, slot: slot, icon: .reply, color: secondary, count: tweet.replyCount)
        layoutSlot(repostItem, index: 1, slot: slot, icon: .repost, color: repostColor, count: tweet.retweetCount)
        layoutSlot(likeItem, index: 2, slot: slot, icon: likeIcon, color: likeColor, count: tweet.likeCount)
        layoutSlot(bookmarkItem, index: 3, slot: slot, icon: bookmarkIcon, color: bookmarkColor,
                   count: tweet.bookmarkCount)
        layoutSlot(shareItem, index: 4, slot: slot, icon: .share, color: secondary, count: 0)
    }

    private func layoutSlot(_ item: ActionItem, index: Int, slot: CGFloat, icon: IconName, color: UIColor,
                            count: Int) {
        let height = FocalActionBarView.rowHeight
        item.frame = CGRect(x: slot * CGFloat(index), y: 0, width: slot, height: height)

        let text = count > 0 ? Format.count(count) : ""
        item.countLabel.text = text
        item.countLabel.textColor = color
        item.countLabel.isHidden = text.isEmpty
        let fitted = item.countLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: height))
        let textWidth = ceil(fitted.width)

        // icon, gap of 4 pt and count, centred in the slot as one group
        let groupWidth: CGFloat = text.isEmpty ? 22 : 22 + 4 + textWidth
        let startX = (slot - groupWidth) / 2
        item.iconView.image = Icons.image(icon, size: 22)
        item.iconView.tintColor = color
        item.iconView.frame = CGRect(x: startX, y: (height - 22) / 2, width: 22, height: 22)
        item.countLabel.frame = CGRect(x: startX + 26, y: 0, width: textWidth, height: height)
    }

    @objc private func replyTapped() {
        onReply?()
    }

    @objc private func repostTapped() {
        onRepost?()
    }

    @objc private func likeTapped() {
        if let tweet = tweet, !tweet.liked {
            LikeFeedback.play(on: likeItem.iconView)
        }
        onLike?()
    }

    @objc private func bookmarkTapped() {
        onBookmark?()
    }

    @objc private func shareTapped() {
        onShare?()
    }
}

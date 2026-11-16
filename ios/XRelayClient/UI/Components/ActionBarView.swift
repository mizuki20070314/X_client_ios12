import UIKit

/// The icon and count of one action. The control is the touch target; its icon and count are drawn inside it.
fileprivate final class ActionItem: UIControl {
    let iconView = UIImageView()
    let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        countLabel.font = Theme.font(13)
        countLabel.numberOfLines = 1
        countLabel.lineBreakMode = .byTruncatingTail
        // a count wider than its room shrinks first; CountFit only gives a room that fits at the smallest scale
        countLabel.adjustsFontSizeToFitWidth = true
        countLabel.minimumScaleFactor = CountFit.minimumScale
        addSubview(iconView)
        addSubview(countLabel)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The width of `text` in the count font (13 pt), rounded up. Zero for an empty text.
    static func naturalWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let size = NSString(string: text).size(withAttributes: [NSAttributedString.Key.font: Theme.font(13)])
        return ceil(size.width)
    }

    /// Places the icon (a square of `iconSide` with its top left corner at `iconOrigin`) and the count 4 pt to its right.
    /// `countWidth` is the room the count gets: 0 hides it; less room than the text makes the label shrink.
    func show(icon: IconName, color: UIColor, count: String, iconOrigin: CGPoint, iconSide: CGFloat,
              height: CGFloat, countWidth: CGFloat) {
        iconView.image = Icons.image(icon, size: iconSide)
        iconView.tintColor = color
        iconView.frame = CGRect(x: iconOrigin.x, y: iconOrigin.y, width: iconSide, height: iconSide)
        countLabel.text = count
        countLabel.textColor = color
        countLabel.isHidden = count.isEmpty || countWidth <= 0
        let countX = iconOrigin.x + iconSide + 4
        countLabel.frame = CGRect(x: countX, y: 0, width: max(0, countWidth), height: height)
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

/// What a count shows in a room of `room` points (the width of its label). The full text when it fits at 80 % or more
/// (the label then shrinks to it); else the shorter form (the decimal dropped: 13.4万 -> 13万) when that fits at 80 %;
/// else nothing, the icon alone. Widths come from the count font, so they are the device's own.
fileprivate enum CountFit {
    /// The smallest scale a count may shrink to.
    /// 0.72 (about 9.4 pt) keeps four-digit counts such as "9,999" on a 320 pt screen.
    static let minimumScale: CGFloat = 0.72

    /// The text to show for `count` in `room` points, and the width of its label (0 for the icon alone).
    static func fit(_ count: Int, room: CGFloat) -> (text: String, width: CGFloat) {
        guard count > 0, room > 0 else { return ("", 0) }
        let full = Format.count(count)
        if fits(full, in: room) {
            return (full, min(ActionItem.naturalWidth(full), room))
        }
        let short = shorterForm(full)
        if short != full, fits(short, in: room) {
            return (short, min(ActionItem.naturalWidth(short), room))
        }
        return ("", 0)
    }

    /// True when `text` is at most `room` wide once shrunk to the smallest scale.
    static func fits(_ text: String, in room: CGFloat) -> Bool {
        return ActionItem.naturalWidth(text) * minimumScale <= room
    }

    /// The text without its decimal, for values from 10,000 on: "13.4万" -> "13万", "1.2億" -> "1億". Any other text is
    /// returned unchanged, so the caller sees that there is no shorter form.
    static func shorterForm(_ text: String) -> String {
        guard let dot = text.firstIndex(of: "."), let unit = text.last, unit == "万" || unit == "億" else {
            return text
        }
        return String(text[..<dot]) + String(unit)
    }
}

/// The x positions of one list row `width` points wide (the numbers are on ActionBarView).
private struct RowLayout {
    /// Left edge of the share icon; its right edge is the row's right edge.
    let shareIconX: CGFloat
    /// Left edge of the bookmark icon: its right edge is 12 pt left of the share icon.
    let bookmarkIconX: CGFloat
    /// Width of one of the four left slots; they end 4 pt before the bookmark icon.
    let slot: CGFloat

    init(width: CGFloat) {
        shareIconX = width - 18
        bookmarkIconX = shareIconX - 12 - 18
        slot = (bookmarkIconX - 4) / 4
    }

    func leftX(_ index: Int) -> CGFloat {
        return slot * CGFloat(index)
    }

    /// The room of a count in a left slot: the slot less the icon (18) and its gap (4).
    var countRoom: CGFloat {
        return max(0, slot - 22)
    }
}

/// The action row under a post in a list (ui-spec §3.9), 32 pt high. Reply, repost, like and views share the left part
/// of the row; bookmark and share sit at the right. It observes nothing itself: the cell calls `configure` again when the
/// post changes.
///
/// Horizontal layout for a row W points wide (`RowLayout`):
///   share icon     W - 18 ... W          target W - 27 ... W + 9 (36 pt; its last 9 pt run into the cell's padding)
///   bookmark icon  W - 48 ... W - 30     12 pt gap to the share icon; target W - 57 ... W - 21, centred on the icon
///   left slot i    slot = (W - 52) / 4; slot i starts at i * slot, and the four end 4 pt before the bookmark icon
///   left icon i    at i * slot, 18 pt; its count starts at i * slot + 22 and is slot - 22 wide at most
///
/// W = 246 (iPod touch, contentWidth 246): share icon 228 ... 246, bookmark icon 198 ... 216, slot 48.5. The left icons
///   are at 0, 48.5, 97 and 145.5, the slots end at 194, so the count room is 26.5 pt. Targets: bookmark 189 ... 225,
///   share 219 ... 255; they overlap by 6 pt, and share is on top.
/// W = 343: share icon 325 ... 343, bookmark icon 295 ... 313, slot 72.75. The left icons are at 0, 72.75, 145.5 and
///   218.25, the slots end at 291, so the count room is 50.75 pt. Targets: bookmark 286 ... 322, share 316 ... 352.
///
/// What a count shows (`CountFit`): the full text when it fits the room at 80 % (the label shrinks to it), else the
/// shorter form (decimal dropped: 13.4万 -> 13万) under the same test, else the icon alone. Widths at 13 pt with the
/// measure used here (digit 7.5, comma or dot 3.5, 万 13). "Fits at 80 %" means width * 0.8 <= room.
///   W = 246, room 26.5: 9,999 = 33.5 (26.8 at 80 %): icon only, 0.3 pt short. 2.8万 = 31.5 (25.2): full, shrunk to 0.84.
///     13.4万 = 39.0 (31.2): shortened to 13万 = 28.0 (22.4), shrunk to 0.95. 1,234万 = 46.5 (37.2): no decimal, so no
///     shorter form: icon only. 999.9万 is not a value Format.count gives (99.9万 is the largest decimal form); it would be
///     icon only too (999万 = 35.5, 28.4 at 80 %).
///   W = 343, room 50.75: 9,999 (33.5), 2.8万 (31.5), 13.4万 (39.0) and 1,234万 (46.5) are all full, without shrinking.
///
/// Touch targets: a left target covers its slot (36 pt high) and ends where the next icon starts. The bookmark and share
/// targets are 36 pt wide and overlap by 6 pt (share wins there). At 246 the bookmark target also reaches 5 pt into the
/// room of the views count, where a long count fills it. No target covers another action's icon.
final class ActionBarView: UIView {
    var onReply: (() -> Void)?
    var onRepost: (() -> Void)?
    var onLike: (() -> Void)?
    var onBookmark: (() -> Void)?
    var onShare: (() -> Void)?

    private static let rowHeight: CGFloat = 32
    /// Targets are 36 pt high: 2 pt beyond the row on each side.
    private static let overflow: CGFloat = 2
    /// Bookmark and share targets are 36 pt wide squares centred on their 18 pt icons.
    private static let targetSide: CGFloat = 36
    /// The share target reaches 9 pt past the row's right edge (into the cell's padding).
    private static let shareOverhang: CGFloat = 9

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

    /// The targets reach 2 pt above and below the row, and the share target 9 pt past the right edge.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let reach = CGRect(x: 0, y: -ActionBarView.overflow, width: bounds.width + ActionBarView.shareOverhang,
                           height: bounds.height + 2 * ActionBarView.overflow)
        return reach.contains(point)
    }

    /// Shows the counts and states of `tweet` in a row `width` points wide.
    func configure(tweet: Tweet, width: CGFloat) {
        self.tweet = tweet
        let palette = Theme.palette
        let secondary = palette.secondaryText
        let row = RowLayout(width: width)

        let repostColor: UIColor = tweet.retweeted ? palette.repost : secondary
        let likeColor: UIColor = tweet.liked ? palette.like : secondary
        let likeIcon: IconName = tweet.liked ? .heartFill : .heart
        let bookmarkColor: UIColor = tweet.bookmarked ? palette.accent : secondary
        let bookmarkIcon: IconName = tweet.bookmarked ? .bookmarkFill : .bookmark

        layoutLeft(replyItem, index: 0, row: row, icon: .reply, color: secondary, count: tweet.replyCount)
        layoutLeft(repostItem, index: 1, row: row, icon: .repost, color: repostColor, count: tweet.retweetCount)
        layoutLeft(likeItem, index: 2, row: row, icon: likeIcon, color: likeColor, count: tweet.likeCount)
        // views exist only when the server counts them; a count of 0 shows the icon alone
        viewsItem.isHidden = tweet.viewCount == nil
        layoutLeft(viewsItem, index: 3, row: row, icon: .views, color: secondary, count: tweet.viewCount ?? 0)
        // bookmark and share show no count
        layoutRight(bookmarkItem, iconX: row.bookmarkIconX, icon: bookmarkIcon, color: bookmarkColor)
        layoutRight(shareItem, iconX: row.shareIconX, icon: .share, color: secondary)
    }

    /// One of the four left items: its target is its whole slot, its icon sits at the slot's left edge and its count
    /// 22 pt in, shown as `CountFit` decides for the room of the slot.
    private func layoutLeft(_ item: ActionItem, index: Int, row: RowLayout, icon: IconName, color: UIColor,
                            count: Int) {
        let overflow = ActionBarView.overflow
        let height = ActionBarView.rowHeight + 2 * overflow
        item.frame = CGRect(x: row.leftX(index), y: -overflow, width: row.slot, height: height)
        let shown = CountFit.fit(count, room: row.countRoom)
        item.show(icon: icon, color: color, count: shown.text, iconOrigin: CGPoint(x: 0, y: overflow + 7),
                  iconSide: 18, height: height, countWidth: shown.width)
    }

    /// Bookmark or share: a 36 pt square target centred on the 18 pt icon at `iconX`.
    private func layoutRight(_ item: ActionItem, iconX: CGFloat, icon: IconName, color: UIColor) {
        let side = ActionBarView.targetSide
        let inset = (side - 18) / 2
        item.frame = CGRect(x: iconX - inset, y: -ActionBarView.overflow, width: side, height: side)
        item.show(icon: icon, color: color, count: "", iconOrigin: CGPoint(x: inset, y: inset), iconSide: 18,
                  height: side, countWidth: 0)
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

/// The action row of the focal post (ui-spec §3.9), 48 pt high across the full cell width: five equal slots, each with a
/// 22 pt icon and its count, centred as one group. The room of a count is the slot less 26 pt (icon 22 + gap 4), the same
/// rule as the list row, and `CountFit` decides the text. At 320 pt (iPod) the slot is 64 and the room 38: 9,999 (33.5)
/// and 2.8万 (31.5) are full, 13.4万 (39.0) is full at 0.97, and 999.9万 (46.5, not a Format value) and 1,234万 (46.5)
/// are full at 0.82. At 375 pt the slot is 75 and the room 49, so every count is full without shrinking. Bookmark shows
/// its count here, share none.
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
        // icon 22 + gap 4 + count, centred in the slot as one group; the count's room is the slot less 26
        let shown = CountFit.fit(count, room: max(0, slot - 26))
        let groupWidth: CGFloat = shown.width > 0 ? 22 + 4 + shown.width : 22
        let startX = (slot - groupWidth) / 2
        item.show(icon: icon, color: color, count: shown.text, iconOrigin: CGPoint(x: startX, y: (height - 22) / 2),
                  iconSide: 22, height: height, countWidth: shown.width)
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

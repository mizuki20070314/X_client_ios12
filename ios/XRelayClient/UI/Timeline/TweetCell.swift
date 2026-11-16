import UIKit

/// The grey line above a post: "<name>さんがリポスト" for a repost, else the server's pin or text context.
enum TweetContextLine {
    struct Display {
        let icon: IconName?
        let text: String
    }

    static func display(for entry: TweetEntry) -> Display? {
        if let reposter = entry.tweet.retweetedBy {
            // the logged-in user's own repost reads as done
            let isMine = Session.shared.me?.id == reposter.id
            let text = isMine ? "リポスト済み" : reposter.name + "さんがリポスト"
            return Display(icon: .repost, text: text)
        }
        guard let text = entry.contextText, !text.isEmpty else { return nil }
        let icon: IconName? = (entry.contextKind == "pin") ? .pin : nil
        return Display(icon: icon, text: text)
    }
}

/// "返信先: @a さん": the handles in the accent colour, the rest in the secondary colour (ui-spec.md §4.3-4).
enum ReplyLine {
    static func attributed(handles: [String]) -> NSAttributedString {
        let palette = Theme.palette
        let font = Theme.font(15)
        let secondary: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.secondaryText]
        let accent: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.accent]
        let shown = handles.prefix(2).map { "@" + $0 }.joined(separator: " ")
        let others = handles.count - 2
        let result = NSMutableAttributedString(string: "返信先: ", attributes: secondary)
        result.append(NSAttributedString(string: shown, attributes: accent))
        if others > 0 {
            result.append(NSAttributedString(string: "、他\(others)人", attributes: secondary))
        }
        result.append(NSAttributedString(string: "さん", attributes: secondary))
        return result
    }
}

/// Frames of a post's attachments: the media grid, else the card, then the quoted post (ui-spec.md §4.3-6).
struct TweetAttachmentFrames {
    var media: CGRect?
    var card: CGRect?
    var quote: CGRect?
    /// The y below the last attachment, or the start y when there is none.
    var bottom: CGFloat

    static func make(for tweet: Tweet, x: CGFloat, width: CGFloat, top: CGFloat, firstGap: CGFloat) -> TweetAttachmentFrames {
        var frames = TweetAttachmentFrames(media: nil, card: nil, quote: nil, bottom: top)
        var y = top
        var gap = firstGap
        if !tweet.media.isEmpty {
            // a post with media shows no card
            let height = MediaGridView.height(for: tweet.media, width: width)
            frames.media = CGRect(x: x, y: y + gap, width: width, height: height)
            y += gap + height
            gap = TimelineSpec.attachmentGap
        } else if let card = tweet.card {
            let height = CardView.height(card: card, width: width)
            frames.card = CGRect(x: x, y: y + gap, width: width, height: height)
            y += gap + height
            gap = TimelineSpec.attachmentGap
        }
        if tweet.quote != nil || tweet.quoteUnavailable != nil {
            let height = QuoteView.height(tweet: tweet.quote, unavailable: tweet.quoteUnavailable, width: width)
            frames.quote = CGRect(x: x, y: y + gap, width: width, height: height)
            y += gap + height
        }
        frames.bottom = y
        return frames
    }
}

/// The media grid, the card and the quoted post of a post row. Shared by TweetCell and FocalTweetCell.
final class TweetAttachmentViews {
    let mediaView = MediaGridView(frame: .zero)
    let cardView = CardView(frame: .zero)
    let quoteView = QuoteView(frame: .zero)
    var onMediaTap: ((Int) -> Void)?
    var onQuoteTap: (() -> Void)?

    /// Adds the views to the cell and wires their taps. Called once, from the cell's setup.
    func install(in container: UIView) {
        mediaView.onTap = { [weak self] index in self?.onMediaTap?(index) }
        quoteView.onTap = { [weak self] in self?.onQuoteTap?() }
        container.addSubview(mediaView)
        container.addSubview(cardView)
        container.addSubview(quoteView)
        mediaView.isHidden = true
        cardView.isHidden = true
        quoteView.isHidden = true
    }

    func apply(_ tweet: Tweet, frames: TweetAttachmentFrames) {
        if let frame = frames.media {
            mediaView.frame = frame
            mediaView.isHidden = false
            mediaView.configure(media: tweet.media, width: frame.width, interactive: true)
        } else {
            hideMedia()
        }
        if let frame = frames.card, let card = tweet.card {
            cardView.frame = frame
            cardView.isHidden = false
            cardView.configure(card: card, width: frame.width)
        } else {
            cardView.isHidden = true
        }
        if let frame = frames.quote {
            quoteView.frame = frame
            quoteView.isHidden = false
            quoteView.configure(tweet: tweet.quote, unavailable: tweet.quoteUnavailable, width: frame.width)
        } else {
            hideQuote()
        }
    }

    /// Drops the pictures that are still loading (the row is being reused).
    func reset() {
        hideMedia()
        cardView.isHidden = true
        hideQuote()
    }

    private func hideMedia() {
        mediaView.isHidden = true
        mediaView.configure(media: [], width: mediaView.bounds.width, interactive: false)
    }

    private func hideQuote() {
        quoteView.isHidden = true
        quoteView.configure(tweet: nil, unavailable: nil, width: quoteView.bounds.width)
    }
}

/// The frames of a post row at one width (ui-spec.md §4.3). Built once per width by TweetRow and cached there.
struct TweetLayout {
    let width: CGFloat
    let height: CGFloat
    let hasContext: Bool
    let contextIconFrame: CGRect
    let contextTextFrame: CGRect
    let avatarFrame: CGRect
    let nameFrame: CGRect
    let overflowFrame: CGRect
    let replyFrame: CGRect?
    let replyText: NSAttributedString?
    let textFrame: CGRect?
    let text: TextLayout?
    let moreFrame: CGRect?
    let attachments: TweetAttachmentFrames
    let actionFrame: CGRect
    let threadAbove: CGRect?
    let threadBelow: CGRect?
    let hairlineFrame: CGRect?
}

extension TweetLayout {
    static func make(entry: TweetEntry, width: CGFloat) -> TweetLayout {
        let palette = Theme.palette
        let tweet = entry.tweet
        let pad = Metrics.pad(width)
        let contentX = Metrics.contentX(width)
        let contentWidth = Metrics.contentWidth(width)
        let avatarSize = Metrics.avatar
        let hasContext = TweetContextLine.display(for: entry) != nil

        var y = TimelineSpec.topPadding
        var contextIconFrame = CGRect.zero
        var contextTextFrame = CGRect.zero
        if hasContext {
            // the icon ends at the avatar's right edge
            contextIconFrame = CGRect(x: pad + avatarSize - 16, y: y, width: 16, height: 16)
            contextTextFrame = CGRect(x: contentX, y: y, width: contentWidth, height: 16)
            y += 20
        }

        let avatarY = y
        let avatarFrame = CGRect(x: pad, y: avatarY, width: avatarSize, height: avatarSize)
        let nameFrame = CGRect(x: contentX, y: avatarY, width: contentWidth - 28, height: TimelineSpec.nameLineHeight)
        let nameCenterY = avatarY + TimelineSpec.nameLineHeight / 2
        let overflowFrame = TimelineSpec.overflowFrame(width: width, pad: pad, centerY: nameCenterY)
        y += 22

        var replyFrame: CGRect?
        var replyText: NSAttributedString?
        // a reply that continues the row above shows no reply line
        if !tweet.replyToHandles.isEmpty && !entry.above {
            replyFrame = CGRect(x: contentX, y: y, width: contentWidth, height: 20)
            replyText = ReplyLine.attributed(handles: tweet.replyToHandles)
            y += 22
        }

        var textFrame: CGRect?
        var text: TextLayout?
        var moreFrame: CGRect?
        if !tweet.text.isEmpty {
            let attributed = TweetText.attributed(tweet.text, entities: tweet.entities, font: Theme.font(15),
                                                  color: palette.text, linkColor: palette.accent, lineSpacing: 2)
            let layout = TextLayout(attributed, width: contentWidth, maxLines: tweet.isLong ? 10 : 0,
                                    entities: tweet.entities)
            textFrame = CGRect(x: contentX, y: y, width: contentWidth, height: layout.size.height)
            text = layout
            y += layout.size.height
            if layout.isTruncated {
                moreFrame = CGRect(x: contentX, y: y, width: contentWidth, height: 22)
                y += 22
            }
        }

        // 10 pt after the name line when nothing but the name line comes before the attachments
        let hasTextBlock = replyFrame != nil || textFrame != nil
        let firstGap = hasTextBlock ? TimelineSpec.attachmentGap : TimelineSpec.nameAttachmentGap
        let attachments = TweetAttachmentFrames.make(for: tweet, x: contentX, width: contentWidth, top: y,
                                                     firstGap: firstGap)
        y = attachments.bottom

        let actionFrame = CGRect(x: contentX, y: y + 6, width: contentWidth, height: TimelineSpec.actionBarHeight)
        y += 6 + TimelineSpec.actionBarHeight + 6

        let minimumHeight = TimelineSpec.topPadding + avatarSize + TimelineSpec.topPadding
        let height = max(y, minimumHeight)

        let threadX = pad + avatarSize / 2 - TimelineSpec.threadWidth / 2
        var threadAbove: CGRect?
        if entry.above {
            threadAbove = CGRect(x: threadX, y: 0, width: TimelineSpec.threadWidth,
                                 height: avatarY - TimelineSpec.threadGap)
        }
        let belowY = avatarY + avatarSize + TimelineSpec.threadGap
        var threadBelow: CGRect?
        if entry.below {
            threadBelow = CGRect(x: threadX, y: belowY, width: TimelineSpec.threadWidth,
                                 height: max(0, height - belowY))
        }
        var hairlineFrame: CGRect?
        if !entry.below {
            hairlineFrame = CGRect(x: 0, y: height - Metrics.hairline, width: width, height: Metrics.hairline)
        }

        return TweetLayout(
            width: width,
            height: height,
            hasContext: hasContext,
            contextIconFrame: contextIconFrame,
            contextTextFrame: contextTextFrame,
            avatarFrame: avatarFrame,
            nameFrame: nameFrame,
            overflowFrame: overflowFrame,
            replyFrame: replyFrame,
            replyText: replyText,
            textFrame: textFrame,
            text: text,
            moreFrame: moreFrame,
            attachments: attachments,
            actionFrame: actionFrame,
            threadAbove: threadAbove,
            threadBelow: threadBelow,
            hairlineFrame: hairlineFrame
        )
    }
}

extension TweetRow {
    /// The layout at `width`, computed once and then reused (the cell only applies it).
    func layout(for width: CGFloat) -> TweetLayout {
        if let cached = layoutCache, cached.width == width {
            return cached
        }
        let fresh = TweetLayout.make(entry: entry, width: width)
        layoutCache = fresh
        return fresh
    }
}

/// A post in a list: context line, avatar, name line, reply line, text, attachments and the action bar
/// (ui-spec.md §4.3).
final class TweetCell: TimelineCellBase {
    private let contextIcon = UIImageView()
    private let contextLabel = UILabel()
    private let avatar = AvatarView(frame: .zero)
    private let nameLine = NameLineView(frame: .zero)
    private let overflowButton = UIButton(type: .custom)
    private let replyLabel = UILabel()
    private let bodyLabel = LinkLabel(frame: .zero)
    private let moreLabel = UILabel()
    private let attachments = TweetAttachmentViews()
    private let actionBar = ActionBarView(frame: .zero)

    /// The post of the row on screen. The closures read it, so they follow the row through reuse.
    private var tweet: Tweet?
    private var contentWidth: CGFloat = 0
    private var observedTweet: Tweet?
    private var changeObserver: NSObjectProtocol?

    override func setUpContent() {
        let palette = Theme.palette
        contextLabel.font = Theme.font(13, .semibold)
        contextLabel.numberOfLines = 1
        contextLabel.lineBreakMode = .byTruncatingTail
        replyLabel.font = Theme.font(15)
        replyLabel.numberOfLines = 1
        replyLabel.lineBreakMode = .byTruncatingTail
        moreLabel.font = Theme.font(15)
        moreLabel.textColor = palette.accent
        moreLabel.text = "さらに表示"
        overflowButton.setImage(Icons.image(.overflow, size: TimelineSpec.overflowIconSize), for: .normal)
        overflowButton.tintColor = palette.secondaryText
        overflowButton.addTarget(self, action: #selector(overflowTapped), for: .touchUpInside)

        // entity taps (links, mentions, hashtags) open their target; other taps reach the row
        bodyLabel.onTapEntity = { entity in Router.open(entity: entity) }
        avatar.onTap = { [weak self] in
            guard let user = self?.tweet?.user else { return }
            Router.openProfile(user: user)
        }
        attachments.onMediaTap = { [weak self] index in
            guard let tweet = self?.tweet else { return }
            Router.openMedia(tweet: tweet, index: index)
        }
        attachments.onQuoteTap = { [weak self] in
            guard let quote = self?.tweet?.quote else { return }
            Router.openTweet(quote)
        }
        actionBar.onReply = { [weak self] in
            self?.withTweet { TweetActions.reply(to: $0) }
        }
        actionBar.onRepost = { [weak self] in
            self?.withTweet { TweetActions.showRepostMenu(for: $0) }
        }
        actionBar.onLike = { [weak self] in
            self?.withTweet { TweetActions.toggleLike($0) }
        }
        actionBar.onBookmark = { [weak self] in
            self?.withTweet { TweetActions.toggleBookmark($0) }
        }
        actionBar.onShare = { [weak self] in
            self?.withTweet { TweetActions.showShareMenu(for: $0) }
        }

        let views: [UIView] = [contextIcon, contextLabel, avatar, nameLine, overflowButton, replyLabel,
                               bodyLabel, moreLabel]
        for view in views {
            contentView.addSubview(view)
        }
        attachments.install(in: contentView)
        contentView.addSubview(actionBar)
    }

    func configure(_ row: TweetRow, layout: TweetLayout) {
        let tweet = row.tweet
        self.tweet = tweet
        contentWidth = Metrics.contentWidth(layout.width)
        observeChanges(of: tweet)

        applyContext(row.entry, layout: layout)
        avatar.timelinePlace(layout.avatarFrame)
        avatar.set(user: tweet.user, size: Metrics.avatar)
        nameLine.timelinePlace(layout.nameFrame)
        nameLine.showsHandle = true
        nameLine.set(user: tweet.user, time: Format.relativeTime(tweet.createdAt), width: layout.nameFrame.width)
        overflowButton.frame = layout.overflowFrame

        replyLabel.timelinePlace(layout.replyFrame)
        replyLabel.attributedText = layout.replyText
        bodyLabel.timelinePlace(layout.textFrame)
        bodyLabel.textLayout = layout.text
        moreLabel.timelinePlace(layout.moreFrame)

        attachments.apply(tweet, frames: layout.attachments)

        actionBar.timelinePlace(layout.actionFrame)
        actionBar.configure(tweet: tweet, width: layout.actionFrame.width)
        threadAbove.timelinePlace(layout.threadAbove)
        threadBelow.timelinePlace(layout.threadBelow)
        hairline.timelinePlace(layout.hairlineFrame)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopObserving()
        tweet = nil
        avatar.set(url: nil, square: false, size: Metrics.avatar)
        attachments.reset()
        bodyLabel.textLayout = nil
    }

    deinit {
        stopObserving()
    }

    // MARK: - Private

    private func applyContext(_ entry: TweetEntry, layout: TweetLayout) {
        guard let context = TweetContextLine.display(for: entry) else {
            contextIcon.timelinePlace(nil)
            contextLabel.timelinePlace(nil)
            return
        }
        let palette = Theme.palette
        contextLabel.timelinePlace(layout.contextTextFrame)
        contextLabel.text = context.text
        contextLabel.textColor = palette.secondaryText
        if let icon = context.icon {
            contextIcon.timelinePlace(layout.contextIconFrame)
            contextIcon.image = Icons.image(icon, size: 16)
            contextIcon.tintColor = palette.secondaryText
        } else {
            contextIcon.timelinePlace(nil)
        }
    }

    private func withTweet(_ action: (Tweet) -> Void) {
        guard let tweet = tweet else { return }
        action(tweet)
    }

    @objc private func overflowTapped() {
        withTweet { TweetActions.showOverflowMenu(for: $0) }
    }

    /// Re-applies the action bar when the post changes (counts, liked state). The text is laid out once per row.
    private func observeChanges(of tweet: Tweet) {
        if observedTweet === tweet {
            return
        }
        stopObserving()
        observedTweet = tweet
        changeObserver = NotificationCenter.default.addObserver(forName: Tweet.didChange, object: tweet, queue: nil) {
            [weak self] _ in
            guard let self = self, let current = self.tweet else { return }
            self.actionBar.configure(tweet: current, width: self.contentWidth)
        }
    }

    private func stopObserving() {
        if let token = changeObserver {
            NotificationCenter.default.removeObserver(token)
        }
        changeObserver = nil
        observedTweet = nil
    }
}

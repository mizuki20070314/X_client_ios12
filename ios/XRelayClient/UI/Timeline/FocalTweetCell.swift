import UIKit

/// The frames of the focal post at one width (ui-spec.md §4.4). Built once per width by FocalTweetRow.
struct FocalTweetLayout {
    let width: CGFloat
    let height: CGFloat
    let hasContext: Bool
    let contextIconFrame: CGRect
    let contextTextFrame: CGRect
    let avatarFrame: CGRect
    let nameFrame: CGRect
    let handleFrame: CGRect
    let overflowFrame: CGRect
    /// Present when the author is not followed yet; the cell hides it for the logged-in user.
    let followFrame: CGRect?
    let replyFrame: CGRect?
    let replyText: NSAttributedString?
    let textFrame: CGRect?
    let text: TextLayout?
    let attachments: TweetAttachmentFrames
    let timeFrame: CGRect
    /// The metadata line (date and view count): one line, or two when the whole line does not fit.
    let meta: TextLayout
    /// The hairline between the time and the action bar (pad to W - pad).
    let topRuleFrame: CGRect
    let actionFrame: CGRect
    let hairlineFrame: CGRect
    let threadAbove: CGRect?
}

extension FocalTweetLayout {
    static func make(entry: TweetEntry, width: CGFloat) -> FocalTweetLayout {
        let palette = Theme.palette
        let tweet = entry.tweet
        let pad = Metrics.pad(width)
        let contentX = Metrics.contentX(width)
        let contentWidth = Metrics.contentWidth(width)
        let avatarSize = Metrics.avatar
        let bodyWidth = width - 2 * pad
        let hasContext = TweetContextLine.display(for: entry) != nil

        var y = TimelineSpec.topPadding
        var contextIconFrame = CGRect.zero
        var contextTextFrame = CGRect.zero
        if hasContext {
            contextIconFrame = CGRect(x: pad + avatarSize - 16, y: y, width: 16, height: 16)
            contextTextFrame = CGRect(x: contentX, y: y, width: contentWidth, height: 16)
            y += 20
        }

        // header block: the name line and the handle line share the avatar's height
        let avatarY = y
        let avatarFrame = CGRect(x: pad, y: avatarY, width: avatarSize, height: avatarSize)
        let overflowFrame = TimelineSpec.overflowFrame(width: width, pad: pad,
                                                       centerY: avatarY + TimelineSpec.nameLineHeight / 2)
        var followFrame: CGRect?
        var nameRight = overflowFrame.minX - 8
        if !tweet.user.following {
            let followWidth = TimelineSpec.followWidth
            let followX = overflowFrame.minX - 8 - followWidth
            followFrame = CGRect(x: followX, y: avatarY + 4, width: followWidth, height: 32)
            nameRight = followX - 8
        }
        let nameWidth = max(0, nameRight - contentX)
        let nameFrame = CGRect(x: contentX, y: avatarY, width: nameWidth, height: TimelineSpec.nameLineHeight)
        let handleFrame = CGRect(x: contentX, y: avatarY + 20, width: nameWidth, height: 20)
        y += avatarSize + 12

        var replyFrame: CGRect?
        var replyText: NSAttributedString?
        if !tweet.replyToHandles.isEmpty {
            replyFrame = CGRect(x: pad, y: y, width: bodyWidth, height: 20)
            replyText = ReplyLine.attributed(handles: tweet.replyToHandles)
            y += 24
        }

        var textFrame: CGRect?
        var text: TextLayout?
        if !tweet.text.isEmpty {
            let attributed = TweetText.attributed(tweet.text, entities: tweet.entities, font: Theme.font(17),
                                                  color: palette.text, linkColor: palette.accent, lineSpacing: 3)
            let layout = TextLayout(attributed, width: bodyWidth, maxLines: 0, entities: tweet.entities)
            textFrame = CGRect(x: pad, y: y, width: bodyWidth, height: layout.size.height)
            text = layout
            y += layout.size.height
        }

        let attachments = TweetAttachmentFrames.make(for: tweet, x: pad, width: bodyWidth, top: y,
                                                     firstGap: TimelineSpec.attachmentGap)
        y = attachments.bottom

        y += 12
        let meta = metadataLayout(for: tweet, width: bodyWidth)
        // a single line is 20 pt high (ui-spec.md §4.4); a second line adds its own height
        let metaHeight = max(20, meta.size.height)
        let timeFrame = CGRect(x: pad, y: y, width: bodyWidth, height: metaHeight)
        y += metaHeight + 12

        let topRuleFrame = CGRect(x: pad, y: y, width: bodyWidth, height: Metrics.hairline)
        y += Metrics.hairline
        let actionFrame = CGRect(x: 0, y: y, width: width, height: TimelineSpec.focalActionBarHeight)
        y += TimelineSpec.focalActionBarHeight
        let hairlineFrame = CGRect(x: 0, y: y, width: width, height: Metrics.hairline)
        y += Metrics.hairline

        let threadX = pad + avatarSize / 2 - TimelineSpec.threadWidth / 2
        var threadAbove: CGRect?
        if entry.above {
            threadAbove = CGRect(x: threadX, y: 0, width: TimelineSpec.threadWidth,
                                 height: avatarY - TimelineSpec.threadGap)
        }

        return FocalTweetLayout(
            width: width,
            height: y,
            hasContext: hasContext,
            contextIconFrame: contextIconFrame,
            contextTextFrame: contextTextFrame,
            avatarFrame: avatarFrame,
            nameFrame: nameFrame,
            handleFrame: handleFrame,
            overflowFrame: overflowFrame,
            followFrame: followFrame,
            replyFrame: replyFrame,
            replyText: replyText,
            textFrame: textFrame,
            text: text,
            attachments: attachments,
            timeFrame: timeFrame,
            meta: meta,
            topRuleFrame: topRuleFrame,
            actionFrame: actionFrame,
            hairlineFrame: hairlineFrame,
            threadAbove: threadAbove
        )
    }
}

extension FocalTweetLayout {
    /// "午後8:48 · 2026年11月16日 · 13.4万 件の表示" (15 pt). When the whole line does not fit, the view count goes to
    /// a second line, so the break falls after the date part. No line limit: the height comes from this layout.
    static func metadataLayout(for tweet: Tweet, width: CGFloat) -> TextLayout {
        let oneLine = metadataText(for: tweet, countOnNewLine: false)
        let fitsOnOneLine = !TextLayout(oneLine, width: width, maxLines: 1).isTruncated
        let text = fitsOnOneLine ? oneLine : metadataText(for: tweet, countOnNewLine: true)
        return TextLayout(text, width: width, maxLines: 0)
    }

    private static func metadataText(for tweet: Tweet, countOnNewLine: Bool) -> NSAttributedString {
        let palette = Theme.palette
        let secondary: [NSAttributedString.Key: Any] = [
            .font: Theme.font(15),
            .foregroundColor: palette.secondaryText
        ]
        let result = NSMutableAttributedString(string: Format.fullTimestamp(tweet.createdAt), attributes: secondary)
        if let views = tweet.viewCount {
            let count: [NSAttributedString.Key: Any] = [
                .font: Theme.font(15, .bold),
                .foregroundColor: palette.text
            ]
            // the line break takes the place of the separator, so the second line starts with the count
            let separator = countOnNewLine ? "\n" : " · "
            result.append(NSAttributedString(string: separator, attributes: secondary))
            result.append(NSAttributedString(string: Format.count(views), attributes: count))
            result.append(NSAttributedString(string: " 件の表示", attributes: secondary))
        }
        return result
    }
}

extension FocalTweetRow {
    /// The layout at `width`, computed once and then reused.
    func layout(for width: CGFloat) -> FocalTweetLayout {
        if let cached = layoutCache, cached.width == width {
            return cached
        }
        let fresh = FocalTweetLayout.make(entry: entry, width: width)
        layoutCache = fresh
        return fresh
    }
}

/// The post a detail screen is about (ui-spec.md §4.4): larger text, the full time line and the large action bar.
/// It is not pressable: a tap on it does nothing.
final class FocalTweetCell: TimelineCellBase {
    private let contextIcon = UIImageView()
    private let contextLabel = UILabel()
    private let avatar = AvatarView(frame: .zero)
    private let nameLine = NameLineView(frame: .zero)
    private let handleLabel = UILabel()
    private let overflowButton = UIButton(type: .custom)
    private let followButton = FollowButton(frame: .zero)
    private let replyLabel = UILabel()
    private let bodyLabel = LinkLabel(frame: .zero)
    private let attachments = TweetAttachmentViews()
    private let metaLabel = LinkLabel(frame: .zero)
    private let topRule = UIView()
    private let actionBar = FocalActionBarView(frame: .zero)

    private var tweet: Tweet?
    /// The focal action bar spans the full width of the row.
    private var actionWidth: CGFloat = 0
    private var observedTweet: Tweet?
    private var changeObserver: NSObjectProtocol?

    override func setUpContent() {
        let palette = Theme.palette
        highlightsOnPress = false
        contextLabel.font = Theme.font(13, .semibold)
        contextLabel.numberOfLines = 1
        contextLabel.lineBreakMode = .byTruncatingTail
        handleLabel.font = Theme.font(15)
        handleLabel.textColor = palette.secondaryText
        handleLabel.numberOfLines = 1
        handleLabel.lineBreakMode = .byTruncatingTail
        replyLabel.font = Theme.font(15)
        replyLabel.numberOfLines = 1
        replyLabel.lineBreakMode = .byTruncatingTail
        topRule.backgroundColor = palette.separator
        overflowButton.setImage(Icons.image(.overflow, size: TimelineSpec.overflowIconSize), for: .normal)
        overflowButton.tintColor = palette.secondaryText
        overflowButton.addTarget(self, action: #selector(overflowTapped), for: .touchUpInside)

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

        let views: [UIView] = [contextIcon, contextLabel, avatar, nameLine, handleLabel, overflowButton,
                               followButton, replyLabel, bodyLabel, metaLabel, topRule]
        for view in views {
            contentView.addSubview(view)
        }
        attachments.install(in: contentView)
        contentView.addSubview(actionBar)
    }

    func configure(_ row: FocalTweetRow, layout: FocalTweetLayout) {
        let tweet = row.tweet
        self.tweet = tweet
        actionWidth = layout.width
        observeChanges(of: tweet)
        let isMine = tweet.user.id == Session.shared.me?.id

        applyContext(row.entry, layout: layout)
        avatar.timelinePlace(layout.avatarFrame)
        avatar.set(user: tweet.user, size: Metrics.avatar)
        nameLine.timelinePlace(layout.nameFrame)
        nameLine.showsHandle = false
        nameLine.set(user: tweet.user, time: nil, width: layout.nameFrame.width)
        handleLabel.timelinePlace(layout.handleFrame)
        handleLabel.text = "@" + tweet.user.handle
        overflowButton.frame = layout.overflowFrame

        let showsFollow = !isMine && !tweet.user.following
        followButton.timelinePlace(showsFollow ? layout.followFrame : nil)
        if showsFollow {
            followButton.set(user: tweet.user)
        }

        replyLabel.timelinePlace(layout.replyFrame)
        replyLabel.attributedText = layout.replyText
        bodyLabel.timelinePlace(layout.textFrame)
        bodyLabel.textLayout = layout.text

        attachments.apply(tweet, frames: layout.attachments)

        metaLabel.timelinePlace(layout.timeFrame)
        metaLabel.textLayout = layout.meta
        topRule.timelinePlace(layout.topRuleFrame)

        actionBar.timelinePlace(layout.actionFrame)
        actionBar.configure(tweet: tweet, width: layout.actionFrame.width)
        threadAbove.timelinePlace(layout.threadAbove)
        hairline.timelinePlace(layout.hairlineFrame)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopObserving()
        tweet = nil
        avatar.set(url: nil, square: false, size: Metrics.avatar)
        attachments.reset()
        bodyLabel.textLayout = nil
        metaLabel.textLayout = nil
    }

    deinit {
        stopObserving()
    }

    // MARK: - Private

    private func applyContext(_ entry: TweetEntry, layout: FocalTweetLayout) {
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

    /// Re-applies the action bar when the post changes, as the timeline cell does.
    private func observeChanges(of tweet: Tweet) {
        if observedTweet === tweet {
            return
        }
        stopObserving()
        observedTweet = tweet
        changeObserver = NotificationCenter.default.addObserver(forName: Tweet.didChange, object: tweet, queue: nil) {
            [weak self] _ in
            guard let self = self, let current = self.tweet else { return }
            self.actionBar.configure(tweet: current, width: self.actionWidth)
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

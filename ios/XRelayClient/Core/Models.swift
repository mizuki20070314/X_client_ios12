import Foundation

// Parsing helpers. Named "json…" so that they never collide with a property of the same meaning in a model.

/// A non-empty string, else nil (an empty cursor would make paging loop forever).
private func jsonText(_ json: JSON) -> String? {
    guard let text = json.string, !text.isEmpty else { return nil }
    return text
}

private func jsonURL(_ json: JSON) -> URL? {
    guard let text = jsonText(json) else { return nil }
    return URL(string: text)
}

/// Seconds since the Unix epoch.
private func jsonDate(_ json: JSON) -> Date? {
    guard let seconds = json.int else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(seconds))
}

private func jsonStrings(_ json: JSON) -> [String] {
    return json.array.compactMap { $0.string }
}

private func jsonEntities(_ json: JSON) -> [TextEntity] {
    return json.array.compactMap { TextEntity(json: $0) }
}

/// Pairs [start, end] (UTF-16 offsets) as NSRange; malformed pairs are dropped.
private func jsonRanges(_ json: JSON) -> [NSRange] {
    return json.array.compactMap { pair -> NSRange? in
        guard let start = pair[0].int, let end = pair[1].int, start >= 0, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

/// Drops the entities that reach past the end of their text, so that the UI can always apply their ranges.
private func clipped(_ entities: [TextEntity], to text: String) -> [TextEntity] {
    let length = text.utf16.count
    return entities.filter { $0.range.location + $0.range.length <= length }
}

/// The same for the bold ranges of a notification.
private func clippedRanges(_ ranges: [NSRange], to text: String) -> [NSRange] {
    let length = text.utf16.count
    return ranges.filter { $0.location + $0.length <= length }
}

// MARK: - Text

enum VerifiedKind { case none, blue, business, government }

struct TextEntity {
    enum Kind { case url, mention, hashtag, cashtag }
    let range: NSRange      // UTF-16, straight from "s" and "e"
    let kind: Kind
    let value: String
}

extension TextEntity {
    init?(json: JSON) {
        guard let start = json["s"].int, let end = json["e"].int, start >= 0, end >= start else { return nil }
        let parsedKind: Kind
        switch json["k"].string ?? "" {
        case "url": parsedKind = .url
        case "mention": parsedKind = .mention
        case "hashtag": parsedKind = .hashtag
        case "cashtag": parsedKind = .cashtag
        default: return nil
        }
        range = NSRange(location: start, length: end - start)
        kind = parsedKind
        value = json["v"].string ?? ""
    }
}

// MARK: - Translation

/// A translation of a post's text or of a profile's bio (api-v2.md §4). `entities` refer to `text`.
struct Translation {
    let text: String
    let entities: [TextEntity]
    let sourceLang: String          // e.g. "en"
    let sourceLangName: String      // e.g. "英語"
    let provider: String            // e.g. "Google"
}

extension Translation {
    /// nil without a text; the other keys fall back to empty strings.
    init?(json: JSON) {
        guard let body = jsonText(json["text"]) else { return nil }
        text = body
        entities = clipped(jsonEntities(json["entities"]), to: body)
        sourceLang = json["source_lang"].string ?? ""
        sourceLangName = json["source_lang_name"].string ?? ""
        provider = json["provider"].string ?? ""
    }
}

// MARK: - User

/// A reference type: every row that shows this user holds the same instance (see TweetStore).
final class User {
    let id: String
    var name: String
    var handle: String
    var avatarURL: URL?                 // the 48 px "_normal" image; other sizes via avatarURL(pixels:)
    var verified: VerifiedKind
    var isSquare: Bool
    var isProtected: Bool
    var following: Bool
    var followedBy: Bool
    var blocking: Bool
    var muting: Bool
    var labelText: String?
    var labelBadgeURL: URL?

    // Full profile. isFull is true when the JSON had "followers" (profile screens, /v2/me, /v2/user).
    var isFull: Bool
    var bannerURL: URL?
    var bio: String
    var bioEntities: [TextEntity]
    var location: String
    var linkDisplay: String?
    var linkURL: URL?
    var joined: Date?
    var followers: Int
    var friends: Int
    var tweets: Int
    var mediaCount: Int
    var likesCount: Int
    var pinnedIDs: [String]
    var blockedBy: Bool
    var followRequestSent: Bool
    // From JSON, full users only: the profile text can be translated (api-v2.md §4).
    var bioTranslatable: Bool
    // Runtime state (not from JSON), kept by merge(from:): the translation of the bio and what the header shows.
    var bioTranslation: Translation? = nil
    var showsBioTranslation = false
    var isTranslatingBio = false

    static let didChange = Notification.Name("UserDidChange")

    init?(json: JSON) {
        guard let id = jsonText(json["id"]), let handle = jsonText(json["handle"]) else { return nil }
        self.id = id
        self.handle = handle
        name = jsonText(json["name"]) ?? handle
        avatarURL = jsonURL(json["avatar"])
        verified = User.verifiedKind(json["verified"].string)
        isSquare = json["square"].bool ?? false
        isProtected = json["protected"].bool ?? false
        following = json["following"].bool ?? false
        followedBy = json["followed_by"].bool ?? false
        blocking = json["blocking"].bool ?? false
        muting = json["muting"].bool ?? false
        labelText = jsonText(json["label"]["text"])
        labelBadgeURL = jsonURL(json["label"]["badge"])
        isFull = json["followers"].exists
        bannerURL = jsonURL(json["banner"])
        let biography = json["bio"].string ?? ""
        bio = biography
        bioEntities = clipped(jsonEntities(json["bio_entities"]), to: biography)
        bioTranslatable = json["bio_translatable"].bool ?? false
        location = json["location"].string ?? ""
        linkDisplay = jsonText(json["url"]["display"])
        linkURL = jsonURL(json["url"]["expanded"])
        joined = jsonDate(json["joined"])
        followers = json["followers"].int ?? 0
        friends = json["friends"].int ?? 0
        tweets = json["tweets"].int ?? 0
        mediaCount = json["media_count"].int ?? 0
        likesCount = json["likes_count"].int ?? 0
        pinnedIDs = jsonStrings(json["pinned_ids"])
        blockedBy = json["blocked_by"].bool ?? false
        followRequestSent = json["follow_request_sent"].bool ?? false
    }

    private static func verifiedKind(_ text: String?) -> VerifiedKind {
        switch text ?? "" {
        case "blue": return .blue
        case "business": return .business
        case "government": return .government
        default: return .none
        }
    }

    /// Copies the newer data into this instance. A basic user (no profile fields) must not erase a full profile
    /// that is already known, so the profile fields are copied only from a full copy.
    func merge(from other: User) {
        name = other.name
        handle = other.handle
        avatarURL = other.avatarURL
        verified = other.verified
        isSquare = other.isSquare
        isProtected = other.isProtected
        following = other.following
        followedBy = other.followedBy
        blocking = other.blocking
        muting = other.muting
        labelText = other.labelText
        labelBadgeURL = other.labelBadgeURL
        guard other.isFull else { return }
        isFull = true
        bannerURL = other.bannerURL
        bio = other.bio
        bioEntities = other.bioEntities
        bioTranslatable = other.bioTranslatable
        location = other.location
        linkDisplay = other.linkDisplay
        linkURL = other.linkURL
        joined = other.joined
        followers = other.followers
        friends = other.friends
        tweets = other.tweets
        mediaCount = other.mediaCount
        likesCount = other.likesCount
        pinnedIDs = other.pinnedIDs
        blockedBy = other.blockedBy
        followRequestSent = other.followRequestSent
    }

    /// Sizes: "_normal" (48 px, up to 48), "_bigger" (73 px, up to 73), "_200x200" (up to 200), "_400x400".
    /// URLs without "_normal" (demo images) are returned unchanged.
    func avatarURL(pixels: Int) -> URL? {
        guard let base = avatarURL, base.absoluteString.contains("_normal") else { return avatarURL }
        let variant: String
        if pixels <= 48 {
            return base
        } else if pixels <= 73 {
            variant = "_bigger"
        } else if pixels <= 200 {
            variant = "_200x200"
        } else {
            variant = "_400x400"
        }
        return URL(string: base.absoluteString.replacingOccurrences(of: "_normal", with: variant))
    }

    /// The banner plus the size the app wants: "/600x200" or "/1500x500".
    func bannerURL(wide: Bool) -> URL? {
        guard let base = bannerURL else { return nil }
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        let size = wide ? "/1500x500" : "/600x200"
        return URL(string: text + size)
    }

    func notifyChanged() {
        NotificationCenter.default.post(name: User.didChange, object: self)
    }
}

// MARK: - Media and cards

enum MediaKind { case photo, video, gif }

/// A photo, video or animated GIF of a post.
final class Media {
    let kind: MediaKind
    let url: URL?                       // photo: the image; video/gif: the poster frame
    let width: Int
    let height: Int
    let alt: String?
    let mp4URL: URL?
    let hlsURL: URL?
    let durationMs: Int
    var aspect: CGFloat                 // width / height; 16/9 when unknown

    enum Size: String { case small, medium, large }

    init?(json: JSON) {
        let parsedKind: MediaKind
        switch json["type"].string ?? "" {
        case "photo": parsedKind = .photo
        case "video": parsedKind = .video
        case "gif": parsedKind = .gif
        default: return nil
        }
        let video = json["video"]
        let parsedWidth = json["w"].int ?? 0
        let parsedHeight = json["h"].int ?? 0
        kind = parsedKind
        url = jsonURL(json["url"])
        width = parsedWidth
        height = parsedHeight
        alt = jsonText(json["alt"])
        mp4URL = jsonURL(video["mp4"])
        hlsURL = jsonURL(video["hls"])
        durationMs = video["duration_ms"].int ?? 0
        aspect = Media.initialAspect(kind: parsedKind, width: parsedWidth, height: parsedHeight, videoAspect: video["aspect"])
    }

    private static func initialAspect(kind: MediaKind, width: Int, height: Int, videoAspect: JSON) -> CGFloat {
        if kind == .photo && width > 0 && height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        let videoWidth = videoAspect[0].int ?? 0
        let videoHeight = videoAspect[1].int ?? 0
        if videoWidth > 0 && videoHeight > 0 {
            return CGFloat(videoWidth) / CGFloat(videoHeight)
        }
        if width > 0 && height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        return 16.0 / 9.0
    }

    /// pbs.twimg.com/media/<key>.<ext> becomes …/media/<key>?format=<ext>&name=<size>. Other URLs are unchanged.
    func imageURL(_ size: Size) -> URL? {
        guard let url = url, url.host == "pbs.twimg.com", url.path.hasPrefix("/media/") else { return url }
        let file = url.lastPathComponent
        guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return url }
        let key = String(file[file.startIndex..<dot])
        let format = String(file[file.index(after: dot)...])
        guard !format.isEmpty else { return url }
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = "pbs.twimg.com"
        components.path = "/media/" + key
        components.queryItems = [
            URLQueryItem(name: "format", value: format),
            URLQueryItem(name: "name", value: size.rawValue)
        ]
        return components.url ?? url
    }
}

struct Poll {
    let choices: [(label: String, count: Int)]
    let total: Int
    let endsAt: Date?
    let isFinal: Bool
}

extension Poll {
    init?(json: JSON) {
        let parsedChoices: [(label: String, count: Int)] = json["choices"].array.map {
            (label: $0["label"].string ?? "", count: $0["count"].int ?? 0)
        }
        guard !parsedChoices.isEmpty else { return nil }
        let sum = parsedChoices.reduce(0) { $0 + $1.count }
        choices = parsedChoices
        total = json["total"].int ?? sum
        endsAt = jsonDate(json["ends_at"])
        isFinal = json["final"].bool ?? false
    }
}

struct Card {
    enum Kind { case summary, large, player, poll }
    let kind: Kind
    let url: URL?
    let domain: String
    let title: String
    let description: String
    let imageURL: URL?
    let imageWidth: Int
    let imageHeight: Int
    let poll: Poll?
}

extension Card {
    init?(json: JSON) {
        let parsedKind: Kind
        switch json["type"].string ?? "" {
        case "summary": parsedKind = .summary
        case "summary_large_image": parsedKind = .large
        case "player": parsedKind = .player
        case "poll": parsedKind = .poll
        default: return nil
        }
        let parsedPoll = Poll(json: json["poll"])
        // a poll card without its poll has nothing to show
        if parsedKind == .poll && parsedPoll == nil { return nil }
        let image = json["image"]
        kind = parsedKind
        url = jsonURL(json["url"])
        domain = json["domain"].string ?? ""
        title = json["title"].string ?? ""
        description = json["description"].string ?? ""
        imageURL = jsonURL(image["url"])
        imageWidth = image["w"].int ?? 0
        imageHeight = image["h"].int ?? 0
        poll = parsedPoll
    }
}

// MARK: - Post

/// A post. A reference type: the same post is shown by the timeline and the detail screen, and both observe
/// `didChange` (see TweetStore).
final class Tweet {
    let id: String
    var user: User
    var text: String
    var entities: [TextEntity]
    var isLong: Bool
    var createdAt: Date
    var replyCount: Int
    var retweetCount: Int
    var likeCount: Int
    var quoteCount: Int
    var bookmarkCount: Int
    var viewCount: Int?
    var liked: Bool
    var retweeted: Bool
    var bookmarked: Bool
    var media: [Media]
    var quote: Tweet?
    var quoteUnavailable: String?
    var card: Card?
    var replyToID: String?
    var replyToHandles: [String]
    var conversationID: String
    var retweetedBy: User?              // set when the timeline entry is a repost; then the rest describes the original
    var retweetID: String?
    var lang: String
    var sensitive: Bool
    var source: String?
    var edited: Bool
    var place: String?
    var replyLimited: Bool
    // From JSON: the post can be translated ("ポストを翻訳", api-v2.md §4).
    var translatable: Bool
    // Runtime state (not from JSON), kept by merge(from:): the translation and what the row shows.
    var translation: Translation? = nil
    var showsTranslation = false
    var isTranslating = false

    static let didChange = Notification.Name("TweetDidChange")
    /// Posted by notifyLayoutChanged(): the layout of the post changed (its translation was shown or hidden).
    static let layoutDidChange = Notification.Name("TweetLayoutDidChange")

    convenience init?(json: JSON) {
        self.init(json: json, nested: false)
    }

    /// A quoted post has no quote of its own (the contract allows one level only), so `nested` posts do not read one.
    private init?(json: JSON, nested: Bool) {
        guard let id = jsonText(json["id"]), let user = User(json: json["user"]) else { return nil }
        self.id = id
        self.user = user
        let body = json["text"].string ?? ""
        text = body
        entities = clipped(jsonEntities(json["entities"]), to: body)
        translatable = json["translatable"].bool ?? false
        isLong = json["long"].bool ?? false
        createdAt = jsonDate(json["created_at"]) ?? Date(timeIntervalSince1970: 0)
        replyCount = json["reply_count"].int ?? 0
        retweetCount = json["retweet_count"].int ?? 0
        likeCount = json["like_count"].int ?? 0
        quoteCount = json["quote_count"].int ?? 0
        bookmarkCount = json["bookmark_count"].int ?? 0
        viewCount = json["view_count"].int
        liked = json["liked"].bool ?? false
        retweeted = json["retweeted"].bool ?? false
        bookmarked = json["bookmarked"].bool ?? false
        media = json["media"].array.compactMap { Media(json: $0) }
        quote = nested ? nil : Tweet(json: json["quote"], nested: true)
        quoteUnavailable = jsonText(json["quote_unavailable"])
        card = Card(json: json["card"])
        replyToID = jsonText(json["reply_to"]["id"])
        replyToHandles = jsonStrings(json["reply_to"]["handles"])
        conversationID = jsonText(json["conversation_id"]) ?? id
        retweetedBy = User(json: json["retweeted_by"])
        retweetID = jsonText(json["retweet_id"])
        lang = json["lang"].string ?? ""
        sensitive = json["sensitive"].bool ?? false
        source = jsonText(json["source"])
        edited = json["edited"].bool ?? false
        place = jsonText(json["place"])
        replyLimited = json["reply_limited"].bool ?? false
    }

    func merge(from other: Tweet) {
        user = other.user
        text = other.text
        entities = other.entities
        isLong = other.isLong
        createdAt = other.createdAt
        replyCount = other.replyCount
        retweetCount = other.retweetCount
        likeCount = other.likeCount
        quoteCount = other.quoteCount
        bookmarkCount = other.bookmarkCount
        viewCount = other.viewCount
        liked = other.liked
        retweeted = other.retweeted
        bookmarked = other.bookmarked
        media = other.media
        quote = other.quote
        quoteUnavailable = other.quoteUnavailable
        card = other.card
        replyToID = other.replyToID
        replyToHandles = other.replyToHandles
        conversationID = other.conversationID
        retweetedBy = other.retweetedBy
        retweetID = other.retweetID
        lang = other.lang
        sensitive = other.sensitive
        source = other.source
        edited = other.edited
        place = other.place
        replyLimited = other.replyLimited
        translatable = other.translatable
        // the runtime state (translation, showsTranslation, isTranslating) is not copied: it belongs to this instance
    }

    var permalink: URL? {
        return URL(string: "https://x.com/\(user.handle)/status/\(id)")
    }

    func notifyChanged() {
        NotificationCenter.default.post(name: Tweet.didChange, object: self)
    }

    /// The layout of this post changed: the timeline re-lays out its row.
    func notifyLayoutChanged() {
        NotificationCenter.default.post(name: Tweet.layoutDidChange, object: self)
    }
}

// MARK: - Timeline

struct TweetEntry {
    let tweet: Tweet
    let contextKind: String?            // "pin" or "text"
    let contextText: String?
    var above: Bool
    var below: Bool
    var focal: Bool
}

struct NotificationEntry {
    let id: String
    let icon: String
    let text: String
    let bold: [NSRange]
    let users: [User]
    let tweet: Tweet?
    let time: Date?
    let url: URL?
}

extension NotificationEntry {
    init?(json: JSON) {
        guard let id = jsonText(json["id"]) else { return nil }
        self.id = id
        icon = jsonText(json["icon"]) ?? "bell"
        let body = json["text"].string ?? ""
        text = body
        bold = clippedRanges(jsonRanges(json["bold"]), to: body)
        users = Array(json["users"].array.compactMap { User(json: $0) }.prefix(8))
        tweet = Tweet(json: json["tweet"])
        time = jsonDate(json["time"])
        url = jsonURL(json["url"])
    }
}

struct Trend {
    let name: String
    let context: String?
    let meta: String?
    let query: String                   // what a tap searches for
    let rank: Int?
}

extension Trend {
    init?(json: JSON) {
        guard let name = jsonText(json["name"]) else { return nil }
        self.name = name
        context = jsonText(json["context"])
        meta = jsonText(json["meta"])
        query = jsonText(json["query"]) ?? name
        rank = json["rank"].int
    }
}

enum TimelineItem {
    case tweet(TweetEntry)
    case more(cursor: String, label: String)
    case header(String)
    case tombstone(text: String, above: Bool, below: Bool)
    case user(User)
    case notification(NotificationEntry)
    case trend(Trend)
}

extension TimelineItem {
    /// nil for an unknown "t" or an unusable payload. Does not intern (TimelinePage does).
    init?(json: JSON) {
        switch json["t"].string ?? "" {
        case "tweet":
            guard let tweet = Tweet(json: json["tweet"]) else { return nil }
            let entry = TweetEntry(
                tweet: tweet,
                contextKind: json["context"]["k"].string,
                contextText: json["context"]["text"].string,
                above: json["above"].bool ?? false,
                below: json["below"].bool ?? false,
                focal: json["focal"].bool ?? false
            )
            self = .tweet(entry)
        case "more":
            guard let cursor = jsonText(json["cursor"]) else { return nil }
            self = .more(cursor: cursor, label: jsonText(json["label"]) ?? "さらに表示")
        case "header":
            guard let text = jsonText(json["text"]) else { return nil }
            self = .header(text)
        case "tombstone":
            let text = jsonText(json["text"]) ?? "このポストは削除されました。"
            self = .tombstone(text: text, above: json["above"].bool ?? false, below: json["below"].bool ?? false)
        case "user":
            guard let user = User(json: json["user"]) else { return nil }
            self = .user(user)
        case "notification":
            guard let entry = NotificationEntry(json: json) else { return nil }
            self = .notification(entry)
        case "trend":
            guard let trend = Trend(json: json) else { return nil }
            self = .trend(trend)
        default:
            return nil
        }
    }
}

/// One page of any list endpoint. `bottom` is the cursor of the next (older) page; nil means the end.
struct TimelinePage {
    var items: [TimelineItem]
    var top: String?
    var bottom: String?

    /// Every post (quotes included) and user the page creates is interned in TweetStore.shared.
    init(json: JSON) {
        items = json["items"].array.compactMap { TimelineItem(json: $0) }.map { TimelinePage.interned($0) }
        top = jsonText(json["top"])
        bottom = jsonText(json["bottom"])
    }

    private static func interned(_ item: TimelineItem) -> TimelineItem {
        let store = TweetStore.shared
        switch item {
        case .tweet(let entry):
            return .tweet(TweetEntry(
                tweet: store.intern(entry.tweet),
                contextKind: entry.contextKind, contextText: entry.contextText,
                above: entry.above, below: entry.below, focal: entry.focal
            ))
        case .user(let user):
            return .user(store.intern(user))
        case .notification(let entry):
            let users = entry.users.map { store.intern($0) }
            let tweet = entry.tweet.map { store.intern($0) }
            return .notification(NotificationEntry(
                id: entry.id, icon: entry.icon, text: entry.text, bold: entry.bold,
                users: users, tweet: tweet, time: entry.time, url: entry.url
            ))
        default:
            return item
        }
    }
}

struct ExploreTab {
    let id: String
    let label: String
}

struct ExplorePage {
    let tabs: [ExploreTab]
    let tab: String?                    // the tab that was answered
    let page: TimelinePage

    init(json: JSON) {
        tabs = json["tabs"].array.compactMap { row -> ExploreTab? in
            guard let id = jsonText(row["id"]) else { return nil }
            return ExploreTab(id: id, label: row["label"].string ?? id)
        }
        tab = jsonText(json["tab"])
        page = TimelinePage(json: json)
    }
}

struct Badges {
    var notifications: Int
    var messages: Int
}

extension Badges {
    init(json: JSON) {
        notifications = json["notifications"].int ?? 0
        messages = json["messages"].int ?? 0
    }
}

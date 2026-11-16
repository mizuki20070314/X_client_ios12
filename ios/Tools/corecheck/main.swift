import Foundation

// corecheck: runs the Foundation-only part of Core on Linux. The built-in checks cover Format, TwitterText, the URL
// rules of Media and User, TweetStore interning and tolerant parsing. Each JSON file given as an argument is parsed
// as the shape its top-level keys name: "tabs" -> ExplorePage, "items" -> TimelinePage, "user" -> User (and Badges
// when "badges" is there), "notifications" -> Badges. Exit status 1 when a check fails.

var checkCount = 0
var failureCount = 0

func expect(_ condition: Bool, _ message: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(message)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    checkCount += 1
    if actual != expected {
        failureCount += 1
        print("FAIL: \(message): expected \(expected), got \(actual)")
    }
}

func parse(_ text: String) -> JSON {
    return JSON(data: Data(text.utf8))
}

// 2026-11-16 19:05 in Japan Standard Time (+09:00); the epoch values were computed with Python's datetime.
let nowEpoch = 1_794_823_500
let now = Date(timeIntervalSince1970: TimeInterval(nowEpoch))

func secondsAgo(_ seconds: Int) -> Date {
    return Date(timeIntervalSince1970: TimeInterval(nowEpoch - seconds))
}

// MARK: - Format

func checkFormat() {
    Format.timeZone = TimeZone(secondsFromGMT: 9 * 3_600) ?? .current

    expectEqual(Format.relativeTime(secondsAgo(0), now: now), "1秒", "relative time 0 s")
    expectEqual(Format.relativeTime(secondsAgo(5), now: now), "5秒", "relative time 5 s")
    expectEqual(Format.relativeTime(secondsAgo(59), now: now), "59秒", "relative time 59 s")
    expectEqual(Format.relativeTime(secondsAgo(60), now: now), "1分", "relative time 60 s")
    expectEqual(Format.relativeTime(secondsAgo(720), now: now), "12分", "relative time 12 min")
    expectEqual(Format.relativeTime(secondsAgo(3_599), now: now), "59分", "relative time 59 min")
    expectEqual(Format.relativeTime(secondsAgo(3_600), now: now), "1時間", "relative time 1 h")
    expectEqual(Format.relativeTime(secondsAgo(3 * 3_600), now: now), "3時間", "relative time 3 h")
    expectEqual(Format.relativeTime(secondsAgo(86_399), now: now), "23時間", "relative time 23 h 59 min")
    expectEqual(Format.relativeTime(secondsAgo(86_400), now: now), "11月15日", "relative time 1 day, same year")
    expectEqual(Format.relativeTime(Date(timeIntervalSince1970: 1_793_847_600), now: now), "11月5日", "same year date")
    expectEqual(Format.relativeTime(Date(timeIntervalSince1970: 1_762_311_600), now: now), "2025年11月5日", "previous year")
    expectEqual(Format.relativeTime(Date(timeIntervalSince1970: 1_767_409_200), now: now), "1月3日", "earlier this year")
    expectEqual(Format.relativeTime(Date(timeIntervalSince1970: TimeInterval(nowEpoch + 10)), now: now), "1秒", "future date")

    let countCases: [(Int, String)] = [
        (0, "0"), (999, "999"), (1234, "1,234"), (9999, "9,999"), (10000, "1万"), (12345, "1.2万"),
        (123456, "12.3万"), (1234567, "123万"), (12345678, "1,234万"), (100000000, "1億"), (123456789, "1.2億")
    ]
    for (value, expected) in countCases {
        expectEqual(Format.count(value), expected, "count(\(value))")
    }

    expectEqual(Format.duration(ms: 0), "0:00", "duration 0")
    expectEqual(Format.duration(ms: 19_000), "0:19", "duration 19 s")
    expectEqual(Format.duration(ms: 725_000), "12:05", "duration 12:05")
    expectEqual(Format.duration(ms: 3_723_000), "1:02:03", "duration 1:02:03")

    expectEqual(Format.fullTimestamp(now), "午後7:05 · 2026年11月16日", "full timestamp 19:05")
    expectEqual(Format.fullTimestamp(Date(timeIntervalSince1970: 1_794_756_600)), "午前12:30 · 2026年11月16日", "full timestamp 00:30")
    expectEqual(Format.joined(Date(timeIntervalSince1970: 1_652_972_400)), "2022年5月からXを利用しています", "joined")
}

// MARK: - TwitterText

func checkTwitterText() {
    expectEqual(TwitterText.limit, 280, "post limit")
    let lengthCases: [(String, Int)] = [
        ("abc", 3), ("あいう", 6), ("a https://example.com/very/long/path b", 27),
        ("😀", 2), ("", 0), ("https://t.co/abc", 23)
    ]
    for (text, expected) in lengthCases {
        expectEqual(TwitterText.weightedLength(text), expected, "weighted length of \(text)")
    }
}

// MARK: - Media, cards and avatars

func checkMediaAndAvatars() {
    if let media = Media(json: parse("{\"type\":\"photo\",\"url\":\"https://pbs.twimg.com/media/HXOkK4tbUAAQFF7.jpg\",\"w\":1164,\"h\":2048}")) {
        expectEqual(media.imageURL(.medium)?.absoluteString ?? "", "https://pbs.twimg.com/media/HXOkK4tbUAAQFF7?format=jpg&name=medium", "pbs image size")
        expect(abs(media.aspect - 1164.0 / 2048.0) < 0.0001, "photo aspect is width / height")
    } else {
        expect(false, "photo parses")
    }
    if let demo = Media(json: parse("{\"type\":\"photo\",\"url\":\"demo://photo/3?w=1200&h=800\"}")) {
        expectEqual(demo.imageURL(.small)?.absoluteString ?? "", "demo://photo/3?w=1200&h=800", "demo image unchanged")
    } else {
        expect(false, "demo photo parses")
    }
    if let video = Media(json: parse("{\"type\":\"video\",\"url\":null,\"w\":0,\"h\":0,\"video\":{\"mp4\":null,\"hls\":null,\"duration_ms\":35134,\"aspect\":[16,9]}}")) {
        expect(abs(video.aspect - 16.0 / 9.0) < 0.0001, "video aspect from video.aspect")
        expectEqual(video.durationMs, 35_134, "video duration")
    } else {
        expect(false, "video parses")
    }
    expect(Media(json: parse("{\"type\":\"hologram\"}")) == nil, "unknown media type is dropped")

    let avatar = "https://pbs.twimg.com/profile_images/123/abc_normal.jpg"
    if let user = User(json: parse("{\"id\":\"1\",\"handle\":\"yamada_demo\",\"avatar\":\"\(avatar)\"}")) {
        expectEqual(user.avatarURL(pixels: 48)?.absoluteString ?? "", avatar, "48 px avatar")
        expectEqual(user.avatarURL(pixels: 73)?.absoluteString ?? "", "https://pbs.twimg.com/profile_images/123/abc_bigger.jpg", "73 px avatar")
        expectEqual(user.avatarURL(pixels: 200)?.absoluteString ?? "", "https://pbs.twimg.com/profile_images/123/abc_200x200.jpg", "200 px avatar")
        expectEqual(user.avatarURL(pixels: 201)?.absoluteString ?? "", "https://pbs.twimg.com/profile_images/123/abc_400x400.jpg", "201 px avatar")
    } else {
        expect(false, "user parses")
    }
    if let user = User(json: parse("{\"id\":\"1\",\"handle\":\"yamada_demo\",\"banner\":\"https://pbs.twimg.com/profile_banners/123/1700000000\"}")) {
        expectEqual(user.bannerURL(wide: false)?.absoluteString ?? "", "https://pbs.twimg.com/profile_banners/123/1700000000/600x200", "banner 600x200")
        expectEqual(user.bannerURL(wide: true)?.absoluteString ?? "", "https://pbs.twimg.com/profile_banners/123/1700000000/1500x500", "banner 1500x500")
    } else {
        expect(false, "user with banner parses")
    }

    let poll = Card(json: parse("{\"type\":\"poll\",\"url\":\"\",\"domain\":\"\",\"title\":\"\",\"description\":\"\",\"image\":null,\"poll\":{\"choices\":[{\"label\":\"Yes\",\"count\":10},{\"label\":\"No\",\"count\":5}],\"total\":15,\"ends_at\":1794800000,\"final\":false}}"))
    expect(poll?.kind == .poll, "poll card")
    expectEqual(poll?.poll?.choices.count ?? 0, 2, "poll choices")
    expectEqual(poll?.poll?.total ?? 0, 15, "poll total")
    expect(Card(json: parse("{\"type\":\"poll\",\"poll\":null}")) == nil, "poll card without poll is dropped")
}

// MARK: - TweetStore and tolerant parsing

func tweetJSON(id: String, likes: Int, text: String) -> JSON {
    return parse("{\"id\":\"\(id)\",\"user\":{\"id\":\"1001\",\"name\":\"山田 太郎\",\"handle\":\"yamada_demo\"},\"text\":\"\(text)\",\"created_at\":1794823000,\"like_count\":\(likes)}")
}

func checkStoreAndParsing() {
    let store = TweetStore.shared

    // the same post id is one instance, and the newer data is merged into it
    let first = Tweet(json: tweetJSON(id: "9001", likes: 1, text: "最初"))
    expect(first != nil, "tweet parses")
    let heldFirst = store.intern(first!)
    let second = Tweet(json: tweetJSON(id: "9001", likes: 5, text: "更新"))
    let heldSecond = store.intern(second!)
    expect(heldSecond === heldFirst, "same post id gives the same instance")
    expectEqual(heldFirst.likeCount, 5, "merged like count")
    expectEqual(heldFirst.text, "更新", "merged text")

    // a basic user does not erase the full profile that is already known
    let full = User(json: parse("{\"id\":\"1001\",\"handle\":\"yamada_demo\",\"name\":\"山田 太郎\",\"bio\":\"自己紹介\",\"followers\":12}"))
    let basic = User(json: parse("{\"id\":\"1001\",\"handle\":\"yamada_demo\",\"name\":\"山田 太郎\"}"))
    let heldFull = store.intern(full!)
    let heldBasic = store.intern(basic!)
    expect(heldBasic === heldFull, "same user id gives the same instance")
    expect(heldBasic.isFull, "basic copy keeps the full profile")
    expectEqual(heldBasic.bio, "自己紹介", "profile bio kept after a basic copy")

    // tolerant parsing: unusable items are skipped, an empty cursor is nil, nothing crashes
    let messy = parse("{\"items\":[{\"t\":\"tweet\",\"tweet\":null},{\"t\":\"unknown\"},{\"t\":\"more\",\"cursor\":\"c1\",\"label\":\"もっと\"},42,null,{\"t\":\"tombstone\"}],\"bottom\":\"\"}")
    let messyPage = TimelinePage(json: messy)
    expectEqual(messyPage.items.count, 2, "unusable items are skipped")
    expect(messyPage.bottom == nil, "empty cursor is nil")
    expect(Tweet(json: JSON(nil)) == nil, "tweet from nothing is nil")
    expect(JSON(data: Data("not json".utf8)).raw == nil, "non-JSON data gives nil raw")
    expect(JSON(data: Data("{\"a\":1}".utf8))["a"].int == 1, "JSON(data:) reads an object")
    expect(JSON(nil)["a"]["b"][0].exists == false, "missing paths do not exist")
    expectEqual(parse("{\"n\":\"12\"}")["n"].int ?? -1, 12, "numeric string counts as int")
}

// MARK: - Demo and captured files

func checkTweetEntities(_ tweet: Tweet, name: String) {
    let text = NSString(string: tweet.text)
    var previousEnd = 0
    for entity in tweet.entities {
        let start = entity.range.location
        let end = start + entity.range.length
        expect(start >= previousEnd && end <= text.length, "\(name) \(tweet.id): entity \(start)..<\(end) lies inside the text (\(text.length) UTF-16 units) and does not overlap")
        previousEnd = max(previousEnd, end)
        guard end <= text.length else { continue }
        let visible = text.substring(with: entity.range)
        switch entity.kind {
        case .mention:
            expect(visible == "@" + entity.value, "\(name) \(tweet.id): mention shows @\(entity.value), got \(visible)")
        case .hashtag:
            expect(visible == "#" + entity.value, "\(name) \(tweet.id): hashtag shows #\(entity.value), got \(visible)")
        case .cashtag:
            expect(visible == "$" + entity.value, "\(name) \(tweet.id): cashtag shows $\(entity.value), got \(visible)")
        case .url:
            break
        }
    }
    expect(tweet.quote?.quote == nil, "\(name) \(tweet.id): a quoted post has no quote of its own")
    if let quote = tweet.quote {
        checkTweetEntities(quote, name: name)
    }
}

/// Parsing the same answer again must give the same instances (the first page holds them).
func checkSameInstances(_ first: TimelinePage, _ second: TimelinePage, name: String) {
    expectEqual(first.items.count, second.items.count, "\(name): second parse has the same item count")
    for (a, b) in zip(first.items, second.items) {
        if case .tweet(let x) = a, case .tweet(let y) = b {
            expect(x.tweet === y.tweet, "\(name): post \(x.tweet.id) is one instance across parses")
            expect(x.tweet.user === y.tweet.user, "\(name): author of \(x.tweet.id) is one instance across parses")
        }
    }
}

func summarizeTimeline(_ root: JSON, name: String) {
    let page = TimelinePage(json: root)
    checkSameInstances(page, TimelinePage(json: root), name: name)
    var counts: [String: Int] = [:]
    var posts: [Tweet] = []
    for item in page.items {
        switch item {
        case .tweet(let entry):
            counts["tweet", default: 0] += 1
            posts.append(entry.tweet)
            checkTweetEntities(entry.tweet, name: name)
        case .more:
            counts["more", default: 0] += 1
        case .header:
            counts["header", default: 0] += 1
        case .tombstone:
            counts["tombstone", default: 0] += 1
        case .user:
            counts["user", default: 0] += 1
        case .notification(let entry):
            counts["notification", default: 0] += 1
            if let tweet = entry.tweet {
                checkTweetEntities(tweet, name: name)
            }
        case .trend:
            counts["trend", default: 0] += 1
        }
    }
    let kinds = counts.keys.sorted().map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: ", ")
    print("\(name): \(page.items.count) items (\(kinds)), top \(page.top ?? "null"), bottom \(page.bottom ?? "null")")
    for tweet in posts.prefix(5) {
        let head = String(tweet.text.prefix(40)).replacingOccurrences(of: "\n", with: " ")
        let quoted = tweet.quote == nil ? "n" : "y"
        print("  \(tweet.user.name) @\(tweet.user.handle): \(head) | media \(tweet.media.count) | quote \(quoted)")
    }
}

func summarize(path: String) {
    let name = (path as NSString).lastPathComponent
    guard let data = FileManager.default.contents(atPath: path) else {
        expect(false, "\(name) can be read")
        return
    }
    let root = JSON(data: data)
    guard let keys = root.dictionary?.keys else {
        expect(false, "\(name) is a JSON object")
        return
    }
    if keys.contains("tabs") {
        let explore = ExplorePage(json: root)
        let labels = explore.tabs.map { $0.id }.joined(separator: ", ")
        print("\(name): explore, tabs [\(labels)], selected \(explore.tab ?? "null"), \(explore.page.items.count) items")
        checkSameInstances(explore.page, TimelinePage(json: root), name: name)
    } else if keys.contains("items") {
        summarizeTimeline(root, name: name)
    } else if keys.contains("user") {
        guard let user = User(json: root["user"]) else {
            expect(false, "\(name): user parses")
            return
        }
        print("\(name): user \(user.name) @\(user.handle), full \(user.isFull), followers \(user.followers)")
        if keys.contains("badges") {
            let badges = Badges(json: root["badges"])
            print("  badges: notifications \(badges.notifications), messages \(badges.messages)")
        }
    } else if keys.contains("notifications") {
        let badges = Badges(json: root)
        print("\(name): badges, notifications \(badges.notifications), messages \(badges.messages)")
    } else {
        expect(false, "\(name) has a known shape")
    }
}

// MARK: - Main

checkFormat()
checkTwitterText()
checkMediaAndAvatars()
checkStoreAndParsing()

let files = Array(CommandLine.arguments.dropFirst())
if files.isEmpty {
    print("no JSON files given: only the built-in checks ran")
}
for path in files {
    summarize(path: path)
}

print("corecheck: \(checkCount) checks, \(failureCount) failed")
exit(failureCount == 0 ? 0 : 1)

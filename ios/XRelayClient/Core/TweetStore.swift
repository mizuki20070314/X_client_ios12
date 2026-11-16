import Foundation

/// One instance per post id and per user id, so that a change made on one screen shows on every other screen that
/// holds the same post. The references are weak: an instance lives as long as some screen holds it.
/// Main thread only (the networking layer delivers its results there).
final class TweetStore {
    static let shared = TweetStore()

    private final class WeakBox<Object: AnyObject> {
        weak var value: Object?

        init(_ value: Object) {
            self.value = value
        }
    }

    private var tweets: [String: WeakBox<Tweet>] = [:]
    private var users: [String: WeakBox<User>] = [:]
    private var tweetPruneLimit = 4_000
    private var userPruneLimit = 4_000

    private init() {}

    /// The known instance for this id, or nil when none is alive.
    func tweet(id: String) -> Tweet? {
        return tweets[id]?.value
    }

    func user(id: String) -> User? {
        return users[id]?.value
    }

    /// Returns the instance already known for the post's id, after merging `tweet` into it. Otherwise registers
    /// `tweet` itself. Its author, reposter and quoted post are interned as well.
    func intern(_ tweet: Tweet) -> Tweet {
        tweet.user = intern(tweet.user)
        if let reposter = tweet.retweetedBy {
            tweet.retweetedBy = intern(reposter)
        }
        if let quoted = tweet.quote {
            tweet.quote = intern(quoted)
        }
        guard let known = tweets[tweet.id]?.value else {
            tweets[tweet.id] = WeakBox(tweet)
            pruneTweets()
            return tweet
        }
        if known !== tweet {
            known.merge(from: tweet)
            known.notifyChanged()
        }
        return known
    }

    func intern(_ user: User) -> User {
        guard let known = users[user.id]?.value else {
            users[user.id] = WeakBox(user)
            pruneUsers()
            return user
        }
        if known !== user {
            known.merge(from: user)
            known.notifyChanged()
        }
        return known
    }

    // Dead entries are removed only when the table has doubled since the last pass, so that the cost stays linear.

    private func pruneTweets() {
        guard tweets.count > tweetPruneLimit else { return }
        tweets = tweets.filter { $0.value.value != nil }
        tweetPruneLimit = max(4_000, tweets.count * 2)
    }

    private func pruneUsers() {
        guard users.count > userPruneLimit else { return }
        users = users.filter { $0.value.value != nil }
        userPruneLimit = max(4_000, users.count * 2)
    }
}

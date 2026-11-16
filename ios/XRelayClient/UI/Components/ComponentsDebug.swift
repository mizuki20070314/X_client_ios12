import UIKit

/// The debug steps of the Components part (ui-spec §6, ui-wave2-notes.md). Each takes a post id and finds the post in
/// the store, so it works for posts that a screen has loaded.
enum ComponentsDebug {
    static func registerDebugSteps() {
        DebugRoutes.register("overflow") { argument in
            guard let tweet = TweetStore.shared.tweet(id: argument) else { return }
            TweetActions.showOverflowMenu(for: tweet)
        }
        DebugRoutes.register("repostmenu") { argument in
            guard let tweet = TweetStore.shared.tweet(id: argument) else { return }
            TweetActions.showRepostMenu(for: tweet)
        }
        DebugRoutes.register("sharemenu") { argument in
            guard let tweet = TweetStore.shared.tweet(id: argument) else { return }
            TweetActions.showShareMenu(for: tweet)
        }
        DebugRoutes.register("like") { argument in
            guard let tweet = TweetStore.shared.tweet(id: argument) else { return }
            TweetActions.toggleLike(tweet)
        }
        DebugRoutes.register("bookmark") { argument in
            guard let tweet = TweetStore.shared.tweet(id: argument) else { return }
            TweetActions.toggleBookmark(tweet)
        }
    }
}

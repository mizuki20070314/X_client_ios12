import UIKit

/// The debug steps of the Screens part (docs/ui-spec.md, section 6), registered once at launch for the CI screenshots.
/// Each step takes the text after its colon as the argument; a missing or unusable argument does nothing.
enum ScreensDebug {
    static func registerDebugSteps() {
        DebugRoutes.register("hometab") { argument in
            guard let index = Int(argument) else { return }
            (visibleScreen() as? HomeViewController)?.selectHomeTab(index)
        }
        DebugRoutes.register("tweet") { argument in
            guard !argument.isEmpty else { return }
            if let tweet = TweetStore.shared.tweet(id: argument) {
                Router.openTweet(tweet)
            } else {
                Router.openTweet(id: argument)
            }
        }
        DebugRoutes.register("profile") { argument in
            guard !argument.isEmpty else { return }
            Router.openProfile(handle: argument)
        }
        DebugRoutes.register("search") { argument in
            guard !argument.isEmpty else { return }
            Router.openSearch(query: argument)
        }
        DebugRoutes.register("compose") { _ in
            Router.openCompose()
        }
        DebugRoutes.register("reply") { argument in
            guard let tweet = TweetStore.shared.tweet(id: argument) else { return }
            Router.openCompose(replyTo: tweet)
        }
        DebugRoutes.register("quote") { argument in
            guard let tweet = TweetStore.shared.tweet(id: argument) else { return }
            Router.openCompose(quote: tweet)
        }
        DebugRoutes.register("type") { argument in
            (visibleScreen() as? ComposeViewController)?.setDraft(argument)
        }
        DebugRoutes.register("viewer") { argument in
            // "<post id>:<index>", the index being the position of the media in the post
            let parts = argument.split(separator: ":", maxSplits: 1).map { String($0) }
            guard parts.count == 2, let index = Int(parts[1]),
                  let tweet = TweetStore.shared.tweet(id: parts[0]) else { return }
            Router.openMedia(tweet: tweet, index: index)
        }
    }

    /// The screen the user sees: the presented one, or the top of the navigation under it.
    private static func visibleScreen() -> UIViewController? {
        guard var top = Router.topViewController else { return nil }
        if let navigation = top as? UINavigationController, let inner = navigation.topViewController {
            top = inner
        }
        return top
    }
}

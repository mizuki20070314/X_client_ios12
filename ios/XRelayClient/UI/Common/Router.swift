import UIKit
import SafariServices

/// Navigation for every screen and cell. Pushes go onto the selected tab's stack and presentations come from the
/// top-most controller. An open drawer closes first, and the navigation runs when it is closed.
enum Router {
    // MARK: - push

    static func openTweet(_ tweet: Tweet) {
        push(TweetDetailViewController(tweet: tweet))
    }

    static func openTweet(id: String) {
        push(TweetDetailViewController(tweetID: id))
    }

    static func openProfile(user: User) {
        push(ProfileViewController(user: user))
    }

    static func openProfile(handle: String) {
        push(ProfileViewController(handle: handle))
    }

    static func openSearch(query: String) {
        push(SearchResultsViewController(query: query))
    }

    static func openUserList(userID: String, followers: Bool) {
        push(UserListViewController(userID: userID, followers: followers))
    }

    static func openSettings() {
        push(SettingsViewController())
    }

    static func openHistory() {
        push(HistoryViewController())
    }

    static func push(_ controller: UIViewController) {
        afterClosingDrawer {
            guard let navigation = MainViewController.current?.currentNavigation else { return }
            navigation.pushViewController(controller, animated: true)
        }
    }

    // MARK: - present

    /// Photos open the viewer; the viewer plays videos and GIFs itself.
    static func openMedia(tweet: Tweet, index: Int) {
        present(MediaViewerController(tweet: tweet, index: index), style: .overFullScreen)
    }

    static func openCompose(replyTo: Tweet? = nil, quote: Tweet? = nil) {
        let compose = ComposeViewController(replyTo: replyTo, quote: quote)
        present(XNavigationController(rootViewController: compose))
    }

    /// Full screen, from the top-most controller.
    static func present(_ controller: UIViewController) {
        present(controller, style: .fullScreen)
    }

    private static func present(_ controller: UIViewController, style: UIModalPresentationStyle) {
        controller.modalPresentationStyle = style
        afterClosingDrawer {
            guard let top = topViewController else { return }
            top.present(controller, animated: true, completion: nil)
        }
    }

    /// The controller that presents: the top-most presented one, else the selected tab's top screen.
    static var topViewController: UIViewController? {
        guard let root = RootContainerViewController.current else { return nil }
        let presented = deepestPresented(from: root)
        if presented !== root {
            return presented
        }
        let fallback: UIViewController = root
        return MainViewController.current?.currentNavigation.topViewController ?? fallback
    }

    // MARK: - links

    static func open(entity: TextEntity) {
        switch entity.kind {
        case .url:
            if let url = URL(string: entity.value) {
                openURL(url)
            }
        case .mention:
            openProfile(handle: entity.value)
        case .hashtag:
            openSearch(query: "#" + entity.value)
        case .cashtag:
            openSearch(query: "$" + entity.value)
        }
    }

    /// X links open the post or the profile in the app; other web links open in Safari; the rest go to the system.
    static func openURL(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }
        if isXHost(url) {
            let parts = pathParts(of: url)
            if parts.count >= 3, parts[1] == "status", isNumeric(parts[2]) {
                openTweet(id: parts[2])
                return
            }
            if parts.count == 1, isProfileHandle(parts[0]) {
                openProfile(handle: parts[0])
                return
            }
        }
        openInSafari(url)
    }

    private static func openInSafari(_ url: URL) {
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = Theme.palette.accent
        present(safari)
    }

    // MARK: - helpers

    /// Runs `action` once the drawer is closed; at once when it is closed already.
    private static func afterClosingDrawer(_ action: @escaping () -> Void) {
        guard let root = RootContainerViewController.current, root.isDrawerOpen else {
            action()
            return
        }
        root.closeDrawer(completion: action)
    }

    private static func deepestPresented(from controller: UIViewController) -> UIViewController {
        var top = controller
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    private static func isXHost(_ url: URL) -> Bool {
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return host == "x.com" || host == "twitter.com"
    }

    private static func pathParts(of url: URL) -> [String] {
        return url.path.split(separator: "/").map { String($0) }
    }

    private static func isNumeric(_ text: String) -> Bool {
        return !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Paths of X that are not accounts (`x.com/home`, `x.com/i/…`).
    private static let reservedPaths: Set<String> = [
        "home", "search", "i", "explore", "settings", "notifications", "messages",
        "compose", "login", "logout", "signup", "share", "intent",
    ]

    private static func isProfileHandle(_ text: String) -> Bool {
        if reservedPaths.contains(text.lowercased()) {
            return false
        }
        return !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}

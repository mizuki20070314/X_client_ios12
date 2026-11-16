# Notes for the screen implementation (wave 2)

Additions to `ui-spec.md` that every screen developer needs. The four parts are written at the same time by different
people, so each part codes against the signatures in `ui-spec.md` and this file, not against the other parts' code.

## Ownership

| part | folder / files |
|---|---|
| Shell | `UI/Common/Metrics.swift`, `UI/Common/Router.swift`, `UI/Shell/*` (RootContainerViewController, MainViewController, BottomBarView, XNavigationController, BaseViewController, TopBarView, DrawerViewController, MessagesViewController, SettingsViewController, HistoryViewController, ThemeSheet), `App/AppRoot.swift`, `UI/Foundation/DemoImages.swift` (two fixes), `README.md`, `ios/README.md` |
| Components | `UI/Components/*` (TabStripView, PagerViewController, BottomSheet, TextLayout + LinkLabel + TweetText, NameLineView, MediaGridView, QuoteView, CardView, ActionBarView, FocalActionBarView, FollowButton, StateViews), `UI/Common/TweetActions.swift` |
| Timeline | `UI/Timeline/*` (TimelineViewController, Rows, TweetCell, FocalTweetCell, MoreCell, HeaderCell, TombstoneCell, UserCell, NotificationCell, TrendCell) |
| Screens | `UI/Screens/*` (HomeViewController, ComposeViewController, TweetDetailViewController, ProfileViewController, UserListViewController, SearchFieldView, SearchViewController, SearchResultsViewController, NotificationsViewController, MediaViewerController) |

## Extra shared signatures

```swift
// UI/Components/PagerViewController.swift (Components)
protocol ModeSelectable: AnyObject { func selectMode(_ index: Int) }   // screens with a tab strip + pager conform

// UI/Common/Router.swift (Shell)
enum Router {
    // … ui-spec.md §2.5 …
    static func push(_ controller: UIViewController)          // onto the selected tab's navigation (closes the drawer first)
    static func present(_ controller: UIViewController)       // full screen, from the top-most view controller
}

// UI/Shell/ThemeSheet.swift (Shell)
enum ThemeSheet { static func present(from presenter: UIViewController?) }   // the ダークモード sheet of ui-spec §5.8

// Screen initialisers (Screens) used by Router:
//   TweetDetailViewController(tweet: Tweet), TweetDetailViewController(tweetID: String)
//   ProfileViewController(user: User), ProfileViewController(handle: String)
//   SearchResultsViewController(query: String), UserListViewController(userID: String, followers: Bool)
//   ComposeViewController(replyTo: Tweet?, quote: Tweet?)        (Router wraps it in an XNavigationController)
//   MediaViewerController(tweet: Tweet, index: Int)
//   HomeViewController(), SearchViewController(), NotificationsViewController()   (tab roots, plain init())
// Shell screens: MessagesViewController(), SettingsViewController(isInitialSetup: Bool = false), HistoryViewController()

// Timeline (Timeline) — ui-spec.md §4.1, plus:
extension TimelineViewController { var isLoaded: Bool { get } }
```

`TimelineViewController` lays its table out over its own `view.bounds`; the screen that embeds it sets the frame
(below the top bar / tab strip) and gives it `extraBottomInset`. It does **not** add space for the bottom bar itself:
`MainViewController` already ends the tab content above the bottom bar.

## Debug steps — who registers what

All registrations happen in a `static func registerDebugSteps()` of one type per part, called once by
`AppRoot.makeRootViewController()` (Shell) before the root is built: `ShellDebug.registerDebugSteps()`,
`ComponentsDebug.registerDebugSteps()`, `TimelineDebug.registerDebugSteps()`, `ScreensDebug.registerDebugSteps()`.
(`DebugRoutes.register` replaces a handler of the same name, so registering twice is harmless.)

| part | steps (ui-spec.md §6) |
|---|---|
| Shell | `tab`, `drawer`, `settings`, `history`, `themesheet`, `toast`, `userlist`, `mode` (finds the top-most visible view controller — presented ones first, then the selected tab's top — and calls `selectMode` when it is `ModeSelectable`) |
| Components | `overflow`, `repostmenu`, `sharemenu`, `like`, `bookmark` (posts come from `TweetStore.shared.tweet(id:)`) |
| Timeline | `scroll` (the visible `TimelineViewController`: walk the top-most view controller's children) |
| Screens | `hometab`, `tweet`, `profile`, `search`, `compose`, `reply`, `quote`, `type`, `viewer` |

## Demo data facts (from `Resources/Demo`, read them)

- Logged-in user: 山田 太郎 `@yamada_demo`.
- `demo_tweet_default.json` is answered for every `/v2/tweet`; its focal post is the 3rd item.
- Demo media URLs: photos `demo://photo/<n>?w=&h=`, avatars `demo://avatar/<n>`, banners `demo://banner/<n>`,
  cards `demo://card/<n>`; videos have `mp4` `demo://video/<n>.mp4` and no `hls` — in demo mode the player is not
  opened (show a Toast `デモでは再生できません`).
- Writes (like, post, follow…) succeed without changing the files.

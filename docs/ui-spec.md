# UI specification

How the app looks and behaves. The model is the official **Android** app of X (version 12.43): bottom bar with icons
only, a navigation drawer behind the avatar, "おすすめ / フォロー中" tabs, a floating compose button, vertical
"⋮" overflow, bottom sheets instead of iOS action sheets, left-aligned titles with a back arrow.

Read [`ios-design.md`](ios-design.md) first (hard rules, Core API, Theme, Icons, images). Everything here is built
from plain views and frames; all colours come from `Theme.palette`, all icons from `Icons.image`, all text is
Japanese. Reference width is **320 pt** (iPod touch); 375 pt and wider must also look right.

## 1. Metrics and type

`UI/Common/Metrics.swift`:

```swift
enum Metrics {
    static func pad(_ width: CGFloat) -> CGFloat        // page side padding: 12 when width <= 320, else 16
    static func gap(_ width: CGFloat) -> CGFloat        // avatar-to-content gap: 10 when width <= 320, else 12
    static let avatar: CGFloat = 40
    static let hairline: CGFloat                        // 1 / UIScreen.main.scale
    static let topBarHeight: CGFloat = 44               // below the status bar
    static let tabStripHeight: CGFloat = 44
    static let bottomBarHeight: CGFloat = 49            // above the bottom safe area
    static func contentX(_ width: CGFloat) -> CGFloat   // pad + avatar + gap
    static func contentWidth(_ width: CGFloat) -> CGFloat   // width - contentX - pad
}
```

| text | font |
|---|---|
| post body, handles, times, list text | 15 regular (line spacing 2) |
| names | 15 bold |
| counts in the action row, context line, card domain | 13 (context line: semibold) |
| focal post body | 17 regular (line spacing 3) |
| top bar title | 17 bold |
| tab strip | 15 (selected bold, others medium) |
| profile name | 20 bold |
| drawer rows | 20 bold |
| buttons (follow, post) | 14 bold |

Primary text uses `palette.text`, secondary `palette.secondaryText`, links/mentions/hashtags `palette.accent`.
A pressed row shows `palette.highlight` as its background while the finger is down.
Touch targets are at least 36×36 pt even when the drawn icon is smaller.

## 2. Structure

```
RootContainerViewController            window root: main UI + drawer + dimming
 ├─ MainViewController                 four tabs, custom bottom bar
 │   ├─ XNavigationController → HomeViewController
 │   ├─ XNavigationController → SearchViewController
 │   ├─ XNavigationController → NotificationsViewController
 │   └─ XNavigationController → MessagesViewController
 └─ DrawerViewController
```

Pushed screens (post detail, profile, search results, user list, settings, history) are pushed on the selected tab's
navigation controller; the bottom bar stays visible, as on Android.

### 2.1 `RootContainerViewController`

- `static var current: RootContainerViewController?` (the window's root).
- `let main: MainViewController`, `let drawer: DrawerViewController`.
- `func openDrawer()`, `func closeDrawer(completion: (() -> Void)? = nil)`. Drawer width `min(view.width * 0.85, 300)`,
  slides in from the left over the main UI in 0.25 s; behind it a dimming view (`palette.overlay`) fades in. Tap on
  the dimming or a pan to the left closes it.
- A `UIScreenEdgePanGestureRecognizer` (left edge) opens the drawer interactively, only when
  `main.isAtRoot` (the selected tab's navigation stack has one view controller) — otherwise the edge swipe belongs
  to "back".
- `preferredStatusBarStyle` = `Theme.statusBarStyle`.
- `AppRoot.makeRootViewController()` returns a new `RootContainerViewController`.
- When `RelayClient.shared.isConfigured` is false at first appearance, present the settings screen
  (`SettingsViewController(isInitialSetup: true)` inside an `XNavigationController`, full screen).
- Calls `Session.shared.refresh()` at start and when the app comes to the foreground (if configured).

### 2.2 `MainViewController`

- `static var current: MainViewController?`
- `enum Tab: Int { case home, search, notifications, messages }`, `var selectedTab: Tab`, `func select(_ tab: Tab)`.
- `var currentNavigation: XNavigationController`, `var isAtRoot: Bool`.
- Children are created on first selection (home immediately). The selected child's view fills
  `(0, 0, w, h − bottomBarHeight − safeAreaInsets.bottom)`, or on a large screen its content column (§8.2).
- Selecting the tab that is already selected: if its stack is deeper than the root, `popToRootViewController`;
  otherwise call `scrollToTopOrRefresh()` on the root if it conforms to `TabRootScrollable`.

```swift
protocol TabRootScrollable: AnyObject { func scrollToTopOrRefresh() }
```

`BottomBarView` (height `bottomBarHeight + safeAreaInsets.bottom`): background `palette.background`, a hairline
(`palette.separator`) along its top edge, four buttons of equal width. Icons 26 pt, tint `palette.text`
(the official bar is black/white, not blue): unselected `home`, `search`, `bell`, `message`; selected `homeFill`,
`searchBold`, `bellFill`, `messageFill`. No labels (accessibility labels ホーム / 検索 / 通知 / メッセージ).
Badge on the bell (and on the message icon): a circle of at least 16×16 (height 16, padding 4, radius 8), background
`palette.accent`, white 10 pt bold number, centred 10 pt right and 9 pt above the icon centre, "99+" above 99, hidden
at 0. Numbers come from `Session.shared.badges` (observe `Session.didUpdate`); opening the notifications tab sets
`Session.shared.badges.notifications = 0`.

### 2.3 `XNavigationController`

`UINavigationController` with the system bar hidden for good (`setNavigationBarHidden(true, animated: false)` in
`viewDidLoad`, and again in `pushViewController` paths if needed). It keeps the interactive "swipe back": it is the
delegate of `interactivePopGestureRecognizer` and allows it when `viewControllers.count > 1`.
`childForStatusBarStyle` returns `nil`; `preferredStatusBarStyle` = `Theme.statusBarStyle`.

### 2.4 `BaseViewController` and `TopBarView`

Every screen derives from `BaseViewController`:

```swift
class BaseViewController: UIViewController {
    let topBar = TopBarView()
    var showsTopBar: Bool { return true }               // override
    var topBarAccessoryHeight: CGFloat { return 0 }     // extra band below the bar (a tab strip)
    var contentTop: CGFloat                             // safeAreaInsets.top + topBarHeight + topBarAccessoryHeight (0 when the bar is hidden)
    func layoutContent()                                // override: called from viewDidLayoutSubviews after the bar is placed
}
```

- `view.backgroundColor = palette.background`.
- The bar's frame is `(0, 0, w, safeAreaInsets.top + topBarHeight)`: it also covers the status bar area.

`TopBarView`: opaque `palette.background`; optional hairline at the bottom (`showsSeparator`, default true).
Inside the lower 44 pt:

- `leftView` — at `x = pad`, vertically centred. Helpers: `setBackButton(_ action: @escaping () -> Void)` (icon `back`,
  24 pt, tint `palette.text`, 36×36 touch area), `setCloseButton(_:)` (icon `close`), `setAvatarButton()` (an
  `AvatarView` of 32 pt showing `Session.shared.me`, updating on `Session.didUpdate`; tap →
  `RootContainerViewController.current?.openDrawer()`).
- `title: String?` — 17 bold. `titleAlignment`: `.leading` (default, Android style: starts 20 pt right of the left
  view, or at `pad` without one) or `.center`.
- `centerView` — centred (the logo) or, with `centerViewFills = true`, stretched between the left view and the
  right views with 12 pt gaps (a search field).
- `rightViews: [UIView]` — right-aligned, 8 pt apart, `pad` from the edge.
- `onTapTitle` — called when the title or the centre view is tapped (scroll to top).

### 2.5 `Router`

Navigation helpers used by every screen and cell (`UI/Common/Router.swift`):

```swift
enum Router {
    static func openTweet(_ tweet: Tweet)
    static func openTweet(id: String)
    static func openProfile(user: User)
    static func openProfile(handle: String)
    static func openSearch(query: String)
    static func openUserList(userID: String, followers: Bool)
    static func openMedia(tweet: Tweet, index: Int)             // photo → viewer; video/gif → player
    static func openCompose(replyTo: Tweet? = nil, quote: Tweet? = nil)
    static func openSettings()
    static func openHistory()
    static func openURL(_ url: URL)
    static func open(entity: TextEntity)                        // url → openURL, mention → profile, hashtag "#tag" / cashtag "$SYM" → search
    static var topViewController: UIViewController?             // for presenting sheets/alerts
}
```

- Pushes go to `MainViewController.current?.currentNavigation`; the drawer is closed first when it is open.
- `openURL`: `https://x.com/<handle>/status/<id>` and `https://twitter.com/…` → `openTweet(id:)`;
  `https://x.com/<handle>` (one path component that is not a reserved word such as `home`, `search`, `i`,
  `explore`, `settings`, `notifications`, `messages`) → `openProfile(handle:)`; other `http(s)` URLs →
  `SFSafariViewController` (`preferredControlTintColor = palette.accent`); anything else →
  `UIApplication.shared.open`.

## 3. Shared components

### 3.1 `TabStripView`

`init(titles: [String], style: Style)` with `enum Style { case fill, scroll }`; height `tabStripHeight`.
`fill`: equal segments across the width. `scroll`: segments as wide as their title + 32, in a horizontal scroll view
(used when there are many tabs); the selected segment is scrolled into view.
Selected title 15 bold `palette.text`, others 15 medium `palette.secondaryText`. Indicator: 4 pt high, radius 2,
`palette.accent`, as wide as the selected title's text, at the bottom of the strip; it moves in 0.2 s, or follows
`setProgress(_ position: CGFloat)` (fractional index) while a pager is dragged. Hairline at the bottom.
`var selectedIndex: Int`, `var onSelect: ((Int) -> Void)?`, `func setTitles(_:)`.

### 3.2 `PagerViewController`

A horizontally paging `UIScrollView` with one child view controller per page, created on demand by
`makePage: (Int) -> UIViewController`:
`init(pageCount: Int, makePage: @escaping (Int) -> UIViewController)`, `var currentIndex`,
`func setPage(_ index: Int, animated: Bool)`, `var onProgress: ((CGFloat) -> Void)?`, `var onPageChange: ((Int) -> Void)?`,
`func page(at index: Int) -> UIViewController?`. Only the visible page's scroll view has `scrollsToTop = true`.
When a page becomes current for the first time it gets `loadIfNeeded()` if it is a `TimelineViewController`.
Its pan gesture must wait for edge gestures: `scrollView.panGestureRecognizer.require(toFail:)` for the drawer's
edge pan and the navigation controller's `interactivePopGestureRecognizer`.

### 3.3 `BottomSheet`

The Android "modal bottom sheet" that replaces iOS action sheets:

```swift
struct BottomSheetItem {
    enum Style { case normal, destructive }
    let icon: IconName?
    let title: String
    var style: Style = .normal
    var isChecked: Bool = false            // shows a `check` icon at the right
    let handler: () -> Void
}
enum BottomSheet {
    static func present(from presenter: UIViewController?, title: String? = nil, items: [BottomSheetItem])
}
```

A view controller presented `.overFullScreen` without the system animation: a dimming view (`palette.overlay`) fades
in while the sheet slides up from the bottom (0.25 s). Sheet: `palette.background`, top corners radius 16, a 36×4
grabber (`palette.border`, radius 2) 8 pt from the top, optional title (15 bold, `pad` inset, 44 pt high), then rows
52 pt high: icon 22 pt at `x = 20` tinted `palette.text` (`palette.danger` for destructive), title 16 regular at
`x = 60` (20 without an icon) in the same colour, pressed state `palette.highlight`. Below the rows: 8 pt + the bottom
safe area. Tapping a row dismisses the sheet and then calls its handler. Tapping the dimming or dragging the sheet
down dismisses it.

### 3.4 Text

```swift
final class TextLayout {                   // measured, drawable, hit-testable text (TextKit 1)
    let size: CGSize                       // ceil of the used rect
    let isTruncated: Bool
    init(_ text: NSAttributedString, width: CGFloat, maxLines: Int = 0, entities: [TextEntity] = [])
    func draw(at origin: CGPoint)
    func entity(at point: CGPoint) -> TextEntity?      // nil when the point is not on an entity's glyphs
    func rects(for range: NSRange) -> [CGRect]
}
final class LinkLabel: UIView {            // draws a TextLayout; only entities are touchable
    var textLayout: TextLayout?
    var onTapEntity: ((TextEntity) -> Void)?
}
enum TweetText {
    static func attributed(_ text: String, entities: [TextEntity], font: UIFont, color: UIColor,
                           linkColor: UIColor, lineSpacing: CGFloat) -> NSAttributedString
}
```

- `TextLayout` owns an `NSTextStorage`, `NSLayoutManager` and `NSTextContainer` (`lineFragmentPadding = 0`,
  `maximumNumberOfLines = maxLines`, `lineBreakMode = .byTruncatingTail` when `maxLines > 0`, container size
  `(width, .greatestFiniteMagnitude)`). The same object measures and draws, so heights are exact.
  `isTruncated` = the glyph range of the container ends before `numberOfGlyphs`.
- `LinkLabel.hitTest` returns the label only when the point is on an entity; any other touch falls through to the
  row behind it (so tapping plain text opens the post). While an entity is pressed its rects are filled with
  `palette.accent` at 15 % (radius 3). `isOpaque = false`, `contentMode = .redraw`.
- `TweetText.attributed` validates entity ranges against the UTF-16 length before colouring them.

### 3.5 `NameLineView`

One line: **name** (15 bold) · badge · lock · `@handle` (15, secondary) · ` · 3時間` (15, secondary).

- Badge: icon `verified` 16 pt after the name with a 2 pt gap: `palette.accent` for `blue`, `palette.gold` for
  `business`, `palette.grey` for `government`. Protected accounts add the `lock` icon (14 pt, `palette.text`).
- The time never shrinks. If everything does not fit, the handle is shortened first (tail "…") down to 30 pt, then
  the name. Implemented with three `UILabel`s and image views placed by frame.
- `func set(user: User, time: String?, width: CGFloat)`; `static let height: CGFloat = 20`.
- Variant without time/handle (`showsHandle = false`) for the focal post and profile rows.

### 3.6 `MediaGridView`

`func configure(media: [Media], width: CGFloat, interactive: Bool)`,
`static func height(for media: [Media], width: CGFloat) -> CGFloat`, `var onTap: ((Int) -> Void)?`.

| items | layout (2 pt gaps) | height |
|---|---|---|
| 1 | one tile | `round(width / clamp(aspect, 0.75, 2.5))` |
| 2 | two tiles side by side | `round(width * 4 / 7)` |
| 3 | left tile full height, right column two tiles | `round(width * 4 / 7)` |
| 4+ | 2×2 (the first four) | `round(width * 9 / 16)` |

Corner radius 16 with `masksToBounds`, a hairline border in `palette.border`. Tiles are `RemoteImageView`s
(`scaleAspectFill`, background `palette.surface`): photos load `imageURL(.small)`, video/GIF load `url` (the poster).
Overlays: video — a 48 pt circle in `palette.accent` with a 3 pt white border and the white `play` icon (22 pt) in
the centre, plus the duration (`Format.duration`) in a pill at the bottom-left (8 pt inset; black 77 %, radius 4,
white 12 medium, padding 2×4); GIF — the same pill with "GIF".

### 3.7 `QuoteView`

`func configure(tweet: Tweet?, unavailable: String?, width: CGFloat)`,
`static func height(tweet: Tweet?, unavailable: String?, width: CGFloat) -> CGFloat`, `var onTap: (() -> Void)?`.
A box: hairline border `palette.border`, radius 16, padding 12, pressed state `palette.highlight`.
Row 1: `AvatarView` 20 pt + 4 pt + `NameLineView`. Row 2 (4 pt below): the text, 15 regular, at most 8 lines, links
coloured but not touchable. If the quoted post has media: 8 pt below, a `MediaGridView` over the inner width
(not interactive). Unavailable: only the notice, 15 `secondaryText`. The whole box is one touch target.

### 3.8 `CardView`

`func configure(card: Card, width: CGFloat)`, `static func height(card: Card, width: CGFloat) -> CGFloat`.

- `large` / `player` with an image: the image `width × round(width / 1.91)`, radius 16, hairline border; at its
  bottom-left (12 pt inset) the title in a pill (black 77 %, radius 4, white 13 regular, one line, padding 2×4, at
  most `width − 24` wide); `player` adds the play circle of 3.6. 4 pt below the image: `<domain> から` (13,
  `secondaryText`, 18 pt high).
- `summary` (or `large` without an image): a box 88 pt high (hairline border, radius 16): left a 88×88 thumbnail
  (image, or `palette.surface` with the `link` icon 24 pt in `secondaryText`), a vertical hairline, then with 12 pt
  insets: domain (13, `secondaryText`, one line) and title (15, `palette.text`, two lines).
- `poll`: one row per choice, 32 pt high, 4 pt apart: a bar from the left (radius 4, `palette.accent` at 30 % for the
  choice with most votes, else `palette.surface`) as wide as its share (at least 4 pt), the label at `x = 12` (15;
  bold for the leading choice), the share right-aligned (`45.2%`, 15). 4 pt below: `1,234票 · 最終結果` or
  `1,234票 · 残り3時間` / `残り12分` / `残り2日` (13, `secondaryText`, 20 pt high).
- A tap (not for polls) opens `card.url` through `Router.openURL`.

### 3.9 Action bars

`ActionBarView` (timeline rows): `func configure(tweet: Tweet, width: CGFloat)`; height 32 (icons centred
vertically). Icons 18 pt, counts 13 regular 4 pt right of the icon, both `palette.secondaryText`; a count of 0 is
not shown.

- Slots: `slot = floor((width − 52) / 4)`; reply at `x = 0`, repost at `slot`, like at `2·slot`, views at `3·slot`
  (icon left-aligned in its slot); bookmark icon at `x = width − 52`, share icon at `x = width − 18`.
- reply `reply` + `replyCount`; repost `repost` + `retweetCount` (`palette.repost` when `retweeted`); like `heart` /
  `heartFill` + `likeCount` (`palette.like` when `liked`); views `views` + `viewCount` (hidden when `nil`);
  bookmark `bookmark` / `bookmarkFill` (`palette.accent` when `bookmarked`); share `share`.
- Counts use `Format.count`.
- Callbacks: `onReply`, `onRepost`, `onLike`, `onBookmark`, `onShare`.
- Liking plays a short bounce on the heart (scale 0.8 → 1.2 → 1, 0.25 s) and a light impact
  (`UIImpactFeedbackGenerator(style: .light)`).

`FocalActionBarView` (the large post): height 48, five equal slots across the width — reply, repost, like, bookmark,
share — each with a 22 pt icon and its count (13) centred as a group; same colours and callbacks.

### 3.10 `FollowButton`

A pill 32 pt high, at least 96 pt wide, title 14 bold:

| state | look |
|---|---|
| not following | background `palette.text`, title `フォローする` in `palette.background` |
| following | no fill, hairline border `palette.border`, title `フォロー中` in `palette.text` |
| request sent | like "following", title `承認待ち` |
| blocking | background `palette.danger`, white title `ブロック中` |

`func set(user: User)`; a tap calls `UserActions.toggleFollow(user)` (blocking → unblock after confirmation) and the
button follows `User.didChange`.

### 3.11 State views

- `LoadingView`: a centred `UIActivityIndicatorView` (`.gray` on iOS 12, `.medium` on 13+; `color =
  palette.secondaryText`), animating.
- `MessageView(title: String, detail: String?, buttonTitle: String?, action: (() -> Void)?)`: centred, title 20 bold,
  detail 15 `secondaryText` (multi-line, at most `width − 64`), an optional pill button (accent background, white
  14 bold, 36 pt high).

## 4. Timeline engine

One list implementation serves the home tabs, search results, profile posts, bookmarks, notifications, replies…

### 4.1 `TimelineViewController`

```swift
final class TimelineViewController: UIViewController {
    typealias Loader = (_ cursor: String?, _ completion: @escaping (Result<TimelinePage, Error>) -> Void) -> Void
    init(source: TimelineSource)                 // loader = RelayClient.shared.timeline(source, …)
    init(loader: @escaping Loader)
    let tableView: UITableView
    var emptyText: String                        // default "表示できるポストがありません"
    var headerView: UIView?                      // set as tableHeaderView (profile header)
    var extraBottomInset: CGFloat                // e.g. room for the compose button
    var transformItems: (([TimelineItem]) -> [TimelineItem])?      // applied to every page before rows are built
    var onFirstPage: ((TimelinePage) -> Void)?
    var onScroll: ((UIScrollView) -> Void)?
    func loadIfNeeded()                          // first load, once
    func reload()                                // first page again (pull to refresh uses it)
    func setSource(_ source: TimelineSource)     // switch what is shown; clears rows and loads
    func scrollToTopOrRefresh()                  // at the top already → reload, else scroll to the top
    func insertAtTop(_ tweet: Tweet)             // a post just created
}
```

- The table: plain style, `separatorStyle = .none`, exact heights from the row models (rule 2 of ios-design.md §1),
  background `palette.background`, `keyboardDismissMode = .onDrag`.
- First load: `LoadingView` in the middle. Failure: `MessageView` with the error's `localizedDescription` and a
  `再試行` button. Empty: `MessageView(title: emptyText)`.
- Pull to refresh: `UIRefreshControl` (tint `palette.secondaryText`) → `reload()`; a failure shows a `Toast` and
  keeps the old rows.
- More pages: when `bottom != nil`, nothing is loading and the offset is within 800 pt of the end, load with
  `cursor = bottom` and append. A page that adds no new row ends the list (`bottom = nil`). While loading, a 44 pt
  footer with a spinner. A failure shows a `Toast`; the next scroll tries again.
- Duplicates: only across pages — when a further page is appended, its stand-alone posts (`above == false && below
  == false`) whose `tweet.id` + `retweetID` are already listed are dropped. Items of one answer are shown exactly as
  the server sent them (the server already removed duplicates there, but keeps the posts of a conversation thread).
- `more` rows: tapping one shows a spinner in it, loads that cursor and replaces the row by the page's items.
- `viewWillAppear`: reload when `RelayClient.shared.configurationRevision` differs from the one of the last load.
- Notifications: `.tweetDeleted` (object: post id) removes matching rows; a width change rebuilds all row layouts.
- Row taps: post → `Router.openTweet(tweet)` (not for the focal row); user → `Router.openProfile(user:)`; rows of
  kind notification / trend decide themselves (4.5).
- Debug step `scroll:<points>`: scrolls the visible timeline to that offset (clamped).

### 4.2 Rows

`UI/Timeline/Rows.swift`:

```swift
protocol TimelineRow: AnyObject {
    var reuseIdentifier: String { get }
    var cellClass: UITableViewCell.Type { get }
    func height(for width: CGFloat) -> CGFloat          // cached per width
    func configure(_ cell: UITableViewCell, width: CGFloat)
    func didSelect(from controller: UIViewController)   // default: nothing
    var dedupeKey: String? { get }                      // posts: id (+ repost id); others nil
}
enum TimelineRowFactory {
    static func rows(for items: [TimelineItem]) -> [TimelineRow]
}
```

| item | row class | cell |
|---|---|---|
| `tweet` (not focal) | `TweetRow` | `TweetCell` |
| `tweet` with `focal` | `FocalTweetRow` | `FocalTweetCell` |
| `more` | `MoreRow` | `MoreCell` |
| `header` | `HeaderRow` | `HeaderCell` |
| `tombstone` | `TombstoneRow` | `TombstoneCell` |
| `user` | `UserRow` | `UserCell` |
| `notification` | `NotificationRow` | `NotificationCell` |
| `trend` | `TrendRow` | `TrendCell` |

### 4.3 `TweetRow` / `TweetCell` (a post in a list)

Layout for cell width `W` (`pad`, `gap`, `contentX`, `contentWidth` from `Metrics`); `y` starts at 12:

1. **Context line** (only for a repost or a `context`): a 16 pt icon right-aligned to the avatar's right edge
   (`x = pad + 40 − 16`) and, at `contentX`, one line of 13 semibold `secondaryText`, 16 pt high; then `y += 20`.
   Repost: icon `repost`, text `<name>さんがリポスト` (`リポスト済み` when it is the logged-in user). `pin`: icon
   `pin`, the context text. `text`: no icon, the context text.
2. **Avatar** `AvatarView` 40 pt at `(pad, y)`; tap → profile.
3. **Name line** `NameLineView` at `(contentX, y)`, width `contentWidth − 28`; time = `Format.relativeTime`.
   **Overflow** button: icon `overflow` 18 pt in `secondaryText`, 36×36 touch area, its icon's right edge at
   `W − pad`, vertically centred on the name line. `y += 22`.
4. **Reply line** (when `replyToHandles` is not empty and the row is not joined to the row above): one line, 15:
   `返信先: ` in `secondaryText` + `@handle` (accent; two handles joined by ` `; more than two:
   `@a @b、他N人`) + `さん` in `secondaryText`; `y += 22`.
5. **Text** (when not empty): `LinkLabel` at `(contentX, y)`, width `contentWidth`; a long post (`isLong`) is limited
   to 10 lines, and when it is truncated a line `さらに表示` (15, accent, 22 pt high) follows. `y += height`.
6. **Attachments**, each preceded by a 12 pt gap (10 pt when it is the first thing after the name line because there
   is no text): `MediaGridView` → `CardView` → `QuoteView`, each `contentWidth` wide at `contentX`. A post with media
   shows no card.
7. **Action bar** `ActionBarView` at `(contentX, y + 6)`, `contentWidth` wide, 32 high; `y += 6 + 32 + 6`.
8. Row height = `max(y, 12 + 40 + 12)`.

- Hairline separator along the bottom, full width, `palette.separator` — not drawn when `below` is true.
- Thread line: 2 pt wide, `palette.border`, centred under the avatar (`x = pad + 19`): with `above`, from the top of
  the row to 4 pt above the avatar; with `below`, from 4 pt under the avatar to the bottom of the row.
- The cell observes `Tweet.didChange` for its post and refreshes the action bar.
- Taps: media tile → `Router.openMedia`; quote → `Router.openTweet(quote)`; entity → `Router.open(entity:)`;
  `さらに表示` and anywhere else → the post's detail; action bar and overflow → `TweetActions`.

### 4.4 `FocalTweetRow` / `FocalTweetCell` (the post the detail screen is about)

1. Thread line from the top to 4 pt above the avatar when `above`.
2. `y = 12`: context line as in 4.3 when present.
3. Avatar 40 pt at `(pad, y)`; at `x = pad + 40 + gap`: the name with badge (15 bold, `NameLineView` without handle)
   and, 20 pt lower, `@handle` (15 `secondaryText`). At the right: the overflow button and, left of it with an 8 pt
   gap, a `FollowButton` when the author is neither followed nor the logged-in user. `y += 40 + 12`.
4. Reply line as in 4.3 (always, when there are handles); `y += 24`.
5. Text: 17 regular, line spacing 3, full width `W − 2·pad` at `x = pad`, no line limit.
6. Attachments as in 4.3, `W − 2·pad` wide at `x = pad`, 12 pt gaps.
7. 12 pt gap, then one line (15, `secondaryText`, 20 high): `午後7:05 · 2026年11月16日` and, when there is a view
   count, ` · ` + the count in `palette.text` bold + ` 件の表示`. Then 12 pt.
8. Hairline from `pad` to `W − pad`; `FocalActionBarView` (48 high, full width); hairline across the full width.

### 4.5 Other rows

- `MoreCell`: 48 pt high; the label (15, accent) at `contentX`; while loading a small spinner instead. Hairline
  below.
- `HeaderCell`: an 8 pt band of `palette.surface`, then the text in 20 bold with `pad` insets, 52 pt high in total
  (band included: 60). Hairline below.
- `TombstoneCell`: a box (`palette.surface`, radius 12) from `pad` to `W − pad` with 8 pt above and below,
  containing the text (15, `secondaryText`, 12 pt insets, multi-line). Thread line pieces as in 4.3 when
  `above`/`below` (behind the box, at the avatar column).
- `UserCell`: avatar 40 at `(pad, 12)`; name line without time at `contentX` (width minus the button); `@handle`
  below (15 `secondaryText`), with a chip `フォローされています` (11 medium `secondaryText` on `palette.surface`, radius
  4, padding 2×4) after it when `followedBy`; a `FollowButton` at the right, top-aligned (not for the logged-in
  user); below, the bio (15, at most 2 lines) over `contentWidth`. 12 pt padding at the bottom; hairline.
  Tap → profile.
- `NotificationCell` and `TrendCell`: see 5.6 and 5.5.

### 4.6 `TweetActions` and `UserActions`

`UI/Common/TweetActions.swift`. Every change is applied to the model at once (then `notifyChanged()`), sent to the
relay, and reverted with a `Toast` of the error text if the relay refuses.

```swift
enum TweetActions {
    static func reply(to tweet: Tweet)                     // Router.openCompose(replyTo:)
    static func showRepostMenu(for tweet: Tweet)           // sheet: リポスト / リポストを取り消す (icon repost), 引用 (icon pencil → compose with quote)
    static func toggleRepost(_ tweet: Tweet)
    static func toggleLike(_ tweet: Tweet)
    static func toggleBookmark(_ tweet: Tweet)             // Toast: ブックマークに追加しました / ブックマークから削除しました
    static func showShareMenu(for tweet: Tweet)            // sheet: リンクをコピー (copy; Toast コピーしました), 共有する… (external; UIActivityViewController with the permalink)
    static func showOverflowMenu(for tweet: Tweet)
    static func delete(_ tweet: Tweet)                     // confirmation alert, then relay, then post .tweetDeleted
}
enum UserActions {
    static func toggleFollow(_ user: User)
    static func toggleMute(_ user: User)                   // Toast: @xさんをミュートしました / ミュートを解除しました
    static func toggleBlock(_ user: User)                  // confirmation alert before blocking
}
extension Notification.Name {
    static let tweetDeleted: Notification.Name             // object: post id (String)
    static let tweetCreated: Notification.Name             // object: Tweet? ; userInfo["replyTo"]: String?
}
```

Overflow sheet — own post (`tweet.user.id == Session.shared.me?.id`): `ポストを削除` (trash, destructive),
`リンクをコピー` (link). Someone else's: `@handleさんをフォロー` / `@handleさんのフォローを解除` (userPlus /
userMinus), `@handleさんをミュート` / `ミュートを解除` (volumeOff), `@handleさんをブロック` / `ブロックを解除` (ban,
destructive), `リンクをコピー` (link).

`UIActivityViewController` on iPad needs `popoverPresentationController.sourceView` (the presenter's view, centre).

## 5. Screens

### 5.1 Home — `HomeViewController` (`TabRootScrollable`)

- Top bar: avatar button left; centre the `logo` icon (22 pt, tint `palette.text`); no separator (the strip below has
  one). `onTapTitle` → scroll the current list to the top.
- `topBarAccessoryHeight = tabStripHeight`: `TabStripView(titles: ["おすすめ", "フォロー中"], style: .fill)`.
- Below: `PagerViewController` with two `TimelineViewController`s (`.home(following: false)`,
  `.home(following: true)`), `extraBottomInset = 80`. The selected tab is remembered (`UserDefaults` `homeTab`).
- Compose button: a 56 pt circle, `palette.accent`, white `plus` icon 24 pt, shadow (black 25 %, radius 6, offset
  0/2), 16 pt from the right and bottom edges of the content area; tap → `Router.openCompose()`.
- `.tweetCreated` without `replyTo`: insert the new post at the top of "フォロー中" and "おすすめ" lists that are
  loaded.

### 5.2 Compose — `ComposeViewController(replyTo: Tweet?, quote: Tweet?)`

Presented full screen in an `XNavigationController`.

- Top bar: `close` button left; right a pill button (32 high, 16 pt side padding, `palette.accent`, white 14 bold):
  `ポストする` (`返信` for a reply), at 50 % opacity and disabled while the text is empty or too long, replaced by a
  white spinner while sending. No title, no separator.
- Body (scrolls with the keyboard): for a reply, first a line at `contentX`: `返信先: @handle さん` (as 4.3-4).
  Then the logged-in user's avatar (40) at `pad` and a `UITextView` at `contentX` (17 regular, `palette.text`, clear
  background, no insets) with a placeholder label (`いまどうしてる？`; reply: `返信をポスト`; quote: `コメントを追加`,
  `secondaryText`). For a quote, a `QuoteView` of the quoted post under the text view (`contentWidth` wide).
- A 44 pt bar pinned above the keyboard (hairline on top, `palette.background`): at the right the length ring — a
  22 pt circle, 2 pt line, track `palette.separator`, progress `palette.accent` (= weighted length / 280); from 260
  the remaining count is shown inside (11 pt) and the ring turns `#FFD400`; over 280 the ring and the (negative)
  number are `palette.danger`. Length = `TwitterText.weightedLength`.
- Sending: `RelayClient.shared.createTweet(text:replyTo:quote:)`; success → dismiss, `Toast.show("ポストしました")`,
  post `.tweetCreated`; failure → an alert with the error text (the text stays).
- Closing with text entered asks `ポストを破棄しますか？` (破棄 / キャンセル).
- The keyboard opens when the screen appears.

### 5.3 Post detail — `TweetDetailViewController(tweet: Tweet)` / `(tweetID: String)`

- Top bar: back button, title `ポスト`.
- A `TimelineViewController(source: .tweet(id:))` fills the area between the top bar and the reply bar.
- Until the first answer arrives, and when the screen was opened with a `Tweet`, that post is shown as the focal row
  with a spinner row under it (`transformItems`/a preliminary row set — the list must never be empty then).
- After the first page: if rows precede the focal row, scroll so the focal row is at the top (no animation); the
  conversation above is reachable by scrolling up.
- Reply bar, 52 pt high above the bottom bar, hairline on top: a pill (36 high, radius 18, `palette.surface`) from
  `pad` to `W − pad` with `返信をポスト` (15, `secondaryText`, 16 pt inset); tap → `TweetActions.reply(to:)` for the
  focal post.
- `.tweetCreated` with `replyTo == focal id` → reload.
- `.tweetDeleted` of the focal post → pop.

### 5.4 Profile — `ProfileViewController(user: User)` / `(handle: String)`

One `TimelineViewController` whose `headerView` is the profile header; the top bar floats above it.

Header (width `W`):

- Banner: `W × round(W / 3)`, `RemoteImageView` (`bannerURL(wide: false)`), `palette.surface` behind/without it.
- Avatar: 72 pt, with a 4 pt ring in `palette.background`, at `x = pad`, vertically centred on the banner's lower
  edge. Tap → nothing.
- Right, 12 pt below the banner: `FollowButton` (not for the logged-in user) and left of it (8 pt) a 32 pt round
  button with the `overflow` icon (hairline border) → sheet `リンクをコピー` / mute / block entries of 4.6.
- Below the avatar (8 pt): name (20 bold) + badge 20 pt + lock; `@handle` (15 `secondaryText`) and the
  `フォローされています` chip; 12 pt lower the bio (`LinkLabel`, 15, entities touchable); 12 pt lower the meta items in
  a wrapping flow (13 pt icon gap 4, items 12 apart, 15 `secondaryText`): `mapPin` location, `link` link display
  text (accent, opens the URL), `calendar` `Format.joined`; 12 pt lower: **88** `フォロー中` · **1,471** `フォロワー`
  (numbers 14 bold `palette.text`, words 14 `secondaryText`, 20 pt between the two groups; taps →
  `Router.openUserList`).
- `TabStripView(.fill)`: `ポスト`, `返信`, `メディア`, and `いいね` for the logged-in user's own profile. Selecting one
  calls `timeline.setSource(.userTimeline(userID:tab:))` and keeps the header.

Behaviour:

- Opened with a `User`: name, avatar and badge are shown at once, the rest after `RelayClient.shared.user(handle:)`.
- Top bar: transparent over the banner with the back button in a 32 pt circle (black 50 %, white icon); once the list
  is scrolled past the banner it becomes the normal opaque bar with the name as title. (Two states, switched from
  `onScroll`; no animation needed.)
- `protected` and not followed (and not self): no list; `MessageView("このアカウントのポストは非公開です", …)`.
  `blockedBy`: `MessageView("ブロックされています", …)`.
- Failure to load the user: `MessageView` with the error and `再試行`.

`UserListViewController(userID: String, followers: Bool)`: top bar (back, title `フォロワー` / `フォロー中`) over a
`TimelineViewController(source: .follows(…))`.

### 5.5 Search — `SearchViewController` (tab root) and `SearchResultsViewController(query: String)`

`SearchFieldView`: a pill 36 pt high (radius 18, `palette.surface`) with the `search` icon (16 pt, `secondaryText`)
at 12 pt and a `UITextField` (15, placeholder `検索`, `returnKeyType = .search`, clear button while editing,
no autocorrection/capitalisation). `var onSubmit: ((String) -> Void)?`, `var text: String`.

`SearchViewController` (`TabRootScrollable`):

- Top bar: avatar button; `SearchFieldView` as the filling centre view. Submit → `Router.openSearch(query:)`.
- Accessory: `TabStripView(.scroll)` with the explore tabs (`ExplorePage.tabs`, loaded with the first page; hidden
  until then).
- Content: one `TimelineViewController(loader:)` per tab in a `PagerViewController`, the loader calling
  `RelayClient.shared.explore(tab:)` (no further pages).
- `TrendCell`: `pad` insets, 12 pt above and below: context (13 `secondaryText`), name (15 bold), meta (13
  `secondaryText`), each line only when present, 2 pt apart; hairline below. Tap → `Router.openSearch(trend.query)`.

`SearchResultsViewController`:

- Top bar: back button; `SearchFieldView` showing the query (submitting a new one replaces the screen's query and
  reloads).
- Accessory: `TabStripView(["話題", "最新", "ユーザー", "メディア"], .fill)`; pager of four
  `TimelineViewController(source: .search(query:mode:))` (`top`, `latest`, `people`, `media`), empty text
  `「<query>」の検索結果はありません`.

### 5.6 Notifications — `NotificationsViewController` (`TabRootScrollable`)

- Top bar: avatar button, title `通知`.
- Accessory `TabStripView(["すべて", "@ポスト"], .fill)`; pager with `.notifications(mentions: false)` and
  `.notifications(mentions: true)`; empty text `通知はまだありません`.
- `NotificationCell`: left column — the icon, 24 pt, right-aligned to `pad + 40` at `y = 12`: `heart` → `heartFill`
  in `palette.like`; `repost` → `repost` in `palette.repost`; `person` → `personFill` in `palette.accent`; `star` →
  `star` in `#7856FF`; `logo` → `logo` in `palette.text`; `reply` → `reply` in `palette.accent`; `alert` → `alert` in
  `palette.danger`; others → `bellFill` in `palette.accent`. Right column at `contentX`: the users' avatars (28 pt,
  4 pt apart, at most what fits; each tappable → profile), 8 pt below the text (15, the `bold` ranges bold), and when
  there is a post, 4 pt below, its text in `secondaryText` (15, at most 3 lines). 12 pt padding, hairline.
  Tap → the post's detail when there is a post, else `Router.openURL(url)` when there is a URL.

### 5.7 Messages — `MessagesViewController`

Top bar: avatar button, title `メッセージ`. For now a `MessageView("メッセージ", detail:
"ダイレクトメッセージには、まだ対応していません。")`.

### 5.8 Drawer — `DrawerViewController`

Background `palette.background`. Content inset 20 pt from the left, top = safe area + 16:

- `AvatarView` 40 pt (tap → own profile); 8 pt below the name (17 bold) with badge; `@handle` (15 `secondaryText`);
  12 pt below **11** `フォロー中` **9** `フォロワー` (as in 5.4; taps → user lists).
- 16 pt below, rows 56 pt high — icon 24 pt (`palette.text`) + 20 pt + title 20 bold: `プロフィール` (`person`),
  `履歴` (`history`), then a hairline with 8 pt above/below, then `設定とプライバシー` (`settings`) in 15 regular.
- Bottom-left (20 pt from the left, 16 pt above the safe area): a 36 pt button with the `sun` (dark themes) / `moon`
  (light) icon → `BottomSheet` titled `ダークモード`: `ライト`, `ダークブルー`, `ブラック`, and on iOS 13+
  `端末の設定に合わせる`; the current one checked; choosing sets `Theme.mode`.
- Every row closes the drawer, then navigates through `Router`.
- Without `Session.shared.me` the header shows the placeholder avatar and `未設定`.

### 5.9 Settings — `SettingsViewController(isInitialSetup: Bool = false)`

Top bar: back button (`close` when presented for the initial setup), title `設定とプライバシー`.
A scrolling form (own views; section titles 13 bold `secondaryText`, rows 52 pt with hairlines):

- `リレーサーバー`: three labelled text fields — `リレーURL` (URL keyboard, placeholder
  `https://example.com/xclient`), `プロフィール名` (placeholder `account1（任意）`), `CGIキー` (secure entry) — then
  the rows `接続テスト` and `保存` (15 bold, accent, centred).
  Validation and messages exactly as v1's `SettingsViewController` (`git show HEAD:ios/XRelayClient/SettingsViewController.swift`):
  URL must be http/https with a host and a safe base path, plain `http` only for local addresses, key at least 32
  characters. Connection test → alert with the profiles found. Save → `RelayClient.shared.saveSettings`,
  `Session.shared.refresh()`, `Toast.show("保存しました")`; in the initial setup the screen is dismissed.
- `画面表示`: row `ダークモード` with the current choice at the right → the sheet of 5.8.
- `データ`: row `画像キャッシュを削除` with the size at the right (`12.3 MB`) → `ImageLoader.shared.clearCaches()`,
  Toast `削除しました`.
- `このアプリについて`: `バージョン` with `2.0 (123)` from the bundle; a note (13 `secondaryText`):
  `X の非公式クライアントです。X Corp. とは関係ありません。`
- Initial setup adds an introduction above the form:
  `はじめに、リレーサーバーのURLとCGIキーを設定してください。`

### 5.10 History — `HistoryViewController`

Top bar: back, title `履歴`. Accessory `TabStripView(["ブックマーク", "いいね"], .fill)`; pager with
`TimelineViewController(source: .bookmarks)` (empty text `ブックマークはまだありません`) and
`.userTimeline(userID: me.id, tab: .likes)` (empty text `いいねしたポストはまだありません`; when `Session.shared.me` is
unknown, a `MessageView` asking to try again after `Session.shared.refresh()`).

### 5.11 Media — `MediaViewerController(tweet: Tweet, index: Int)`

Photos, full screen (`.overFullScreen`), black background:

- A paging scroll view with one zoomable page per photo of the post (`imageURL(.medium)`, `maxPixel` 2048, the
  timeline's small image shown first while it loads). Pinch and double-tap zoom (1× ↔ 2.5×).
- A `close` button (36 pt circle, black 50 %, white icon) at the top-left inside the safe area; `1/4` (15, white) at
  the top centre when there are several.
- At the bottom, above the safe area, a `FocalActionBarView`-style row in white for the post (reply, repost, like,
  bookmark, share).
- Dragging a not-zoomed photo vertically moves it and fades the background; released beyond 120 pt (or fast) it
  dismisses. A single tap toggles the buttons.
- Status bar hidden while it is shown.

Video / GIF: `AVPlayerViewController` presented full screen with `AVPlayer(url: hlsURL ?? mp4URL)`, playing at once;
a GIF is muted and loops (seek to zero on `AVPlayerItemDidPlayToEndTime`). The audio session category is `.playback`
for videos so they sound with the mute switch on.

## 6. Debug steps (for CI screenshots)

Registered with `DebugRoutes.register` by the screen that owns them:

| step | effect |
|---|---|
| `tab:<0…3>` | select a bottom tab |
| `drawer` | open the drawer |
| `orient:<portrait\|landscape>` | rotate the device (iPad); the screens and the preview window follow (§8.5) |
| `hometab:<0\|1>` | select a home tab |
| `scroll:<points>` | scroll the visible timeline |
| `tweet:<id>` | open the post detail |
| `profile:<handle>` | open a profile |
| `search:<query>` | open search results |
| `mode:<0…3>` | select a tab of the visible tab strip/pager (search results, notifications, history, profile, explore) |
| `compose`, `reply:<id>`, `quote:<id>` | open the composer (the post is taken from `TweetStore`) |
| `type:<text>` | put text into the composer |
| `overflow:<id>`, `repostmenu:<id>`, `sharemenu:<id>` | open that sheet for a loaded post |
| `like:<id>`, `bookmark:<id>` | toggle through `TweetActions` |
| `viewer:<id>:<index>` | open the media viewer |
| `settings`, `history`, `themesheet` | open those |
| `userlist:<user id>` | following list |
| `toast:<text>` | show a toast |
| `icons` | icon gallery |

## 7. Translation (as in the official app)

Core (`Models.swift`, `RelayClient.swift`):

```swift
struct Translation { let text: String; let entities: [TextEntity]; let sourceLang: String; let sourceLangName: String; let provider: String; init?(json: JSON) }
// Tweet: var translatable: Bool (JSON "translatable"); runtime state, not from JSON and kept by merge():
//        var translation: Translation?, var showsTranslation: Bool, var isTranslating: Bool
// User:  var bioTranslatable: Bool (JSON "bio_translatable"); var bioTranslation: Translation?, var showsBioTranslation: Bool
// Tweet.layoutDidChange: Notification.Name("TweetLayoutDidChange") (object: the Tweet), posted by notifyLayoutChanged()
func translateTweet(id: String, completion: @escaping (Result<Translation, Error>) -> Void)
func translateUser(id: String, completion: @escaping (Result<Translation, Error>) -> Void)
```

`TweetActions.toggleTranslation(_ tweet: Tweet)` (Components): already translated → flip `showsTranslation`; else set
`isTranslating`, call the relay, store `translation`, set `showsTranslation = true`; a failure shows a Toast. Every
change ends with `tweet.notifyLayoutChanged()`.

Rows (`TweetCell`, `FocalTweetCell`): for a post with `translatable`, directly under the text (2 pt gap) one line,
15 pt (13 pt in list rows), accent, 22 pt high (18 in list rows):

| state | line | text shown above it |
|---|---|---|
| not translated | `ポストを翻訳` | original |
| loading | `翻訳中…` (secondaryText) | original |
| translation shown | `<source_lang_name>からGoogleによる翻訳 · 原文を表示` — the first part secondaryText, `原文を表示` accent (provider name from the answer) | the translation (with its entities) |
| translation hidden again | `翻訳を表示` | original |

The line is its own touch target (it does not open the post). `TimelineViewController` observes
`Tweet.layoutDidChange`: it clears the layout cache of the rows showing that post and reloads them without
animation jumps (`UIView.performWithoutAnimation { tableView.beginUpdates(); tableView.endUpdates() }` after
re-configuring the visible cell, or `reloadRows(at:with: .none)`).

Profile header: under the bio, for `bioTranslatable`, the same line with `自己紹介を翻訳` / `翻訳中…` /
`<source_lang_name>からGoogleによる翻訳 · 原文を表示` / `翻訳を表示`; the header height follows.

Demo: `/v2/tweet/translate` and `/v2/user/translate` answer `demo_translate.json`; the demo home timeline gets one
English post (`translatable: true`, id `2122000000000000090`, second item) and the demo detail's focal post stays as
it is. Debug step `translate:<id>` (Components) calls `TweetActions.toggleTranslation`.

## 8. Large screens (iPad, as in the official Android app on tablets)

What the official Android app (12.43) does on a tablet, read from the APK: there is **no tablet-only layout** — no
navigation rail, no second pane, no tablet layout resources. It keeps the phone structure (top bar, home tabs, bottom
bar, drawer, floating compose button) and, behind the switch `android_large_screens_horizontal_inset_enabled`, insets
the content horizontally on large screens so that it reads as one centred column. Bottom sheets keep the Material
maximum width of 640 dp. This app does the same. The target device is the iPad mini 2 (iOS 12, 768×1024 pt portrait,
1024×768 landscape, 20 pt status bar, no home indicator).

### 8.1 Orientation and multitasking

- iPad: all four orientations (`UISupportedInterfaceOrientations~ipad`: portrait, portrait upside down, landscape
  left, landscape right). iPhone / iPod touch: portrait only, as now.
- `UIRequiresFullScreen = YES` (no Slide Over / Split View; the iPad mini 2 has no Split View anyway). So on an iPad
  the window is always the full screen.
- Every screen must lay out again when its bounds change (frames only, from `viewDidLayoutSubviews` /
  `layoutSubviews`, never from `UIScreen` sizes and never cached from the first layout). Presented controllers
  (compose, media viewer, settings at first launch, sheets, the drawer) rotate with the app.
- `-xr-size WxH` (CI): the preview window stays centred on the screen after a rotation (re-centre it when the
  screen bounds change), with the same 20 pt top safe area.

### 8.2 The content column

```swift
extension Metrics {
    /// The widest the content column gets (X's own reading width).
    static let columnMaxWidth: CGFloat = 600
    /// True for a "large screen": the view is at least 600 pt wide (iPad in both orientations; never an iPhone).
    static func isLarge(_ width: CGFloat) -> Bool
    /// The column inside `bounds`: full width below 600 + 2 × 16 pt, otherwise 600 pt wide, centred, rounded to
    /// whole points. Height and y are those of `bounds`.
    static func column(in bounds: CGRect) -> CGRect
}
```

- `MainViewController` places the selected tab's navigation view in `Metrics.column(in: contentFrame)` instead of
  the full width. Everything pushed on a tab (home, detail, profile, search, notifications, messages, settings,
  history, lists) therefore lays out for a 600 pt wide view and needs no change of its own; on a 320/375 pt phone the
  column is the full width and nothing changes (the 320 pt CI shots must stay pixel-identical in layout).
- The two side gutters are `palette.background` with one hairline (`palette.separator`) along each edge of the column
  from the top of the screen down to the bottom bar (like X on the web). The status bar area of the gutters is the
  same background, so the top bar reads as one band.
- `BottomBarView` keeps its full-width background and top hairline, but its four buttons share the column's width
  (centred), not the screen's.
- Because the column is 600 pt in both orientations, rotating an iPad does not change any row height: rotation only
  changes how many rows are visible.

### 8.3 Other surfaces

- **Drawer**: unchanged rule `min(width × 0.85, 300)` → 300 pt from the left edge of the screen; the dimming covers
  the whole screen.
- **Bottom sheets** (`BottomSheet`, `ThemeSheet`, the repost / share / overflow menus): at most 640 pt wide, centred
  horizontally at the bottom of the screen; only the top two corners are rounded, as now. The
  dimming covers the whole screen.
- **Compose** (`ComposeViewController`, full screen): its top bar spans the screen; the text area, the media strip,
  the reply context and the bottom tool row are laid out in `Metrics.column(in:)` of its view (the tool row's
  background may span the screen, its buttons stay in the column). The keyboard handling is unchanged (frames in
  window coordinates converted to the view).
- **Media viewer**: full screen in every orientation. On a bounds change the paging scroll keeps the current page
  (content size, page frames and offset recomputed), each page resets its zoom and fits the photo to the new size.
  The bottom action row is centred and at most 600 pt wide.
- **Toasts**: at most 600 pt wide, centred above the bottom bar.
- **Dialogs** (`UIAlertController`): style `.alert` only, so no popover anchor is needed; any `.actionSheet` or
  `UIActivityViewController` must set `popoverPresentationController.sourceView/sourceRect` (§5 share note).
- **Settings at first launch** (presented full screen): its content in the column like the tab screens (it is a
  `BaseViewController` inside an `XNavigationController` presented full screen — place the presented navigation
  view's content in the column the same way, e.g. `XNavigationController` lays out its top view controller in
  `Metrics.column(in:)` when it is presented, or the settings screen insets itself).
- Floating compose button (home): 16 pt from the column's right edge (it is inside the column already).

### 8.4 Type

The official app scales a few Compose text styles by the smallest screen width (`Sw600`, `Sw720` steps), but the
timeline keeps its phone sizes. This app keeps the phone sizes of §1 on the iPad.

### 8.5 CI

A second simulator (an iPad whose landscape screen is at least 1024×768 pt, e.g. "iPad (10th generation)" or
"iPad (A16)") takes iPad shots with `-xr-size 1024x768` (landscape) and `-xr-size 768x1024` (portrait). Debug step
`orient:<portrait|landscape>` rotates the device (`UIDevice.current.setValue(<orientation>.rawValue, forKey:
"orientation")` + `UIViewController.attemptRotationToDeviceOrientation()`). The simulator stays rotated between
launches, so the iPad group rotates first and returns to portrait at its end. Landscape screenshots from
`simctl io screenshot` are saved rotated by 90°; the reader turns them back.

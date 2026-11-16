import UIKit

/// Something whose list scrolls to the top, or reloads when it is already there (a tab's root screen).
protocol TabRootScrollable: AnyObject {
    func scrollToTopOrRefresh()
}

/// The four tabs with the custom bottom bar (ui-spec §2.2). Each tab keeps its own navigation stack.
final class MainViewController: UIViewController {
    /// The main controller of the window, set when its view loads.
    static var current: MainViewController?

    enum Tab: Int {
        case home, search, notifications, messages
    }

    private let bottomBar = BottomBarView()
    /// Created on first selection and kept, so every tab keeps its stack.
    private var navigations: [Tab: XNavigationController] = [:]
    private var shownTab: Tab = .home
    /// The navigation controller whose view is in the hierarchy.
    private var shownNavigation: XNavigationController?
    private var badgeTimer: Timer?

    var selectedTab: Tab {
        get { return shownTab }
        set { select(newValue) }
    }

    var currentNavigation: XNavigationController {
        return navigation(for: shownTab)
    }

    /// True when the selected tab shows its root screen (only then does the edge swipe open the drawer).
    var isAtRoot: Bool {
        return currentNavigation.viewControllers.count <= 1
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // a newer root may have taken over `current` already
        if MainViewController.current === self {
            MainViewController.current = nil
        }
        badgeTimer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        MainViewController.current = self
        view.backgroundColor = Theme.palette.background
        bottomBar.onSelect = { [weak self] index in
            guard let tab = Tab(rawValue: index) else { return }
            self?.select(tab)
        }
        view.addSubview(bottomBar)
        select(.home)
        updateBadges()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateBadges), name: Session.didUpdate, object: nil)
        center.addObserver(self, selector: #selector(refreshBadges),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(startBadgeTimer),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(stopBadgeTimer),
                           name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let barHeight = Metrics.bottomBarHeight + view.safeAreaInsets.bottom
        bottomBar.frame = CGRect(x: 0, y: view.bounds.height - barHeight, width: view.bounds.width, height: barHeight)
        shownNavigation?.view.frame = contentFrame
    }

    // MARK: - tabs

    /// Shows a tab. Selecting the tab that is shown already pops its stack to the root, or, at the root,
    /// scrolls the root to the top.
    func select(_ tab: Tab) {
        loadViewIfNeeded()
        if tab == shownTab, shownNavigation != nil {
            resetTab(currentNavigation)
            return
        }
        if let previous = shownNavigation {
            hide(previous)
        }
        shownTab = tab
        show(currentNavigation)
        bottomBar.setSelectedIndex(tab.rawValue)
        if tab == .notifications {
            // the bell badge counts what has not been seen yet
            Session.shared.badges.notifications = 0
            updateBadges()
        }
    }

    private func resetTab(_ navigation: XNavigationController) {
        if navigation.viewControllers.count > 1 {
            navigation.popToRootViewController(animated: true)
        } else if let root = navigation.viewControllers.first as? TabRootScrollable {
            root.scrollToTopOrRefresh()
        }
    }

    private func navigation(for tab: Tab) -> XNavigationController {
        if let existing = navigations[tab] {
            return existing
        }
        let root: UIViewController
        switch tab {
        case .home:
            root = HomeViewController()
        case .search:
            root = SearchViewController()
        case .notifications:
            root = NotificationsViewController()
        case .messages:
            root = MessagesViewController()
        }
        let navigation = XNavigationController(rootViewController: root)
        navigations[tab] = navigation
        return navigation
    }

    /// Adds a tab's controller with its appearance callbacks, below the bottom bar.
    private func show(_ navigation: XNavigationController) {
        navigation.beginAppearanceTransition(true, animated: false)
        addChild(navigation)
        navigation.view.frame = contentFrame
        view.insertSubview(navigation.view, belowSubview: bottomBar)
        navigation.didMove(toParent: self)
        navigation.endAppearanceTransition()
        shownNavigation = navigation
    }

    /// Removes a tab's view; its stack stays alive in `navigations`.
    private func hide(_ navigation: XNavigationController) {
        navigation.beginAppearanceTransition(false, animated: false)
        navigation.willMove(toParent: nil)
        navigation.view.removeFromSuperview()
        navigation.removeFromParent()
        navigation.endAppearanceTransition()
        shownNavigation = nil
    }

    /// Everything above the bottom bar, which includes the bottom safe area.
    private var contentFrame: CGRect {
        let height = view.bounds.height - Metrics.bottomBarHeight - view.safeAreaInsets.bottom
        return CGRect(x: 0, y: 0, width: view.bounds.width, height: max(0, height))
    }

    // MARK: - badges

    @objc private func updateBadges() {
        bottomBar.setBadges(notifications: Session.shared.badges.notifications,
                            messages: Session.shared.badges.messages)
    }

    /// The counts are refreshed when the app comes back, and every 60 s while it is active.
    @objc private func refreshBadges() {
        Session.shared.refreshBadges()
    }

    @objc private func startBadgeTimer() {
        badgeTimer?.invalidate()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshBadges()
        }
    }

    @objc private func stopBadgeTimer() {
        badgeTimer?.invalidate()
        badgeTimer = nil
    }
}

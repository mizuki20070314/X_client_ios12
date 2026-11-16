import UIKit

/// The root of the window (ui-spec §2.1): the main UI, a dimming view and the navigation drawer on top.
final class RootContainerViewController: UIViewController, UIGestureRecognizerDelegate {
    /// The window's root, set when its view loads.
    static var current: RootContainerViewController?

    let main = MainViewController()
    let drawer = DrawerViewController()
    /// The left-edge swipe that opens the drawer.
    private(set) var edgePanGesture: UIScreenEdgePanGestureRecognizer?
    /// True while the drawer is open or opening to the open state.
    private(set) var isDrawerOpen = false

    private let dimmingView = UIView()
    /// 0 when the drawer is closed, 1 when it is fully open.
    private var drawerProgress: CGFloat = 0
    private var panStartProgress: CGFloat = 0
    private var hasStarted = false

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return Theme.statusBarStyle
    }

    // The status bar follows this controller, not the main UI or the drawer.
    override var childForStatusBarStyle: UIViewController? {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        RootContainerViewController.current = self
        view.backgroundColor = Theme.palette.background

        addChild(main)
        view.addSubview(main.view)
        main.didMove(toParent: self)

        dimmingView.backgroundColor = Theme.palette.overlay
        dimmingView.alpha = 0
        // the dimming takes touches only while the drawer is open, otherwise it would block the main UI
        dimmingView.isUserInteractionEnabled = false
        dimmingView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimmingTapped)))
        dimmingView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        view.addSubview(dimmingView)

        addChild(drawer)
        view.addSubview(drawer.view)
        drawer.didMove(toParent: self)
        drawer.view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))

        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        edge.edges = .left
        edge.delegate = self
        view.addGestureRecognizer(edge)
        edgePanGesture = edge

        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        main.view.frame = view.bounds
        dimmingView.frame = view.bounds
        layoutDrawer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        refreshSession()
        if !canUseRelay {
            presentInitialSetup()
        }
    }

    // MARK: - drawer

    /// Slides the drawer in over the main UI.
    func openDrawer() {
        guard !isDrawerOpen else { return }
        setDrawer(open: true, completion: nil)
    }

    /// Slides the drawer out. `completion` runs once it is closed, at once when it is closed already.
    func closeDrawer(completion: (() -> Void)? = nil) {
        guard isDrawerOpen || drawerProgress > 0 else {
            completion?()
            return
        }
        setDrawer(open: false, completion: completion)
    }

    private func setDrawer(open: Bool, completion: (() -> Void)?) {
        isDrawerOpen = open
        dimmingView.isUserInteractionEnabled = open
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.drawerProgress = open ? 1 : 0
            self.layoutDrawer()
        }, completion: { _ in
            completion?()
        })
    }

    /// The drawer is `drawerProgress` of the way in, and the dimming fades with it.
    private func layoutDrawer() {
        let width = drawerWidth
        drawer.view.frame = CGRect(x: -width + width * drawerProgress, y: 0,
                                   width: width, height: view.bounds.height)
        dimmingView.alpha = drawerProgress
    }

    /// `min(85 % of the width, 300)`, so the drawer never covers a whole 320 pt screen.
    private var drawerWidth: CGFloat {
        return min(view.bounds.width * 0.85, 300)
    }

    /// The finger moves the drawer. On release it opens or closes by speed, otherwise by how far it got.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let width = max(1, drawerWidth)
        switch gesture.state {
        case .began:
            panStartProgress = drawerProgress
        case .changed:
            let translation = gesture.translation(in: view).x
            drawerProgress = min(1, max(0, panStartProgress + translation / width))
            layoutDrawer()
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: view).x
            let opens: Bool
            if velocity > 300 {
                opens = true
            } else if velocity < -300 {
                opens = false
            } else {
                opens = drawerProgress > 0.5
            }
            setDrawer(open: opens, completion: nil)
        default:
            break
        }
    }

    @objc private func dimmingTapped() {
        closeDrawer(completion: nil)
    }

    /// The edge swipe opens the drawer on a root screen only, and only while the drawer is closed. On a pushed
    /// screen the same swipe means "back" (XNavigationController).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === edgePanGesture else { return true }
        return !isDrawerOpen && (MainViewController.current?.isAtRoot ?? true)
    }

    // MARK: - account

    /// The relay answers: it is configured, or the demo mode runs without one.
    private var canUseRelay: Bool {
        return RelayClient.shared.isConfigured || CoreEnvironment.isDemo
    }

    private func refreshSession() {
        if canUseRelay {
            Session.shared.refresh()
        }
    }

    @objc private func willEnterForeground() {
        refreshSession()
    }

    /// A first launch without a relay starts with the settings, full screen.
    private func presentInitialSetup() {
        let settings = SettingsViewController(isInitialSetup: true)
        let navigation = XNavigationController(rootViewController: settings)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true, completion: nil)
    }
}

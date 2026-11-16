import UIKit

/// The entry point: one plain window (no scenes), whose root comes from AppRoot.
@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    /// The `-xr-size` preview size (CI only); nil in a normal launch.
    private var previewSize: CGSize?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // first thing: every Core call from here on must already see the demo mode
        CoreEnvironment.isDemo = DebugFlags.isDemo
        DebugRoutes.applyEarlyArguments()
        previewSize = AppDelegate.parseSize(DebugFlags.value(for: "-xr-size"))

        let window = UIWindow(frame: AppDelegate.windowFrame(preview: previewSize))
        if previewSize != nil {
            window.backgroundColor = UIColor.black
        }
        window.rootViewController = makeRoot()
        window.makeKeyAndVisible()
        self.window = window

        // the theme is read when a root is built, so a theme change builds a new root
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: Notification.Name("ThemeDidChange"),
            object: nil
        )
        DebugRoutes.runIfRequested()
        return true
    }

    @objc private func themeDidChange() {
        window?.rootViewController = makeRoot()
    }

    private func makeRoot() -> UIViewController {
        let root = AppRoot.makeRootViewController()
        if previewSize != nil, #available(iOS 11.0, *) {
            // the iPod touch status bar is 20 pt high: the preview gets the same top safe area
            root.additionalSafeAreaInsets = UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
        }
        return root
    }

    /// `-xr-size WxH`: a window of that size, centred on the screen (the same trick as the reference project).
    private static func windowFrame(preview: CGSize?) -> CGRect {
        let screen = UIScreen.main.bounds
        guard let size = preview else { return screen }
        return CGRect(
            x: (screen.width - size.width) / 2,
            y: (screen.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func parseSize(_ text: String?) -> CGSize? {
        guard let text = text else { return nil }
        let parts = text.split(separator: "x").compactMap { Double(String($0)) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
}

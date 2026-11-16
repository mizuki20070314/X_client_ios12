import UIKit

/// The navigation stack of a tab or a modal flow. Its own bar stays hidden: every screen draws its top bar
/// (BaseViewController), so the look is the same on iOS 12 and iOS 18.
final class XNavigationController: UINavigationController, UIGestureRecognizerDelegate {
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return Theme.statusBarStyle
    }

    // The status bar follows this controller, not the screen on top of it.
    override var childForStatusBarStyle: UIViewController? {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setNavigationBarHidden(true, animated: false)
        // The swipe back needs a screen to go back to; on the root the edge swipe opens the drawer.
        interactivePopGestureRecognizer?.delegate = self
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return viewControllers.count > 1
    }
}

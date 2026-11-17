import UIKit

/// Base of every screen: the top bar at the top, and the content area below it. Screens place their own views
/// in `layoutContent()`, from `contentTop` down.
class BaseViewController: UIViewController {
    let topBar = TopBarView()

    /// False for a screen whose content starts at the very top.
    var showsTopBar: Bool {
        return true
    }

    /// An extra band below the bar, such as a tab strip. The screen places that view itself.
    var topBarAccessoryHeight: CGFloat {
        return 0
    }

    /// Where the content starts: below the status bar, the bar and the accessory band.
    var contentTop: CGFloat {
        guard showsTopBar else { return 0 }
        return view.safeAreaInsets.top + Metrics.topBarHeight + topBarAccessoryHeight
    }

    /// Every orientation on an iPad (ui-spec §8.1): a presented screen rotates with the app.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.palette.background
        view.addSubview(topBar)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // the bar also covers the status bar area
        topBar.isHidden = !showsTopBar
        topBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width,
                              height: view.safeAreaInsets.top + Metrics.topBarHeight)
        // views added after viewDidLoad must not cover the bar
        view.bringSubviewToFront(topBar)
        layoutContent()
    }

    /// Override: place the screen's views below `contentTop`. Called on every layout pass.
    func layoutContent() {
    }
}

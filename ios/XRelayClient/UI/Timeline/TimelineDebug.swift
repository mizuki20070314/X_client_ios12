import UIKit

/// Debug steps of the timeline (ui-spec.md §6), used by the CI screenshots.
enum TimelineDebug {
    static func registerDebugSteps() {
        // scroll:<points> — scrolls the visible timeline to that offset, clamped to its scrollable range
        DebugRoutes.register("scroll") { argument in
            guard let points = Double(argument), let timeline = TimelineDebug.visibleTimeline() else { return }
            let table = timeline.tableView
            let minY = -table.contentInset.top
            let maxY = max(minY, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
            let y = min(max(CGFloat(points), minY), maxY)
            table.setContentOffset(CGPoint(x: table.contentOffset.x, y: y), animated: false)
        }
    }

    /// The timeline on screen. The walk starts at the top-most presented controller; of a navigation stack only
    /// the top controller counts (the screens below a pushed one are covered), and the timeline must be on screen.
    static func visibleTimeline() -> TimelineViewController? {
        guard let window = keyWindow(), let root = window.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return firstVisibleTimeline(in: top, window: window)
    }

    private static func keyWindow() -> UIWindow? {
        if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            return window
        }
        return (UIApplication.shared.delegate as? AppDelegate)?.window
    }

    private static func firstVisibleTimeline(in controller: UIViewController,
                                             window: UIWindow) -> TimelineViewController? {
        if let timeline = controller as? TimelineViewController, isOnScreen(timeline.view, window: window) {
            return timeline
        }
        let children: [UIViewController]
        if let navigation = controller as? UINavigationController {
            children = navigation.topViewController.map { [$0] } ?? []
        } else {
            children = controller.children
        }
        for child in children {
            if let found = firstVisibleTimeline(in: child, window: window) {
                return found
            }
        }
        return nil
    }

    /// Attached to the window, not hidden on the way up, and inside the window's bounds (a pager's other pages
    /// are attached too, but off screen).
    private static func isOnScreen(_ view: UIView, window: UIWindow) -> Bool {
        guard view.window === window else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.01 {
                return false
            }
            ancestor = current.superview
        }
        let frame = view.convert(view.bounds, to: window)
        return frame.intersects(window.bounds)
    }
}

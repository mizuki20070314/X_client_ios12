import UIKit

/// The root screen of the app. Every part registers its debug steps first, then the root container is built.
enum AppRoot {
    static func makeRootViewController() -> UIViewController {
        ShellDebug.registerDebugSteps()
        ComponentsDebug.registerDebugSteps()
        TimelineDebug.registerDebugSteps()
        ScreensDebug.registerDebugSteps()
        return RootContainerViewController()
    }
}

import UIKit

/// The debug steps of the shell, for the CI screenshots (ui-spec §6, ui-wave2-notes.md). AppRoot registers them once.
enum ShellDebug {
    static func registerDebugSteps() {
        DebugRoutes.register("tab") { argument in
            guard let index = Int(argument), let tab = MainViewController.Tab(rawValue: index) else { return }
            MainViewController.current?.select(tab)
        }
        DebugRoutes.register("drawer") { _ in
            RootContainerViewController.current?.openDrawer()
        }
        DebugRoutes.register("settings") { _ in
            Router.openSettings()
        }
        DebugRoutes.register("history") { _ in
            Router.openHistory()
        }
        DebugRoutes.register("themesheet") { _ in
            ThemeSheet.present(from: Router.topViewController)
        }
        DebugRoutes.register("toast") { text in
            Toast.show(text)
        }
        DebugRoutes.register("userlist") { userID in
            Router.openUserList(userID: userID, followers: false)
        }
        DebugRoutes.register("mode") { argument in
            guard let index = Int(argument), let top = visibleTop() else { return }
            if let selectable = top as? ModeSelectable {
                selectable.selectMode(index)
            }
        }
    }

    /// The top-most visible controller: the presented ones first, then the selected tab's top screen.
    private static func visibleTop() -> UIViewController? {
        guard let top = Router.topViewController else { return nil }
        if let navigation = top as? UINavigationController {
            return navigation.topViewController ?? top
        }
        return top
    }
}

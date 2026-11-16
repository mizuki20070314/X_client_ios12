import UIKit

enum XTheme {
    static let blue = UIColor(red: 29.0 / 255, green: 155.0 / 255, blue: 240.0 / 255, alpha: 1)
    static let text = UIColor(red: 15.0 / 255, green: 20.0 / 255, blue: 25.0 / 255, alpha: 1)
    static let secondaryText = UIColor(red: 83.0 / 255, green: 100.0 / 255, blue: 113.0 / 255, alpha: 1)
    static let separator = UIColor(red: 239.0 / 255, green: 243.0 / 255, blue: 244.0 / 255, alpha: 1)
    static let avatarPlaceholder = UIColor(red: 207.0 / 255, green: 217.0 / 255, blue: 222.0 / 255, alpha: 1)

    static func symbol(_ name: String) -> UIImage? {
        if #available(iOS 13.0, *) {
            return UIImage(systemName: name)?.withRenderingMode(.alwaysTemplate)
        }
        return nil
    }
}

final class MainTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()

        UITabBar.appearance().tintColor = XTheme.blue
        UITabBar.appearance().barTintColor = .white
        UITabBar.appearance().isTranslucent = false
        UINavigationBar.appearance().tintColor = XTheme.blue
        UINavigationBar.appearance().barTintColor = .white
        UINavigationBar.appearance().isTranslucent = false
        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = .white
            appearance.titleTextAttributes = [.foregroundColor: XTheme.text]
            appearance.shadowColor = XTheme.separator
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        }

        let home = UINavigationController(rootViewController: TimelineViewController())
        home.tabBarItem = UITabBarItem(title: "ホーム", image: XTheme.symbol("house"), selectedImage: XTheme.symbol("house.fill"))
        let search = UINavigationController(rootViewController: SearchViewController())
        search.tabBarItem = UITabBarItem(title: "検索", image: XTheme.symbol("magnifyingglass"), selectedImage: XTheme.symbol("magnifyingglass"))
        let settings = UINavigationController(rootViewController: SettingsViewController())
        settings.tabBarItem = UITabBarItem(title: "設定", image: XTheme.symbol("gearshape"), selectedImage: XTheme.symbol("gearshape.fill"))
        viewControllers = [home, search, settings]
        tabBar.backgroundColor = .white
        tabBar.layer.borderColor = XTheme.separator.cgColor
        tabBar.layer.borderWidth = 0.5
    }
}

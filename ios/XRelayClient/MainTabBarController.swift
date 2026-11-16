import UIKit

enum XTheme {
    static let blue = UIColor(red: 29.0 / 255, green: 155.0 / 255, blue: 240.0 / 255, alpha: 1)
    static let background = adaptive(light: .white, dark: .black)
    static let text = adaptive(
        light: UIColor(red: 15.0 / 255, green: 20.0 / 255, blue: 25.0 / 255, alpha: 1),
        dark: .white
    )
    static let secondaryText = adaptive(
        light: UIColor(red: 83.0 / 255, green: 100.0 / 255, blue: 113.0 / 255, alpha: 1),
        dark: UIColor(red: 113.0 / 255, green: 118.0 / 255, blue: 123.0 / 255, alpha: 1)
    )
    static let separator = adaptive(
        light: UIColor(red: 239.0 / 255, green: 243.0 / 255, blue: 244.0 / 255, alpha: 1),
        dark: UIColor(white: 0.18, alpha: 1)
    )
    static let avatarPlaceholder = adaptive(
        light: UIColor(red: 207.0 / 255, green: 217.0 / 255, blue: 222.0 / 255, alpha: 1),
        dark: UIColor(white: 0.25, alpha: 1)
    )

    private static func adaptive(light: UIColor, dark: UIColor) -> UIColor {
        if #available(iOS 13.0, *) {
            return UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
        }
        return light
    }

    static func symbol(_ name: String) -> UIImage? {
        if #available(iOS 13.0, *) {
            if let image = UIImage(systemName: name) {
                return image.withRenderingMode(.alwaysTemplate)
            }
        }
        let glyphs = [
            "house": "⌂", "house.fill": "⌂", "magnifyingglass": "⌕",
            "gearshape": "⚙", "gearshape.fill": "⚙", "bell": "♧", "bell.fill": "♧",
            "envelope": "✉", "envelope.fill": "✉", "plus": "＋", "bubble": "◌",
            "arrow.2.squarepath": "↻", "heart": "♡", "heart.fill": "♥",
            "chart.bar": "▥", "square.and.arrow.up": "↑"
        ]
        guard let glyph = glyphs[name] else { return nil }
        let size = CGSize(width: 24, height: 24)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 20, weight: .regular),
            .foregroundColor: UIColor.black
        ]
        let glyphSize = (glyph as NSString).size(withAttributes: attributes)
        let rect = CGRect(
            x: (size.width - glyphSize.width) / 2,
            y: (size.height - glyphSize.height) / 2,
            width: glyphSize.width,
            height: glyphSize.height
        )
        (glyph as NSString).draw(in: rect, withAttributes: attributes)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return image?.withRenderingMode(.alwaysTemplate)
    }
}

final class MainTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()

        UITabBar.appearance().tintColor = XTheme.blue
        UITabBar.appearance().barTintColor = XTheme.background
        UITabBar.appearance().isTranslucent = false
        UINavigationBar.appearance().tintColor = XTheme.blue
        UINavigationBar.appearance().barTintColor = XTheme.background
        UINavigationBar.appearance().isTranslucent = false
        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = XTheme.background
            appearance.titleTextAttributes = [.foregroundColor: XTheme.text]
            appearance.shadowColor = XTheme.separator
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        }

        let home = UINavigationController(rootViewController: TimelineViewController())
        home.tabBarItem = UITabBarItem(title: "ホーム", image: XTheme.symbol("house"), selectedImage: XTheme.symbol("house.fill"))
        let search = UINavigationController(rootViewController: SearchViewController())
        search.tabBarItem = UITabBarItem(title: "検索", image: XTheme.symbol("magnifyingglass"), selectedImage: XTheme.symbol("magnifyingglass"))
        let notifications = UINavigationController(rootViewController: FeatureUnavailableViewController(
            title: "通知",
            symbolName: "bell",
            message: "通知の取得は、現在のリレーCGIではまだ利用できません。"
        ))
        notifications.tabBarItem = UITabBarItem(title: "通知", image: XTheme.symbol("bell"), selectedImage: XTheme.symbol("bell.fill"))
        let messages = UINavigationController(rootViewController: FeatureUnavailableViewController(
            title: "メッセージ",
            symbolName: "envelope",
            message: "ダイレクトメッセージは、現在のリレーCGIではまだ利用できません。"
        ))
        messages.tabBarItem = UITabBarItem(title: "メッセージ", image: XTheme.symbol("envelope"), selectedImage: XTheme.symbol("envelope.fill"))
        let settings = UINavigationController(rootViewController: SettingsViewController())
        settings.tabBarItem = UITabBarItem(title: "設定", image: XTheme.symbol("gearshape"), selectedImage: XTheme.symbol("gearshape.fill"))
        viewControllers = [home, search, notifications, messages, settings]
        tabBar.backgroundColor = XTheme.background
        tabBar.layer.borderColor = XTheme.separator.cgColor
        tabBar.layer.borderWidth = 0.5
    }
}

private final class FeatureUnavailableViewController: UIViewController {
    private let screenTitle: String
    private let symbolName: String
    private let message: String

    init(title: String, symbolName: String, message: String) {
        screenTitle = title
        self.symbolName = symbolName
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = screenTitle
        view.backgroundColor = XTheme.background

        let icon = UIImageView(image: XTheme.symbol(symbolName))
        icon.tintColor = XTheme.secondaryText
        icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let heading = UILabel()
        heading.text = screenTitle
        heading.font = UIFont.boldSystemFont(ofSize: 20)
        heading.textColor = XTheme.text
        heading.textAlignment = .center

        let detail = UILabel()
        detail.text = message
        detail.font = UIFont.systemFont(ofSize: 15)
        detail.textColor = XTheme.secondaryText
        detail.textAlignment = .center
        detail.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, heading, detail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        ])
    }
}

import UIKit

/// Drives the UI for the CI screenshots: `-xr-theme` sets the theme before the first screen is built, and
/// `-xr-route "step;step;…"` runs steps after launch. Screens register their own steps with `register`.
enum DebugRoutes {
    private static var handlers: [String: (String) -> Void] = [:]

    /// Writes the theme before the UI is built. light → 0, dim → 1, black → 2 (the `themeMode` key of Theme).
    static func applyEarlyArguments() {
        guard let theme = DebugFlags.value(for: "-xr-theme") else { return }
        let modes = ["light": 0, "dim": 1, "black": 2]
        if let mode = modes[theme] {
            UserDefaults.standard.set(mode, forKey: "themeMode")
        }
    }

    /// Registers a step. The step runs with the argument after the colon, e.g. "tweet:2122…" calls the "tweet" step.
    static func register(_ name: String, _ handler: @escaping (String) -> Void) {
        handlers[name] = handler
    }

    /// Runs the steps of `-xr-route` one after another: the first 1 s after launch, then 0.4 s apart.
    /// `wait:<seconds>` adds a pause. Unknown steps are ignored.
    static func runIfRequested() {
        guard let route = DebugFlags.value(for: "-xr-route") else { return }
        registerBuiltInSteps()
        var delay = 1.0
        for raw in route.split(separator: ";") {
            let step = String(raw)
            if step.hasPrefix("wait:"), let seconds = Double(step.dropFirst(5)) {
                delay += seconds
                continue
            }
            let parts = step.split(separator: ":", maxSplits: 1).map { String($0) }
            let name = parts.first ?? ""
            let argument = parts.count > 1 ? parts[1] : ""
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                DebugRoutes.run(name, argument)
            }
            delay += 0.4
        }
    }

    private static func run(_ name: String, _ argument: String) {
        guard let handler = handlers[name] else { return }
        handler(argument)
    }

    private static func registerBuiltInSteps() {
        register("icons") { _ in
            DebugRoutes.presentIconGallery()
        }
    }

    /// The icon gallery, full screen, over whatever is shown on top.
    private static func presentIconGallery() {
        let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow })
            ?? (UIApplication.shared.delegate as? AppDelegate)?.window
        guard let root = window?.rootViewController else { return }
        let top = topMost(from: root)
        let gallery = IconGalleryViewController()
        gallery.modalPresentationStyle = .fullScreen
        top.present(gallery, animated: false, completion: nil)
    }

    private static func topMost(from controller: UIViewController) -> UIViewController {
        var top = controller
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

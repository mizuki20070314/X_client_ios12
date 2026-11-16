import Foundation

/// Launch arguments that the CI screenshots use (docs/ios-design.md §2). They do nothing in a normal launch.
enum DebugFlags {
    /// `-xr-demo`: no network, the relay client answers from the bundled demo JSON.
    static let isDemo: Bool = flag("-xr-demo")

    /// The argument after `key`, e.g. "light" for "-xr-theme light". nil when the key or its value is missing.
    static func value(for key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    static func flag(_ key: String) -> Bool {
        return ProcessInfo.processInfo.arguments.contains(key)
    }
}

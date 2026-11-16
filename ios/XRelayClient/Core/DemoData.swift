import Foundation

/// Answers of the relay API from the bundled files (Resources/Demo, written by tools/make_demo_data.py). Used when
/// CoreEnvironment.isDemo is set: nothing touches the network, and the JSON has the shapes of api-v2.md.
enum DemoData {
    /// The answer for a request path such as "/v2/home", or nil for an unknown route.
    static func response(path: String, query: [String: String]) -> Data? {
        let cursored = query["cursor"] != nil
        switch path {
        case "/v2/me":
            return file("me")
        case "/v2/badges":
            return file("badges")
        case "/v2/home":
            if cursored { return file("home_page2") }
            return file(query["tab"] == "following" ? "home_following" : "home_foryou")
        case "/v2/tweet":
            // the demo has one detail file; a "more" row asks for the next page, which the demo answers empty
            if cursored { return emptyPage }
            return file("tweet_" + (query["id"] ?? "")) ?? file("tweet_default")
        case "/v2/search":
            if cursored { return emptyPage }
            return file("search_" + (query["mode"] ?? "top"))
        case "/v2/user":
            if let handle = query["handle"], let data = file("user_" + handle) {
                return data
            }
            return file("user_default")
        case "/v2/user/timeline":
            if cursored { return emptyPage }
            return file("user_timeline_" + (query["tab"] ?? "posts"))
        case "/v2/user/follows":
            if cursored { return emptyPage }
            return file("user_follows")
        case "/v2/notifications":
            if cursored { return emptyPage }
            return file(query["tab"] == "mentions" ? "notifications_mentions" : "notifications_all")
        case "/v2/bookmarks":
            if cursored { return emptyPage }
            return file("bookmarks")
        case "/v2/explore":
            return file("explore")
        case "/v2/tweet/create":
            return Data("{\"ok\":true,\"tweet\":null}".utf8)
        case "/v2/tweet/delete", "/v2/tweet/like", "/v2/tweet/retweet", "/v2/tweet/bookmark",
             "/v2/user/follow", "/v2/user/mute", "/v2/user/block":
            return Data("{\"ok\":true}".utf8)
        default:
            return nil
        }
    }

    private static let emptyPage = Data("{\"items\":[],\"top\":null,\"bottom\":null}".utf8)

    /// demo_<name>.json from the bundle, with its times moved to the present. `name` may come from a request, so
    /// only plain names are read.
    private static func file(_ name: String) -> Data? {
        guard isPlainName(name),
              let url = Bundle.main.url(forResource: "demo_" + name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return shiftedTimes(data) ?? data
    }

    private static func isPlainName(_ name: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return !name.isEmpty && name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// created_at and time are written relative to the file's "_base" epoch. Moving them by (now - _base) keeps
    /// "3分" at "3分" whenever the app runs. Other times (joined, ends_at) are absolute and stay as they are.
    private static func shiftedTimes(_ data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = root as? [String: Any],
              let base = (object["_base"] as? NSNumber)?.intValue else {
            return nil
        }
        let delta = Int(Date().timeIntervalSince1970) - base
        return try? JSONSerialization.data(withJSONObject: shift(object, by: delta), options: [])
    }

    private static func shift(_ value: Any, by delta: Int) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, item) in dictionary {
                if key == "created_at" || key == "time", let seconds = item as? NSNumber {
                    result[key] = NSNumber(value: seconds.intValue + delta)
                } else {
                    result[key] = shift(item, by: delta)
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { shift($0, by: delta) }
        }
        return value
    }
}

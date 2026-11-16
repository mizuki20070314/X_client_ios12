import Foundation

/// The logged-in account and its badge counts. The last /v2/me answer is kept as JSON text, so the avatar and the
/// name are there at the next launch, before the network has answered.
final class Session {
    static let shared = Session()
    static let didUpdate = Notification.Name("SessionDidUpdate")

    private static let cacheKey = "cachedMe"

    var me: User?
    var badges = Badges(notifications: 0, messages: 0)

    private init() {
        guard let text = UserDefaults.standard.string(forKey: Session.cacheKey),
              let data = text.data(using: .utf8) else {
            return
        }
        let json = JSON(data: data)
        if let user = User(json: json["user"]) {
            me = TweetStore.shared.intern(user)
        }
        badges = Badges(json: json["badges"])
    }

    /// Calls /v2/me, keeps the answer and reports the change. Failures leave the cached account in place.
    func refresh() {
        RelayClient.shared.fetchMe { result in
            guard case .success(let json) = result, let user = User(json: json["user"]) else { return }
            if let raw = json.raw, let data = try? JSONSerialization.data(withJSONObject: raw, options: []) {
                UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: Session.cacheKey)
            }
            self.me = TweetStore.shared.intern(user)
            self.badges = Badges(json: json["badges"])
            NotificationCenter.default.post(name: Session.didUpdate, object: self)
        }
    }

    func refreshBadges() {
        RelayClient.shared.badges { result in
            guard case .success(let value) = result else { return }
            self.badges = value
            NotificationCenter.default.post(name: Session.didUpdate, object: self)
        }
    }
}

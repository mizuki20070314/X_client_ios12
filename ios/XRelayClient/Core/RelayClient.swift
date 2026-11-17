import Foundation

/// Set first thing by the App layer (AppDelegate). Core cannot read DebugFlags itself, so the flag is passed in.
enum CoreEnvironment {
    static var isDemo = false
}

enum SearchMode: String { case top, latest, people, media }
enum UserTab: String { case posts, replies, media, likes }

enum TimelineSource: Equatable {
    case home(following: Bool)
    case tweet(id: String)
    case search(query: String, mode: SearchMode)
    case userTimeline(userID: String, tab: UserTab)
    case follows(userID: String, followers: Bool)
    case notifications(mentions: Bool)
    case bookmarks
}

/// The relay client: the settings (storage identical to v1) and the v2 requests of api-v2.md.
/// Completions run on the main queue. A cancelled request calls nothing.
final class RelayClient {
    static let shared = RelayClient()
    private static let defaultBaseURL = URL(string: "http://localhost:3000")!

    // settings: the same UserDefaults keys and Keychain item as v1, so existing settings survive the update

    var baseURL: URL {
        get { UserDefaults.standard.url(forKey: "relayURL") ?? Self.defaultBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: "relayURL") }
    }

    var isConfigured: Bool {
        UserDefaults.standard.url(forKey: "relayURL") != nil
    }

    var profileName: String? {
        get { UserDefaults.standard.string(forKey: "profileName") }
        set { UserDefaults.standard.set(newValue, forKey: "profileName") }
    }

    private(set) var configurationRevision = 0
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        // API answers are never cached (the relay also sends Cache-Control: no-store)
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func loadBearerToken() throws -> String? {
        try KeychainTokenStore.load()
    }

    func saveSettings(baseURL: URL, profileName: String?, bearerToken: String?) throws {
        let trimmedToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        try KeychainTokenStore.save(trimmedToken?.isEmpty == true ? nil : trimmedToken)
        self.baseURL = baseURL
        let trimmedProfile = profileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profileName = trimmedProfile?.isEmpty == true ? nil : trimmedProfile
        configurationRevision += 1
    }

    /// GET <base>/profiles with the given settings (the v1 connection test, not the stored settings).
    func testConnection(
        baseURL: URL,
        profileName: String?,
        bearerToken: String?,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        if CoreEnvironment.isDemo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { completion(.success(["demo"])) }
            return
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("profiles"))
        request.httpMethod = "GET"
        Self.addHeaders(to: &request, profileName: profileName, bearerToken: bearerToken)
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(APIError.network(error.localizedDescription))) }
                return
            }
            guard let data = data, let response = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(APIError.invalidResponse)) }
                return
            }
            guard (200..<300).contains(response.statusCode) else {
                let failure = Self.legacyError(statusCode: response.statusCode, data: data)
                DispatchQueue.main.async { completion(.failure(failure)) }
                return
            }
            let json = JSON(data: data)
            let result: Result<[String], Error>
            if let profiles = json["profiles"].raw as? [String] {
                result = .success(profiles)
            } else {
                result = .failure(APIError.invalidResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
    }

    // MARK: - reads

    @discardableResult
    func timeline(
        _ source: TimelineSource,
        cursor: String?,
        completion: @escaping (Result<TimelinePage, Error>) -> Void
    ) -> URLSessionTask? {
        let route = Self.route(for: source, cursor: cursor)
        return perform(method: "GET", path: route.path, query: route.query, body: nil) { result in
            completion(result.map { TimelinePage(json: $0) })
        }
    }

    func explore(tab: String?, completion: @escaping (Result<ExplorePage, Error>) -> Void) {
        var query: [String: String] = [:]
        if let tab = tab {
            query["tab"] = tab
        }
        perform(method: "GET", path: "/v2/explore", query: query, body: nil) { result in
            completion(result.map { ExplorePage(json: $0) })
        }
    }

    func me(completion: @escaping (Result<(user: User, badges: Badges), Error>) -> Void) {
        fetchMe { result in
            switch result {
            case .success(let json):
                guard let user = User(json: json["user"]) else {
                    completion(.failure(APIError.invalidResponse))
                    return
                }
                let value = (user: TweetStore.shared.intern(user), badges: Badges(json: json["badges"]))
                completion(.success(value))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// The raw /v2/me answer. Session keeps it for the next launch.
    func fetchMe(completion: @escaping (Result<JSON, Error>) -> Void) {
        perform(method: "GET", path: "/v2/me", query: [:], body: nil, completion: completion)
    }

    func badges(completion: @escaping (Result<Badges, Error>) -> Void) {
        perform(method: "GET", path: "/v2/badges", query: [:], body: nil) { result in
            completion(result.map { Badges(json: $0) })
        }
    }

    func user(handle: String, completion: @escaping (Result<User, Error>) -> Void) {
        perform(method: "GET", path: "/v2/user", query: ["handle": handle], body: nil) { result in
            completion(Self.userResult(result))
        }
    }

    func user(id: String, completion: @escaping (Result<User, Error>) -> Void) {
        perform(method: "GET", path: "/v2/user", query: ["id": id], body: nil) { result in
            completion(Self.userResult(result))
        }
    }

    // MARK: - translation (api-v2.md §4): "not_found" when X has no translation

    func translateTweet(id: String, completion: @escaping (Result<Translation, Error>) -> Void) {
        perform(method: "GET", path: "/v2/tweet/translate", query: ["id": id], body: nil) { result in
            completion(Self.translationResult(result))
        }
    }

    func translateUser(id: String, completion: @escaping (Result<Translation, Error>) -> Void) {
        perform(method: "GET", path: "/v2/user/translate", query: ["id": id], body: nil) { result in
            completion(Self.translationResult(result))
        }
    }

    // MARK: - writes (`on: false` undoes the action; repeating an action in effect is a success)

    func setLike(tweetID: String, on: Bool, completion: @escaping (Error?) -> Void) {
        action("/v2/tweet/like", body: ["id": tweetID, "on": on], completion: completion)
    }

    func setRetweet(tweetID: String, on: Bool, completion: @escaping (Error?) -> Void) {
        action("/v2/tweet/retweet", body: ["id": tweetID, "on": on], completion: completion)
    }

    func setBookmark(tweetID: String, on: Bool, completion: @escaping (Error?) -> Void) {
        action("/v2/tweet/bookmark", body: ["id": tweetID, "on": on], completion: completion)
    }

    func setFollow(userID: String, on: Bool, completion: @escaping (Error?) -> Void) {
        action("/v2/user/follow", body: ["id": userID, "on": on], completion: completion)
    }

    func setMute(userID: String, on: Bool, completion: @escaping (Error?) -> Void) {
        action("/v2/user/mute", body: ["id": userID, "on": on], completion: completion)
    }

    func setBlock(userID: String, on: Bool, completion: @escaping (Error?) -> Void) {
        action("/v2/user/block", body: ["id": userID, "on": on], completion: completion)
    }

    func createTweet(
        text: String,
        replyTo: String?,
        quote: String?,
        completion: @escaping (Result<Tweet?, Error>) -> Void
    ) {
        let body: [String: Any] = [
            "text": text,
            "reply_to": Self.optionalValue(replyTo),
            "quote": Self.optionalValue(quote),
            "media_ids": [String]()
        ]
        perform(method: "POST", path: "/v2/tweet/create", query: [:], body: body) { result in
            switch result {
            case .success(let json):
                if let refusal = Self.refusal(json) {
                    completion(.failure(refusal))
                    return
                }
                let tweet = Tweet(json: json["tweet"]).map { TweetStore.shared.intern($0) }
                completion(.success(tweet))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func deleteTweet(id: String, completion: @escaping (Error?) -> Void) {
        action("/v2/tweet/delete", body: ["id": id], completion: completion)
    }

    // MARK: - requests

    private func action(_ path: String, body: [String: Any], completion: @escaping (Error?) -> Void) {
        perform(method: "POST", path: path, query: [:], body: body) { result in
            switch result {
            case .success(let json):
                completion(Self.refusal(json))
            case .failure(let error):
                completion(error)
            }
        }
    }

    /// One request of the v2 API (api-v2.md §1). Demo mode answers from DemoData after 0.05 s.
    @discardableResult
    private func perform(
        method: String,
        path: String,
        query: [String: String],
        body: [String: Any]?,
        completion: @escaping (Result<JSON, Error>) -> Void
    ) -> URLSessionTask? {
        if CoreEnvironment.isDemo {
            let result: Result<JSON, Error>
            if let data = DemoData.response(path: path, query: query) {
                result = .success(JSON(data: data))
            } else {
                result = .failure(APIError.notFound("デモデータがありません。（\(path)）"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { completion(result) }
            return nil
        }
        guard isConfigured else {
            DispatchQueue.main.async { completion(.failure(APIError.notConfigured)) }
            return nil
        }
        let url: URL
        do {
            url = try Self.makeURL(baseURL: baseURL, path: path, query: query)
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body = body {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return nil
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        Self.addHeaders(to: &request, profileName: profileName, bearerToken: try? loadBearerToken())
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                if (error as NSError).code == NSURLErrorCancelled { return }
                DispatchQueue.main.async { completion(.failure(APIError.network(error.localizedDescription))) }
                return
            }
            guard let data = data, let response = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(APIError.invalidResponse)) }
                return
            }
            guard (200..<300).contains(response.statusCode) else {
                let failure = Self.apiError(statusCode: response.statusCode, data: data)
                DispatchQueue.main.async { completion(.failure(failure)) }
                return
            }
            // parsed here, off the main queue; the models are built by the completion on the main queue
            let json = JSON(data: data)
            let result: Result<JSON, Error> = json.exists ? .success(json) : .failure(APIError.invalidResponse)
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }

    // MARK: - helpers

    private static func route(for source: TimelineSource, cursor: String?) -> (path: String, query: [String: String]) {
        var query: [String: String] = [:]
        let path: String
        switch source {
        case .home(let following):
            path = "/v2/home"
            query["tab"] = following ? "following" : "foryou"
        case .tweet(let id):
            path = "/v2/tweet"
            query["id"] = id
        case .search(let text, let mode):
            path = "/v2/search"
            query["q"] = text
            query["mode"] = mode.rawValue
        case .userTimeline(let userID, let tab):
            path = "/v2/user/timeline"
            query["id"] = userID
            query["tab"] = tab.rawValue
        case .follows(let userID, let followers):
            path = "/v2/user/follows"
            query["id"] = userID
            query["kind"] = followers ? "followers" : "following"
        case .notifications(let mentions):
            path = "/v2/notifications"
            query["tab"] = mentions ? "mentions" : "all"
        case .bookmarks:
            path = "/v2/bookmarks"
        }
        if let cursor = cursor {
            query["cursor"] = cursor
        }
        return (path, query)
    }

    /// <base>/<base path>/<route> with the query. The base path may be a sub-directory such as /xclient.
    private static func makeURL(baseURL: URL, path: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let routePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, routePath].filter { !$0.isEmpty }.joined(separator: "/")
        if !query.isEmpty {
            let pairs = query.sorted { $0.key < $1.key }.map { encodeQueryPart($0.key) + "=" + encodeQueryPart($0.value) }
            components.percentEncodedQuery = pairs.joined(separator: "&")
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }
        return url
    }

    /// "+", "&", "=" and "#" are encoded as well: URLComponents leaves "+" alone, and the relay reads it as a space.
    private static func encodeQueryPart(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// The v1 headers: the profile, and the bearer token as Authorization and as X-Relay-Key.
    private static func addHeaders(to request: inout URLRequest, profileName: String?, bearerToken: String?) {
        if let profileName = profileName?.trimmingCharacters(in: .whitespacesAndNewlines), !profileName.isEmpty {
            request.setValue(profileName, forHTTPHeaderField: "x-profile-name")
        }
        if let bearerToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            request.setValue(bearerToken, forHTTPHeaderField: "X-Relay-Key")
        }
    }

    /// The error body of api-v2.md §1: {"error": {"code", "message", "x_code", "retry_after"}}.
    private static func apiError(statusCode: Int, data: Data) -> APIError {
        let error = JSON(data: data)["error"]
        let message = error["message"].string
        switch error["code"].string ?? "" {
        case "unauthorized":
            return .unauthorized
        case "x_auth":
            return .xAuth(message ?? "Xのログイン情報が無効です。CGIの設定を確認してください。")
        case "rate_limited":
            let text = message ?? "リクエストが多すぎます。しばらく待ってから再試行してください。"
            return .rateLimited(text, retryAfter: error["retry_after"].int)
        case "not_found":
            return .notFound(message ?? "見つかりませんでした。")
        default:
            if statusCode == 401 { return .unauthorized }
            return .server(message ?? "リレーでエラーが発生しました。（HTTP \(statusCode)）")
        }
    }

    /// /profiles keeps the v1 error body {"error": "text"}.
    private static func legacyError(statusCode: Int, data: Data) -> APIError {
        if statusCode == 401 { return .unauthorized }
        let message = JSON(data: data)["error"].string ?? String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
        return .server("HTTP \(statusCode): \(message)")
    }

    /// {"ok": false} is a refusal even with status 200.
    private static func refusal(_ json: JSON) -> Error? {
        if json["ok"].bool == false {
            return APIError.server("操作に失敗しました。")
        }
        return nil
    }

    private static func userResult(_ result: Result<JSON, Error>) -> Result<User, Error> {
        switch result {
        case .success(let json):
            guard let user = User(json: json["user"]) else {
                return .failure(APIError.invalidResponse)
            }
            return .success(TweetStore.shared.intern(user))
        case .failure(let error):
            return .failure(error)
        }
    }

    private static func translationResult(_ result: Result<JSON, Error>) -> Result<Translation, Error> {
        switch result {
        case .success(let json):
            guard let translation = Translation(json: json) else {
                return .failure(APIError.invalidResponse)
            }
            return .success(translation)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// A missing optional is sent as JSON null.
    private static func optionalValue(_ text: String?) -> Any {
        if let text = text {
            return text
        }
        return NSNull()
    }
}

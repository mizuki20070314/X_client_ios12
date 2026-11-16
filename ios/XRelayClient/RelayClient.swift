import Foundation

final class RelayClient {
    static let shared = RelayClient()
    private static let defaultBaseURL = URL(string: "http://localhost:3000")!

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

    private let session: URLSession
    private var catalog: [String: [[String: Any]]]?
    private var catalogBaseURL: URL?

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
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
        if catalogBaseURL != baseURL {
            catalog = nil
            catalogBaseURL = nil
        }
    }

    func testConnection(
        baseURL: URL,
        profileName: String?,
        bearerToken: String?,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        var request = URLRequest(url: baseURL.appendingPathComponent("profiles"))
        request.httpMethod = "GET"
        addHeaders(to: &request, profileName: profileName, bearerToken: bearerToken)
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data = data, let response = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(APIError.invalidResponse)) }
                return
            }
            guard (200..<300).contains(response.statusCode) else {
                let apiError = Self.responseError(statusCode: response.statusCode, data: data)
                DispatchQueue.main.async { completion(.failure(apiError)) }
                return
            }
            do {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let profiles = object["profiles"] as? [String] else {
                    throw APIError.invalidResponse
                }
                DispatchQueue.main.async { completion(.success(profiles)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    func getTimeline(completion: @escaping (Result<[TimelinePost], Error>) -> Void) {
        request(operation: "HomeTimeline", variables: nil) { result in
            completion(result.map { Self.posts(from: $0) })
        }
    }

    func search(_ query: String, completion: @escaping (Result<[TimelinePost], Error>) -> Void) {
        request(operation: "SearchTimeline", variables: [
            "rawQuery": query,
            "count": 20,
            "querySource": "typed_query",
            "product": "Top"
        ]) { result in
            completion(result.map { Self.posts(from: $0) })
        }
    }

    func post(text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        if catalog == nil || catalogBaseURL != baseURL {
            loadCatalog { [weak self] result in
                switch result {
                case .success:
                    self?.post(text: text, completion: completion)
                case .failure(let error):
                    completion(.failure(error))
                }
            }
            return
        }

        guard let operation = catalog?["CreateTweet"]?.first(where: {
            ($0["method"] as? String) == "POST" && $0["data"] != nil
        }) else {
            completion(.failure(APIError.missingOperation("CreateTweet")))
            return
        }

        var body = operation["data"] as? [String: Any] ?? [:]
        var variables = body["variables"] as? [String: Any] ?? [:]
        variables["tweet_text"] = text
        variables["reply"] = NSNull()
        variables["media"] = [
            "media_entities": [],
            "possibly_sensitive": false
        ]
        body["variables"] = variables
        execute(method: "POST", path: operation["path"] as? String ?? "", query: [:], body: body) { result in
            completion(result.map { _ in () })
        }
    }

    private func request(
        operation name: String,
        variables: [String: Any]?,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        if catalog == nil || catalogBaseURL != baseURL {
            loadCatalog { [weak self] result in
                switch result {
                case .success:
                    self?.request(operation: name, variables: variables, completion: completion)
                case .failure(let error):
                    completion(.failure(error))
                }
            }
            return
        }

        guard let template = catalog?[name]?.first(where: {
            ($0["method"] as? String ?? "GET") == "GET" && $0["params"] != nil
        }) ?? catalog?[name]?.first,
              let path = template["path"] as? String else {
            completion(.failure(APIError.missingOperation(name)))
            return
        }

        var query = template["params"] as? [String: Any] ?? [:]
        if let variables = variables {
            query["variables"] = jsonString(variables)
        }
        execute(method: template["method"] as? String ?? "GET", path: path, query: query, body: nil, completion: completion)
    }

    private func loadCatalog(completion: @escaping (Result<Void, Error>) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("requests.ndjson"))
        request.httpMethod = "GET"
        addStoredHeaders(to: &request)
        session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data = data, let response = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(APIError.invalidResponse)) }
                return
            }
            guard (200..<300).contains(response.statusCode) else {
                let apiError = Self.responseError(statusCode: response.statusCode, data: data)
                DispatchQueue.main.async { completion(.failure(apiError)) }
                return
            }
            do {
                var operations: [String: [[String: Any]]] = [:]
                for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
                    guard let lineData = line.data(using: .utf8),
                          let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let path = object["path"] as? String else { continue }
                    let operationName = path.split(separator: "/").last.map(String.init) ?? path
                    operations[operationName, default: []].append(object)
                }
                guard !operations.isEmpty else { throw APIError.invalidResponse }
                guard let self = self else {
                    DispatchQueue.main.async { completion(.failure(APIError.invalidResponse)) }
                    return
                }
                self.catalog = operations
                self.catalogBaseURL = self.baseURL
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    private func execute(
        method: String,
        path: String,
        query: [String: Any],
        body: [String: Any]?,
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        let relayPath = path.hasPrefix("/i/api/") ? path : "/i/api\(path)"
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestPath = relayPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathParts = [basePath, requestPath].filter { !$0.isEmpty }
        components?.path = "/" + pathParts.joined(separator: "/")
        components?.queryItems = query.compactMap { key, value in
            guard let value = Self.queryValue(value) else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        guard let finalURL = components?.url else {
            completion(.failure(APIError.invalidURL))
            return
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addStoredHeaders(to: &request)
        if let body = body {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                completion(.failure(error))
                return
            }
        }
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data = data, let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(APIError.invalidResponse)) }
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let apiError = Self.responseError(statusCode: httpResponse.statusCode, data: data)
                DispatchQueue.main.async { completion(.failure(apiError)) }
                return
            }
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                if let message = Self.xErrorMessage(in: object) {
                    DispatchQueue.main.async { completion(.failure(APIError.server(message))) }
                    return
                }
                DispatchQueue.main.async { completion(.success(object)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    private func addStoredHeaders(to request: inout URLRequest) {
        addHeaders(to: &request, profileName: profileName, bearerToken: try? loadBearerToken())
    }

    private func addHeaders(to request: inout URLRequest, profileName: String?, bearerToken: String?) {
        if let profileName = profileName?.trimmingCharacters(in: .whitespacesAndNewlines), !profileName.isEmpty {
            request.setValue(profileName, forHTTPHeaderField: "x-profile-name")
        }
        if let bearerToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            request.setValue(bearerToken, forHTTPHeaderField: "X-Relay-Key")
        }
    }

    private static func queryValue(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if value is NSNull { return "null" }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func responseError(statusCode: Int, data: Data) -> APIError {
        if statusCode == 401 { return .unauthorized }
        let message: String
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? String {
            message = error
        } else {
            message = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
        }
        return .server("HTTP \(statusCode): \(message)")
    }

    private static func xErrorMessage(in object: Any) -> String? {
        guard let dictionary = object as? [String: Any],
              let errors = dictionary["errors"] as? [[String: Any]],
              let first = errors.first else { return nil }
        return first["message"] as? String ?? "Xからエラーが返されました。"
    }

    private func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func posts(from object: Any) -> [TimelinePost] {
        var posts: [TimelinePost] = []
        collectPosts(from: object, into: &posts)
        var seen = Set<String>()
        return posts.filter { seen.insert($0.id).inserted }
    }

    private static func collectPosts(from object: Any, into posts: inout [TimelinePost]) {
        if let dictionary = object as? [String: Any] {
            if let legacy = dictionary["legacy"] as? [String: Any],
               let id = legacy["id_str"] as? String ?? dictionary["rest_id"] as? String,
               let text = legacy["full_text"] as? String ?? dictionary["text"] as? String {
                let core = dictionary["core"] as? [String: Any]
                let user = (core?["user_results"] as? [String: Any]) ?? (dictionary["user_results"] as? [String: Any])
                let userResult = user?["result"] as? [String: Any]
                let userLegacy = userResult?["legacy"] as? [String: Any]
                let name = userLegacy?["name"] as? String ?? "Xユーザー"
                let handle = userLegacy?["screen_name"] as? String ?? ""
                let avatar = userLegacy?["profile_image_url_https"] as? String
                posts.append(TimelinePost(id: id, name: name, handle: handle, text: text, avatarURL: avatar.flatMap(URL.init)))
            }
            for value in dictionary.values {
                collectPosts(from: value, into: &posts)
            }
        } else if let array = object as? [Any] {
            for value in array {
                collectPosts(from: value, into: &posts)
            }
        }
    }
}

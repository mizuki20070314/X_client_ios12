import Foundation

/// Errors of the relay client. The messages are shown to the user, so they are Japanese. A message sent by the
/// relay is used as it is.
enum APIError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case unauthorized
    case xAuth(String)
    case rateLimited(String, retryAfter: Int?)
    case notFound(String)
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "設定からリレーURLと認証情報を設定してください。"
        case .invalidURL:
            return "リレーURLが正しくありません。"
        case .invalidResponse:
            return "リレーから不正な応答が返されました。"
        case .unauthorized:
            return "リレー認証に失敗しました。設定でBearerトークンを確認してください。"
        case .xAuth(let message), .notFound(let message), .server(let message), .network(let message):
            return message
        case .rateLimited(let message, let retryAfter):
            guard let seconds = retryAfter, seconds > 0 else { return message }
            return message + "（再試行まで約\(APIError.waitText(seconds))）"
        }
    }

    private static func waitText(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)秒" }
        return "\((seconds + 59) / 60)分"
    }
}

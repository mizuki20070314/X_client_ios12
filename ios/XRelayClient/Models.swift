import Foundation

struct TimelineMedia {
    let url: URL
    let altText: String
}

struct TimelinePost {
    let id: String
    let name: String
    let handle: String
    let text: String
    let avatarURL: URL?
    let createdAt: Date?
    let replyCount: Int
    let repostCount: Int
    let likeCount: Int
    let viewCount: Int?
    let media: [TimelineMedia]
    let isVerified: Bool
    let isLiked: Bool
    let isRetweeted: Bool

    var permalink: URL? {
        URL(string: "https://x.com/i/web/status/\(id)")
    }
}

enum SearchSort: String {
    case top = "Top"
    case latest = "Latest"

    var title: String {
        switch self {
        case .top: return "話題"
        case .latest: return "最新"
        }
    }
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case server(String)
    case missingOperation(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "リレーURLが正しくありません。"
        case .invalidResponse: return "リレーから不正な応答が返されました。"
        case .unauthorized: return "リレー認証に失敗しました。設定でBearerトークンを確認してください。"
        case .server(let message): return message
        case .missingOperation(let name): return "リクエストカタログに \(name) がありません。"
        }
    }
}

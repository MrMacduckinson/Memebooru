/// What a meme fundamentally is. Drives viewer, thumbnailer and hashing strategy.
public enum MemeKind: String, Codable, Sendable, CaseIterable {
    case image, gif, video, audio, text, article, tweet

    /// Meta tag auto-assigned on import.
    public var metaTag: String {
        switch self {
        case .image: return "picture"
        case .gif: return "gif"
        case .video: return "video"
        case .audio: return "audio"
        case .text: return "text"
        case .article: return "article"
        case .tweet: return "tweet"
        }
    }
}

/// `native` — rendered from payload (vector tweet/article); `screenshot` — physically an image
/// that is *conceptually* a tweet/article.
public enum Presentation: String, Codable, Sendable {
    case native, screenshot
}

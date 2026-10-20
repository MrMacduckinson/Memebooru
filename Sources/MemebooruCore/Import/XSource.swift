import Foundation

/// Authenticated x.com session: the two cookies a logged-in web session holds.
/// `userID` (own account, digits) is optional — derived from `twid` or resolved when needed.
public struct XSession: Sendable, Equatable, Codable {
    public var authToken: String
    public var csrf: String              // ct0 cookie == x-csrf-token header
    public var userID: String?

    public init(authToken: String, csrf: String, userID: String? = nil) {
        self.authToken = authToken; self.csrf = csrf; self.userID = userID
    }

    /// Build from a raw Cookie header (auth_token, ct0, twid). Returns nil if the essentials are missing.
    public static func fromCookieHeader(_ header: String) -> XSession? {
        var jar: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { jar[kv[0]] = kv[1] }
        }
        return from(cookies: jar)
    }

    public static func from(cookies: [String: String]) -> XSession? {
        guard let auth = cookies["auth_token"], let ct0 = cookies["ct0"], !auth.isEmpty, !ct0.isEmpty else { return nil }
        var uid: String? = nil
        if let twid = cookies["twid"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).removingPercentEncoding {   // twid = "u=<id>", sometimes quoted
            let id = twid.hasPrefix("u=") ? String(twid.dropFirst(2)) : ""
            // Anything but digits would be sent to x.com as the account id; resolved from settings instead.
            uid = !id.isEmpty && id.allSatisfy({ $0.isASCII && $0.isNumber }) ? id : nil
        }
        return XSession(authToken: auth, csrf: ct0, userID: uid)
    }

    var cookieHeader: String { "auth_token=\(authToken); ct0=\(csrf)" }
}

/// GraphQL operation ids and the `features` blob. X rotates these; override via init or env when they break.
public struct XEndpoints: Sendable {
    public var likes: String
    public var bookmarks: String
    public var userByScreenName: String
    public var features: [String: Bool]

    public init(likes: String, bookmarks: String, userByScreenName: String, features: [String: Bool]) {
        self.likes = likes; self.bookmarks = bookmarks; self.userByScreenName = userByScreenName; self.features = features
    }

    /// Defaults known to work around late 2025; env overrides: X_QID_LIKES / X_QID_BOOKMARKS / X_QID_USER / X_FEATURES(json).
    public static func standard(env: [String: String] = ProcessInfo.processInfo.environment) -> XEndpoints {
        var e = XEndpoints(
            likes: "xA8fDIbrJfy4ojjjXmSR-A",
            bookmarks: "iblrFnKr6PZUR-dWpfXG6g",
            userByScreenName: "Gb-d6r0vxPOADdG62OEBpQ",
            features: defaultFeatures)
        if let v = env["X_QID_LIKES"] { e.likes = v }
        if let v = env["X_QID_BOOKMARKS"] { e.bookmarks = v }
        if let v = env["X_QID_USER"] { e.userByScreenName = v }
        if let j = env["X_FEATURES"], let d = j.data(using: .utf8),
           let f = try? JSONDecoder().decode([String: Bool].self, from: d) { e.features = f }
        return e
    }

    /// Apply saved/discovered query-id overrides.
    public mutating func apply(_ o: XEndpointOverride) {
        if let v = o.likes { likes = v }
        if let v = o.bookmarks { bookmarks = v }
        if let v = o.userByScreenName { userByScreenName = v }
    }

    /// Broad feature set; unknown extras are ignored by the server, missing required ones 400.
    static let defaultFeatures: [String: Bool] = [
        "rweb_video_screen_enabled": false,
        "rweb_cashtags_enabled": true,
        "profile_label_improvements_pcf_label_in_post_enabled": true,
        "responsive_web_profile_redirect_enabled": true,
        "rweb_tipjar_consumption_enabled": false,
        "verified_phone_label_enabled": false,
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "responsive_web_graphql_timeline_navigation_enabled": true,
        "premium_content_api_read_enabled": false,
        "communities_web_enable_tweet_community_results_fetch": true,
        "c9s_tweet_anatomy_moderator_badge_enabled": true,
        "responsive_web_grok_analyze_button_fetch_trends_enabled": false,
        "responsive_web_grok_analyze_post_followups_enabled": true,
        "rweb_cashtags_composer_attachment_enabled": true,
        "responsive_web_jetfuel_frame": true,
        "responsive_web_grok_share_attachment_enabled": true,
        "responsive_web_grok_annotations_enabled": true,
        "articles_preview_enabled": true,
        "responsive_web_edit_tweet_api_enabled": true,
        "rweb_conversational_replies_downvote_enabled": false,
        "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
        "view_counts_everywhere_api_enabled": true,
        "longform_notetweets_consumption_enabled": true,
        "responsive_web_twitter_article_tweet_consumption_enabled": true,
        "content_disclosure_indicator_enabled": true,
        "content_disclosure_ai_generated_indicator_enabled": true,
        "responsive_web_grok_show_grok_translated_post": true,
        "responsive_web_grok_analysis_button_from_backend": true,
        "post_ctas_fetch_enabled": false,
        "freedom_of_speech_not_reach_fetch_enabled": true,
        "standardized_nudges_misinfo": true,
        "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
        "longform_notetweets_rich_text_read_enabled": true,
        "longform_notetweets_inline_media_enabled": false,
        "responsive_web_grok_image_annotation_enabled": true,
        "responsive_web_grok_imagine_annotation_enabled": true,
        "responsive_web_grok_community_note_auto_translation_is_enabled": true,
        "responsive_web_enhance_cards_enabled": false,
    ]
}

/// Query ids discovered from x.com's JS, persisted per device (x.com rotates them).
public struct XEndpointOverride: Sendable, Codable, Equatable {
    public var likes: String?
    public var bookmarks: String?
    public var userByScreenName: String?
    public var updatedAt: Int64?
    public init(likes: String? = nil, bookmarks: String? = nil, userByScreenName: String? = nil, updatedAt: Int64? = nil) {
        self.likes = likes; self.bookmarks = bookmarks; self.userByScreenName = userByScreenName; self.updatedAt = updatedAt
    }
    public var isEmpty: Bool { likes == nil && bookmarks == nil && userByScreenName == nil }
}

public struct XError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// x.com returned 404/400 for a GraphQL op — its query id/features are out of date.
public struct XQueryOutdated: Error, CustomStringConvertible, Sendable {
    public let operation: String; public let status: Int; public let body: String
    public var description: String { "x.com \(operation) HTTP \(status): query id out of date. \(body)" }
}

/// x.com answered 429: this session made too many requests. `resetAt` from `x-rate-limit-reset`.
public struct XRateLimited: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let resetAt: Date?
    public var description: String {
        "x.com \(operation): rate limited" + (resetAt.map { " until \(ISO8601DateFormatter().string(from: $0))" } ?? "")
    }
    static func from(_ resp: HTTPResponse, operation: String) -> XRateLimited {
        XRateLimited(operation: operation, resetAt: resp.headers["x-rate-limit-reset"].flatMap(Double.init)
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil })
    }
}

/// Reads a logged-in user's own Likes and Bookmarks via x.com's web GraphQL API.
public struct XClient: Sendable {
    /// Public web-app bearer token (same for every browser session — not a secret).
    public static let webBearer = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs=1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"

    let http: any HTTPClient
    let session: XSession
    public private(set) var endpoints: XEndpoints
    /// Set to persist newly discovered query ids.
    public var onEndpointsDiscovered: (@Sendable (XEndpointOverride) -> Void)?

    public init(http: any HTTPClient, session: XSession, endpoints: XEndpoints = .standard()) {
        self.http = http; self.session = session; self.endpoints = endpoints
    }

    private var headers: [String: String] {
        [
            "authorization": "Bearer \(Self.webBearer)",
            "x-csrf-token": session.csrf,
            "cookie": session.cookieHeader,
            "x-twitter-auth-type": "OAuth2Session",
            "x-twitter-active-user": "yes",
            "x-twitter-client-language": "en",
            "content-type": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Referer": "https://x.com/",
        ]
    }

    private func gql(_ queryID: String, operation: String, variables: [String: Any], features: [String: Bool]? = nil, fieldToggles: [String: Any]? = nil) async throws -> [String: Any] {
        // Percent-encode a JSON blob for a query-string value (encode reserved chars too).
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ obj: Any) -> String {
            let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        var query = "variables=\(enc(variables))"
        query += "&features=\(enc(features ?? endpoints.features))"
        if let fieldToggles { query += "&fieldToggles=\(enc(fieldToggles))" }
        let url = URL(string: "https://x.com/i/api/graphql/\(queryID)/\(operation)?\(query)")!
        let resp = try await http.get(url, headers: headers)
        guard resp.status == 200 else {
            let body = String(decoding: resp.body.prefix(400), as: UTF8.self)
            if resp.status == 429 { throw XRateLimited.from(resp, operation: operation) }
            if resp.status == 404 || resp.status == 400 { throw XQueryOutdated(operation: operation, status: resp.status, body: body) }
            throw XError("x.com \(operation) HTTP \(resp.status). Session expired. \(body)")
        }
        guard let root = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else { throw XError("bad JSON from \(operation)") }
        if let errors = root["errors"] as? [[String: Any]], let first = errors.first, let msg = first["message"] as? String {
            throw XError("x.com \(operation): \(msg)")
        }
        guard let data = root["data"] as? [String: Any] else { throw XError("no data in \(operation)") }
        return data
    }

    /// Own account id, from the session or resolved via settings.json + UserByScreenName.
    public mutating func resolveUserID() async throws -> String {
        if let id = session.userID, !id.isEmpty { return id }
        let settings = try await http.get(URL(string: "https://api.x.com/1.1/account/settings.json")!, headers: headers)
        guard settings.status == 200, let s = try JSONSerialization.jsonObject(with: settings.body) as? [String: Any],
              let screen = s["screen_name"] as? String else { throw XError("cannot read account settings — session likely invalid") }
        let data = try await gql(endpoints.userByScreenName, operation: "UserByScreenName",
                                 variables: ["screen_name": screen, "withSafetyModeUserFields": true])
        guard let id = ((data["user"] as? [String: Any])?["result"] as? [String: Any])?["rest_id"] as? String else {
            throw XError("cannot resolve user id for @\(screen)")
        }
        return id
    }

    public struct Page: Sendable {
        public let tweets: [FetchedTweet]
        public let cursor: String?
    }

    /// Read current Likes/Bookmarks/UserByScreenName query ids from x.com's JS.
    /// Public path: service worker → main bundle (covers Likes + UserByScreenName). With a session it
    /// also follows the authenticated home page to reach lazy chunks (Bookmarks). Persists via the callback.
    @discardableResult
    public mutating func discoverEndpoints() async throws -> XEndpointOverride {
        var scripts: [String] = []
        // 1. public service worker lists the precached bundles incl. main.<hash>.js
        if let sw = try? await self.text("https://x.com/responsive-web/client-web/sw.js") {
            scripts += Self.bundleURLs(in: sw)
        }
        // 2. authenticated home may reference lazy chunks (Bookmarks etc.)
        if let home = try? await httpText("https://x.com/home", cookies: true) {
            scripts += Self.bundleURLs(in: home)
        }
        scripts = Array(Set(scripts))
        guard !scripts.isEmpty else { throw XError("could not reach x.com JS bundles — set query ids manually with `x qid`") }

        var found = XEndpointOverride()
        for url in scripts.sorted(by: { rank($0) < rank($1) }) {
            if found.likes != nil && found.bookmarks != nil && found.userByScreenName != nil { break }
            guard let js = try? await self.text(url) else { continue }
            if found.likes == nil { found.likes = Self.queryID(operation: "Likes", in: js) }
            if found.bookmarks == nil { found.bookmarks = Self.queryID(operation: "Bookmarks", in: js) }
            if found.userByScreenName == nil { found.userByScreenName = Self.queryID(operation: "UserByScreenName", in: js) }
        }
        guard !found.isEmpty else { throw XError("could not find query ids in x.com bundles — set them manually with `x qid`") }
        found.updatedAt = Clock.nowMillis()
        endpoints.apply(found)
        onEndpointsDiscovered?(found)
        return found
    }

    private func httpText(_ url: String, cookies: Bool) async throws -> String {
        guard let u = URL(string: url) else { throw XError("bad url") }
        var h = ["User-Agent": htmlHeaders["User-Agent"]!, "Accept": "text/html,application/xhtml+xml"]
        if cookies { h["cookie"] = session.cookieHeader }
        let r = try await http.get(u, headers: h)
        guard r.status == 200 else { throw XError("HTTP \(r.status)") }
        return String(decoding: r.body, as: UTF8.self)
    }

    private func rank(_ url: String) -> Int {
        if url.contains("bundle.UserByScreenName") || url.contains("bundle.Likes") || url.contains("bundle.Bookmarks") { return 0 }
        if url.contains("/api.") || url.contains("/main.") { return 1 }
        if url.contains("endpoints") || url.contains("Bookmarks") || url.contains("Likes") { return 1 }
        return 2
    }

    private var htmlHeaders: [String: String] {
        ["cookie": session.cookieHeader,
         "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
         "Accept": "text/html,application/xhtml+xml"]
    }
    private func text(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw XError("bad url") }
        let r = try await http.get(u, headers: ["User-Agent": htmlHeaders["User-Agent"]!])
        guard r.status == 200 else { throw XError("HTTP \(r.status) for bundle") }
        return String(decoding: r.body, as: UTF8.self)
    }

    static func bundleURLs(in html: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"https://abs\.twimg\.com/responsive-web/client-web[^"'\ )]+?\.js"#)
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    /// main.js maps chunk short-names to hashes: `"Bookmarks":"a1b2c3"` → full URL.
    static func chunkURLs(fromMain js: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"["']([\w.\-/]*(?:endpoints|Bookmarks|Likes|UserByScreenName|api)[\w.\-/]*)["']\s*:\s*["']([0-9a-f]{6,})["']"#)
        let ns = js as NSString
        return re.matches(in: js, range: NSRange(location: 0, length: ns.length)).map {
            let name = ns.substring(with: $0.range(at: 1)), hash = ns.substring(with: $0.range(at: 2))
            return "https://abs.twimg.com/responsive-web/client-web/\(name).\(hash)a.js"
        }
    }
    /// Extract queryId for an operation: `{queryId:"ABC",operationName:"Likes"}` in either field order.
    static func queryID(operation: String, in js: String) -> String? {
        let q = #"["']?queryId["']?\s*:\s*["']([\w-]{15,25})["']"#
        let n = #"["']?operationName["']?\s*:\s*["']"# + operation + #"["']"#
        let patterns = [
            q + #"\s*,\s*"# + n,                                   // queryId then operationName
            n + #"\s*,\s*"# + q,                                   // operationName then queryId
            #"["']"# + operation + #"["']\s*,\s*"# + q,           // "Op","queryId":"..."
        ]
        let ns = js as NSString
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p), let m = re.firstMatch(in: js, range: NSRange(location: 0, length: ns.length)) else { continue }
            return ns.substring(with: m.range(at: 1))
        }
        return nil
    }

    public mutating func likesPage(userID: String, cursor: String?, count: Int = 40) async throws -> Page {
        var vars: [String: Any] = ["userId": userID, "count": count, "includePromotedContent": false,
                                   "withClientEventToken": false, "withBirdwatchNotes": false, "withVoice": true]
        if let cursor { vars["cursor"] = cursor }
        let data = try await gql(endpoints.likes, operation: "Likes", variables: vars, fieldToggles: ["withArticlePlainText": false])
        let result = (data["user"] as? [String: Any])?["result"] as? [String: Any]
        let tl = (result?["timeline_v2"] as? [String: Any]) ?? (result?["timeline"] as? [String: Any])
        let instr = (tl?["timeline"] as? [String: Any])?["instructions"] as? [[String: Any]] ?? []
        return XTimelineParser.parse(instructions: instr)
    }

    /// Raw JSON of the first Likes/Bookmarks page (for debugging endpoint/shape changes).
    public mutating func rawPage(_ feed: XImporter.Feed) async throws -> Data {
        do { return try await rawPageInner(feed) }
        catch is XQueryOutdated { try await discoverEndpoints(); return try await rawPageInner(feed) }
    }
    private mutating func rawPageInner(_ feed: XImporter.Feed) async throws -> Data {
        if feed == .likes {
            let uid = try await resolveUserID()
            let vars: [String: Any] = ["userId": uid, "count": 20, "includePromotedContent": false,
                                       "withClientEventToken": false, "withBirdwatchNotes": false, "withVoice": true]
            return try await gqlRaw(endpoints.likes, operation: "Likes", variables: vars, fieldToggles: ["withArticlePlainText": false])
        } else {
            return try await gqlRaw(endpoints.bookmarks, operation: "Bookmarks", variables: ["count": 20, "includePromotedContent": true])
        }
    }
    private func gqlRaw(_ queryID: String, operation: String, variables: [String: Any], features: [String: Bool]? = nil, fieldToggles: [String: Any]? = nil) async throws -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        func enc(_ obj: Any) -> String {
            let d = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
            return String(decoding: d, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        var qs = "variables=\(enc(variables))&features=\(enc(features ?? endpoints.features))"
        if let fieldToggles { qs += "&fieldToggles=\(enc(fieldToggles))" }
        let url = URL(string: "https://x.com/i/api/graphql/\(queryID)/\(operation)?\(qs)")!
        let resp = try await http.get(url, headers: headers)
        if resp.status == 404 || resp.status == 400 { throw XQueryOutdated(operation: operation, status: resp.status, body: String(decoding: resp.body.prefix(300), as: UTF8.self)) }
        return resp.body
    }

    public mutating func bookmarksPage(cursor: String?, count: Int = 40) async throws -> Page {
        var vars: [String: Any] = ["count": count, "includePromotedContent": true]
        if let cursor { vars["cursor"] = cursor }
        let data = try await gql(endpoints.bookmarks, operation: "Bookmarks", variables: vars)
        let tl = (data["bookmark_timeline_v2"] as? [String: Any]) ?? (data["bookmark_timeline"] as? [String: Any])
        let instr = (tl?["timeline"] as? [String: Any])?["instructions"] as? [[String: Any]] ?? []
        return XTimelineParser.parse(instructions: instr)
    }
}

/// Parses a GraphQL timeline's `instructions` into `FetchedTweet`s + the bottom cursor.
enum XMediaURL {
    /// Full-resolution original for a pbs photo.
    static func origPhoto(_ url: String) -> String {
        guard url.contains("pbs.twimg.com/media"), !url.contains("name=") else { return url }
        return url + (url.contains("?") ? "&" : "?") + "name=orig"
    }
    /// Crisp avatar (x.com serves a 48px `_normal` by default).
    static func bigAvatar(_ url: String) -> String {
        url.replacingOccurrences(of: "_normal.", with: "_400x400.")
    }
}

enum XTimelineParser {
    static func parse(instructions: [[String: Any]]) -> XClient.Page {
        var tweets: [FetchedTweet] = []
        var cursor: String? = nil

        func consume(itemContent: [String: Any]?) {
            guard let itemContent, let result = tweetResult(itemContent["tweet_results"] as? [String: Any]),
                  let t = tweet(from: result) else { return }
            tweets.append(t)
        }
        func handle(entry: [String: Any]) {
            let entryID = entry["entryId"] as? String ?? ""
            let content = entry["content"] as? [String: Any] ?? entry["item"] as? [String: Any] ?? [:]
            // cursor (top-level or inside a module item)
            if entryID.hasPrefix("cursor-bottom") || (content["cursorType"] as? String) == "Bottom"
                || ((content["itemContent"] as? [String: Any])?["cursorType"] as? String) == "Bottom" {
                cursor = (content["value"] as? String)
                    ?? ((content["itemContent"] as? [String: Any])?["value"] as? String) ?? cursor
                if !entryID.contains("tweet") { return }
            }
            // plain tweet item
            consume(itemContent: content["itemContent"] as? [String: Any])
            // module of items (conversation / carousels)
            if let items = content["items"] as? [[String: Any]] {
                for it in items { handle(entry: it) }
            }
        }

        for ins in instructions {
            switch ins["type"] as? String {
            case "TimelineAddEntries", "TimelineAddToModule", nil:
                let entries = (ins["entries"] as? [[String: Any]])
                    ?? (ins["moduleItems"] as? [[String: Any]])
                    ?? (ins["entry"].map { [$0 as! [String: Any]] }) ?? []
                for e in entries { handle(entry: e) }
            default: break
            }
        }
        return XClient.Page(tweets: tweets, cursor: cursor)
    }

    private static func tweetResult(_ wrap: [String: Any]?) -> [String: Any]? {
        guard var result = wrap?["result"] as? [String: Any] else { return nil }
        if (result["__typename"] as? String) == "TweetWithVisibilityResults", let inner = result["tweet"] as? [String: Any] {
            result = inner
        }
        return result
    }

    static func tweet(from result: [String: Any]) -> FetchedTweet? {
        guard let id = result["rest_id"] as? String, let legacy = result["legacy"] as? [String: Any] else { return nil }
        // Author: x.com moved name/screen_name into `core` and the avatar into `avatar`,
        // but older payloads still keep them in `legacy` — read both.
        let userResult = (((result["core"] as? [String: Any])?["user_results"] as? [String: Any])?["result"] as? [String: Any]) ?? [:]
        let userLegacy = userResult["legacy"] as? [String: Any] ?? [:]
        let userCore = userResult["core"] as? [String: Any] ?? [:]
        let handle = (userCore["screen_name"] as? String) ?? (userLegacy["screen_name"] as? String) ?? ""
        let authorName = (userCore["name"] as? String) ?? (userLegacy["name"] as? String) ?? ""
        let avatar = ((userResult["avatar"] as? [String: Any])?["image_url"] as? String) ?? (userLegacy["profile_image_url_https"] as? String)

        // x.com HTML-escapes `&`, `<`, `>` in `full_text`, but its indices count the unescaped text.
        var text = FetchedTweet.decodeEntities(legacy["full_text"] as? String ?? "")
        // A reply starts with the @handles it answers; x.com shows only `display_text_range` (code points).
        if let range = legacy["display_text_range"] as? [Int], range.count == 2, range[0] > 0, range[0] <= text.unicodeScalars.count {
            let scalars = text.unicodeScalars
            let start = scalars.index(scalars.startIndex, offsetBy: range[0])
            let end = scalars.index(scalars.startIndex, offsetBy: min(range[1], scalars.count))
            text = String(scalars[start..<max(start, end)])
        }
        var noteURLs: [[String: Any]] = []
        if let note = ((result["note_tweet"] as? [String: Any])?["note_tweet_results"] as? [String: Any])?["result"] as? [String: Any],
           let full = note["text"] as? String {
            text = FetchedTweet.decodeEntities(full)
            // A long tweet carries its own link list.
            noteURLs = ((note["entity_set"] as? [String: Any])?["urls"] as? [[String: Any]]) ?? []
        }

        var media: [FetchedTweet.Media] = []
        let mediaList = (legacy["extended_entities"] as? [String: Any])?["media"] as? [[String: Any]]
            ?? (legacy["entities"] as? [String: Any])?["media"] as? [[String: Any]] ?? []
        for m in mediaList {
            let type = m["type"] as? String ?? "photo"
            let w = ((m["original_info"] as? [String: Any])?["width"]) as? Int
            let h = ((m["original_info"] as? [String: Any])?["height"]) as? Int
            if type == "photo" {
                if let u = m["media_url_https"] as? String {
                    media.append(.init(kind: .photo, url: XMediaURL.origPhoto(u), thumbnailURL: u, width: w, height: h))
                }
            } else if let variants = (m["video_info"] as? [String: Any])?["variants"] as? [[String: Any]] {
                let best = variants.filter { ($0["content_type"] as? String) == "video/mp4" }
                    .max { (($0["bitrate"] as? Int) ?? 0) < (($1["bitrate"] as? Int) ?? 0) }
                if let u = best?["url"] as? String {
                    media.append(.init(kind: type == "animated_gif" ? .gif : .video, url: u,
                                       thumbnailURL: m["media_url_https"] as? String, width: w, height: h))
                }
            }
        }

        // Expand t.co link entities to their display target, and drop the media t.co links (they duplicate the attached media).
        do {
            let urls = ((legacy["entities"] as? [String: Any])?["urls"] as? [[String: Any]] ?? []) + noteURLs
            for u in urls {
                if let tco = u["url"] as? String, let disp = (u["display_url"] as? String) ?? (u["expanded_url"] as? String) {
                    text = text.replacingOccurrences(of: tco, with: disp)
                }
            }
        }
        for m in mediaList { if let u = m["url"] as? String { text = text.replacingOccurrences(of: u, with: "") } }
        // The quoted tweet's own link sits at the end of the text; the quote is shown instead.
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let permalink = legacy["quoted_status_permalink"] as? [String: Any] {
            for key in ["url", "display", "expanded"] {
                if let link = permalink[key] as? String, !link.isEmpty, text.hasSuffix(link) {
                    text = String(text.dropLast(link.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        let quoted = tweetResult(result["quoted_status_result"] as? [String: Any]).flatMap { tweet(from: $0) }

        let created = (legacy["created_at"] as? String).flatMap(parseTwitterDate)
        let raw = (try? JSONSerialization.data(withJSONObject: result, options: [])) ?? Data()
        return FetchedTweet(
            id: id, url: "https://x.com/\(handle.isEmpty ? "i" : handle)/status/\(id)", text: text,
            authorName: authorName, handle: handle,
            avatarURL: avatar.map(XMediaURL.bigAvatar), postedAt: created,
            replyToHandle: legacy["in_reply_to_screen_name"] as? String,
            replyToTweetID: legacy["in_reply_to_status_id_str"] as? String,
            quotedTweetID: legacy["quoted_status_id_str"] as? String, media: media, raw: raw,
            quoted: quoted.map { [$0] } ?? [])
    }

    static func parseTwitterDate(_ s: String) -> Int64? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return f.date(from: s).map { Int64($0.timeIntervalSince1970 * 1000) }
    }
}

/// Imports own Likes / Bookmarks into staging, page by page, skipping already-imported tweets.
public struct XImporter: Sendable {
    public enum Feed: String, Sendable { case likes, bookmarks }

    public let staging: StagingArea
    public var client: XClient
    public let tweetImporter: TweetImporter

    public init(staging: StagingArea, client: XClient, http: any HTTPClient, archive: Bool = false) {
        self.staging = staging; self.client = client
        // Media download reuses TweetImporter; wayback off by default (way too slow for thousands of likes).
        self.tweetImporter = TweetImporter(staging: staging, source: FxTwitterSource(http: http), http: http, archive: archive)
    }

    public struct Progress: Sendable {
        public var staged = 0, skipped = 0, pages = 0, tweetsSeen = 0
        /// Saved tweets missing some of their media (download failed); fetching them again fixes nothing
        /// automatically, but the count says how many.
        public var mediaMissing = 0
        /// Media bytes downloaded so far.
        public var bytes: Int64 = 0
        /// Set while waiting out a 429 from x.com.
        public var waitingUntil: Date?
        /// Stopped early because the newest pages were all known (an update run).
        public var caughtUp = false
        /// Chain tweets (what the imported ones reply to / quote) staged with them, and those that
        /// couldn't be fetched (deleted, protected).
        public var chain = 0, chainMissing = 0
        /// Known chain-only tweets that turned out to be liked themselves — now posts of their own.
        public var promoted = 0
        public init() {}
    }

    /// How hard to lean on x.com. Defaults look like someone scrolling the page.
    public struct Pace: Sendable {
        /// Pause between timeline pages (plus up to a second of jitter).
        public var pageDelay: Duration = .seconds(2)
        /// An update run (no checkpoint to resume) stops after this many pages with nothing new.
        public var knownPagesToStop = 2
        /// 429s in a row before giving up (the checkpoint stays, so a later run resumes).
        public var maxRateLimitWaits = 6
        /// Wait used when x.com doesn't say when the limit resets.
        public var defaultRateLimitWait: Duration = .seconds(15 * 60)
        public init() {}
    }

    /// Streams pages until `limit` new tweets are imported (0 = all) into staging, each with its chain
    /// (the tweets it replies to and quotes — `chains`). Downloads media concurrently.
    /// `commitDirectly` skips review and the chains (tests, tools); everything a person imports goes to staging.
    /// Pages are paced (`pace`), a 429 is waited out, progress is checkpointed after every page
    /// (`resume` continues from there). Honours task cancellation; `onItem` fires per imported tweet,
    /// `onProgress` after every page and while waiting.
    @discardableResult
    public mutating func importFeed(_ feed: Feed, limit: Int = 0, extraTags: [String] = [],
                                    commitDirectly: Bool = false, chains: Bool = true, concurrency: Int = 6,
                                    resume: Bool = true, undoBatch: Int64? = nil, pace: Pace = Pace(),
                                    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                                    onProgress: (@Sendable (Progress) -> Void)? = nil,
                                    onItem: (@Sendable (FetchedTweet) -> Void)? = nil) async throws -> Progress {
        var progress = Progress()
        func page(cursor: String?, userID: String) async throws -> XClient.Page {
            var waits = 0
            while true {
                do {
                    do {
                        return feed == .likes ? try await client.likesPage(userID: userID, cursor: cursor)
                                              : try await client.bookmarksPage(cursor: cursor)
                    } catch is XQueryOutdated {
                        try await client.discoverEndpoints()
                        return feed == .likes ? try await client.likesPage(userID: userID, cursor: cursor)
                                              : try await client.bookmarksPage(cursor: cursor)
                    }
                } catch let limited as XRateLimited {
                    waits += 1
                    guard waits <= pace.maxRateLimitWaits else { throw limited }
                    // Clamped to a day: a garbage header must neither trap the Int conversion nor stall forever.
                    let wait: Duration = limited.resetAt.map { .seconds(max(30, Int(min(max($0.timeIntervalSinceNow, 0), 86_400).rounded(.up)) + 5)) }
                        ?? pace.defaultRateLimitWait
                    progress.waitingUntil = Date().addingTimeInterval(Double(wait.components.seconds))
                    onProgress?(progress)
                    try await sleep(wait)
                    progress.waitingUntil = nil
                }
            }
        }
        let userID: String
        if feed == .likes {
            do { userID = try await client.resolveUserID() }
            catch is XQueryOutdated { try await client.discoverEndpoints(); userID = try await client.resolveUserID() }
        } else { userID = "" }

        let collection = staging.collection
        var cursor: String? = resume ? try collection.xCursor(feed.rawValue) : nil
        // Once the whole history has been walked to the end, later runs are updates: the feed is newest
        // first, so pages of known tweets mean everything older is in already. Before that (e.g. only
        // the newest 100 were imported) known pages say nothing about what's below them.
        let completeKey = feed.rawValue + "-complete"
        let updateRun = try collection.xCursor(completeKey) != nil
        var knownStreak = 0
        var emptyStreak = 0
        let known = KnownTweets(try staging.stagedTweetIDs().union(collection.tweetIDs()))
        let tags = extraTags
        let importer = tweetImporter
        let loader = TweetChainLoader(source: importer.source)
        let stagingArea = staging

        outer: while limit == 0 || progress.staged < limit {
            if Task.isCancelled { break }
            let pageData = try await page(cursor: cursor, userID: userID)
            progress.pages += 1
            progress.tweetsSeen += pageData.tweets.count

            // new tweets on this page
            var fresh: [FetchedTweet] = []
            for tw in pageData.tweets {
                if known.claim(tw.id) { fresh.append(tw); continue }
                // Known — but maybe only as part of another tweet's chain: then it's a post now.
                if try collection.promoteChainTweet(tw.id, tags: tags) || staging.promoteChainItem(tw.id, tags: tags) {
                    progress.promoted += 1
                } else { progress.skipped += 1 }
            }
            // The end of the feed: x.com keeps handing out a cursor, but pages come back empty.
            func reachedEnd() {
                try? collection.clearXCursor(feed.rawValue)
                try? collection.setXCursor(completeKey, "1")
            }
            if pageData.tweets.isEmpty { emptyStreak += 1; if emptyStreak >= 2 { reachedEnd(); break } } else { emptyStreak = 0 }
            if updateRun, !pageData.tweets.isEmpty, fresh.isEmpty {
                knownStreak += 1
                if knownStreak >= pace.knownPagesToStop {
                    progress.caughtUp = true
                    try? collection.clearXCursor(feed.rawValue)       // next update starts from the top again
                    break
                }
            } else { knownStreak = 0 }

            // download + stage the fresh ones concurrently, in chunks
            var idx = 0
            while idx < fresh.count {
                if Task.isCancelled { break outer }
                if limit != 0, progress.staged >= limit { break outer }
                let room = limit == 0 ? concurrency : min(concurrency, limit - progress.staged)
                let chunk = Array(fresh[idx..<min(idx + max(1, room), fresh.count)])
                idx += chunk.count

                if commitDirectly {
                    // download concurrently, then insert straight into the collection (no staging flicker)
                    let prepared: [TweetImporter.PreparedTweet] = try await withThrowingTaskGroup(of: TweetImporter.PreparedTweet?.self) { group in
                        for tw in chunk { group.addTask { try? await importer.prepare(tw) } }
                        var out: [TweetImporter.PreparedTweet] = []
                        for try await p in group { if let p { out.append(p) } }
                        return out
                    }
                    for p in prepared {
                        progress.bytes += p.media.reduce(Int64(0)) { sum, m in
                            sum + ((try? FileManager.default.attributesOfItem(atPath: m.url.path)[.size] as? Int64) ?? 0)
                        }
                        if p.media.count < p.tweet.media.count { progress.mediaMissing += 1 }
                        _ = try importer.commitPrepared(p, into: collection, extraTags: tags, undoBatch: undoBatch)
                        progress.staged += 1
                        onItem?(p.tweet)
                    }
                } else {
                    typealias Done = (item: StagedItem, tweet: FetchedTweet, chain: Int, missing: Int, media: Int, bytes: Int64)
                    let staged: [Done] = try await withThrowingTaskGroup(of: Done?.self) { group in
                        for tw in chunk {
                            group.addTask {
                                guard let item = try? await importer.stage(tw) else { return nil }
                                let media = stagingArea.extras(item).filter { $0.role == .media }
                                let bytes = media.reduce(Int64(0)) { sum, m in
                                    sum + (((try? FileManager.default.attributesOfItem(atPath: m.url.path))?[.size] as? NSNumber)?.int64Value ?? 0)
                                }
                                guard chains else { return (item, tw, 0, 0, media.count, bytes) }
                                let c = await stagingArea.stageChain(of: tw, under: item.id, loader: loader, importer: importer, known: known)
                                return (item, tw, c.staged, c.missing, media.count, bytes)
                            }
                        }
                        var out: [Done] = []
                        for try await d in group { if let d { out.append(d) } }
                        return out
                    }
                    for d in staged {
                        var item = d.item
                        if !tags.isEmpty { item.userTags += tags; try staging.update(item) }
                        progress.staged += 1
                        progress.bytes += d.bytes
                        if d.media < d.tweet.media.count { progress.mediaMissing += 1 }
                        progress.chain += d.chain
                        progress.chainMissing += d.missing
                        onItem?(d.tweet)
                    }
                }
            }
            guard let next = pageData.cursor, next != cursor else { reachedEnd(); break }
            cursor = next
            try? collection.setXCursor(feed.rawValue, cursor)  // checkpoint
            onProgress?(progress)
            if Task.isCancelled { break }
            try? await sleep(pace.pageDelay + .milliseconds(Int.random(in: 0...1000)))
        }
        onProgress?(progress)
        return progress
    }
}

extension StagedItem {
    public var payloadTweetID: String? { if case .tweet(let p) = payload { return p.tweetID } else { return nil } }
}

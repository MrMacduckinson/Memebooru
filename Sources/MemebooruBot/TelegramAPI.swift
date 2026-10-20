import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Minimal Telegram Bot API surface the bot needs. Decoding uses snake_case → camelCase conversion,
// so field names below mirror https://core.telegram.org/bots/api one-to-one.

public struct TGUser: Codable, Sendable, Equatable { public var id: Int64; public var firstName: String?; public var username: String? }
public struct TGChat: Codable, Sendable, Equatable { public var id: Int64; public var type: String?; public var title: String?; public var username: String? }

public struct TGFileRef: Codable, Sendable, Equatable {
    public var fileId: String
    public var fileUniqueId: String?
    public var fileName: String?
    public var mimeType: String?
    public var fileSize: Int64?
    public var width: Int?
    public var height: Int?
    public var duration: Int?
    public init(fileId: String, fileName: String? = nil, mimeType: String? = nil, fileSize: Int64? = nil) {
        self.fileId = fileId; self.fileName = fileName; self.mimeType = mimeType; self.fileSize = fileSize
    }
}

/// Where a forwarded message came from (Bot API 7+ `forward_origin`).
public struct TGOrigin: Codable, Sendable, Equatable {
    public var type: String
    public var date: Int64?
    public var senderUser: TGUser?
    public var senderUserName: String?
    public var chat: TGChat?
    public var authorSignature: String?
}

public final class TGMessage: Codable, @unchecked Sendable {
    public var messageId: Int
    public var from: TGUser?
    public var chat: TGChat
    public var date: Int64
    public var text: String?
    public var caption: String?
    public var photo: [TGFileRef]?
    public var animation: TGFileRef?
    public var video: TGFileRef?
    public var document: TGFileRef?
    public var audio: TGFileRef?
    public var voice: TGFileRef?
    public var videoNote: TGFileRef?
    public var sticker: TGFileRef?
    public var forwardOrigin: TGOrigin?
    public var replyToMessage: TGMessage?
    /// Set on every message of an album (several photos / videos / files sent together, delivered as
    /// separate messages); the same for all of them.
    public var mediaGroupId: String?

    public init(messageId: Int, from: TGUser?, chat: TGChat, date: Int64, text: String? = nil) {
        self.messageId = messageId; self.from = from; self.chat = chat; self.date = date; self.text = text
    }
}

public struct TGInlineQuery: Codable, Sendable {
    public var id: String
    public var from: TGUser
    public var query: String
    public var offset: String
    public init(id: String, from: TGUser, query: String, offset: String = "") { self.id = id; self.from = from; self.query = query; self.offset = offset }
}

/// Sent when the user picks an inline result (needs /setinlinefeedback at @BotFather).
public struct TGChosenInlineResult: Codable, Sendable {
    public var resultId: String
    public var from: TGUser
    public var query: String
    public init(resultId: String, from: TGUser, query: String = "") { self.resultId = resultId; self.from = from; self.query = query }
}

public struct TGUpdate: Codable, Sendable {
    public var updateId: Int64
    public var message: TGMessage?
    public var editedMessage: TGMessage?
    public var inlineQuery: TGInlineQuery?
    public var chosenInlineResult: TGChosenInlineResult?
    public init(updateId: Int64, message: TGMessage? = nil, editedMessage: TGMessage? = nil,
                inlineQuery: TGInlineQuery? = nil, chosenInlineResult: TGChosenInlineResult? = nil) {
        self.updateId = updateId; self.message = message; self.editedMessage = editedMessage
        self.inlineQuery = inlineQuery; self.chosenInlineResult = chosenInlineResult
    }
}

public struct TGCommand: Sendable, Equatable {
    public let command: String, description: String
    public init(_ command: String, _ description: String) { self.command = command; self.description = description }
}

public struct TGFile: Codable, Sendable { public var fileId: String; public var filePath: String?; public var fileSize: Int64? }

/// One inline answer. Only the fields for its `type` are set; nil fields are omitted on the wire.
public struct TGInlineResult: Encodable, Sendable, Equatable {
    public struct TextContent: Encodable, Sendable, Equatable { public var messageText: String }
    public var type: String
    public var id: String
    public var photoFileId: String?
    public var gifFileId: String?
    public var videoFileId: String?
    public var audioFileId: String?
    public var voiceFileId: String?
    public var documentFileId: String?
    public var title: String?
    public var description: String?
    public var caption: String?
    public var inputMessageContent: TextContent?

    public init(type: String, id: String) { self.type = type; self.id = id }
}

/// How a file is uploaded to Telegram, which also decides the inline result type used for it.
public enum TGMediaKind: String, Sendable, CaseIterable {
    case photo, animation, video, audio, voice, document

    var method: String { "send" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var field: String { rawValue }
}

public struct TelegramError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public let retryAfter: Int?
    init(_ d: String, retryAfter: Int? = nil) { description = d; self.retryAfter = retryAfter }
}

/// Everything the bot calls. A protocol so tests run against a fake.
public protocol TelegramAPI: Sendable {
    func getUpdates(offset: Int64?, timeout: Int) async throws -> [TGUpdate]
    func sendMessage(chatID: Int64, text: String, replyTo: Int?) async throws -> TGMessage
    func sendMedia(_ kind: TGMediaKind, chatID: Int64, file: URL, silent: Bool) async throws -> TGMessage
    func deleteMessage(chatID: Int64, messageID: Int) async throws
    /// `emptyButton`: text of a button opening the bot's chat, shown above the results (used when nothing matched).
    func answerInlineQuery(id: String, results: [TGInlineResult], nextOffset: String?, cacheTime: Int, emptyButton: String?) async throws
    func setCommands(_ commands: [TGCommand]) async throws
    func getFile(fileID: String) async throws -> TGFile
    func download(filePath: String) async throws -> Data
}

/// Real Bot API over HTTPS (URLSession; FoundationNetworking on Linux).
public final class HTTPTelegramAPI: TelegramAPI, @unchecked Sendable {
    private let token: String
    private let base: URL
    private let session: URLSession
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }()
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e }()

    public init(token: String, base: URL = URL(string: "https://api.telegram.org")!) {
        self.token = token; self.base = base
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90       // long polling holds requests ~50s
        cfg.timeoutIntervalForResource = 600     // uploads of large videos
        session = URLSession(configuration: cfg)
    }

    private struct Envelope<T: Decodable>: Decodable {
        struct Params: Decodable { var retryAfter: Int? }
        var ok: Bool; var result: T?; var description: String?; var parameters: Params?
    }

    private func methodURL(_ m: String) -> URL { base.appendingPathComponent("bot\(token)").appendingPathComponent(m) }

    private func perform(_ req: URLRequest) async throws -> (Data, Int) {
        try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: req) { data, resp, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (data ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0))
            }.resume()
        }
    }

    private func call<T: Decodable>(_ method: String, json body: [String: Any]) async throws -> T {
        var req = URLRequest(url: methodURL(method))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await decode(method, try await perform(req).0)
    }

    private func decode<T: Decodable>(_ method: String, _ data: Data) throws -> T {
        let env = try decoder.decode(Envelope<T>.self, from: data)
        guard env.ok, let r = env.result else {
            throw TelegramError("\(method): \(env.description ?? "unknown error")", retryAfter: env.parameters?.retryAfter)
        }
        return r
    }

    public func getUpdates(offset: Int64?, timeout: Int) async throws -> [TGUpdate] {
        var body: [String: Any] = ["timeout": timeout,
                                   "allowed_updates": ["message", "edited_message", "inline_query", "chosen_inline_result"]]
        if let offset { body["offset"] = offset }
        return try await call("getUpdates", json: body)
    }

    public func sendMessage(chatID: Int64, text: String, replyTo: Int?) async throws -> TGMessage {
        var body: [String: Any] = ["chat_id": chatID, "text": text, "link_preview_options": ["is_disabled": true]]
        if let replyTo { body["reply_parameters"] = ["message_id": replyTo, "allow_sending_without_reply": true] }
        return try await call("sendMessage", json: body)
    }

    public func deleteMessage(chatID: Int64, messageID: Int) async throws {
        let _: Bool = try await call("deleteMessage", json: ["chat_id": chatID, "message_id": messageID])
    }

    public func answerInlineQuery(id: String, results: [TGInlineResult], nextOffset: String?, cacheTime: Int, emptyButton: String?) async throws {
        let resultsJSON = try JSONSerialization.jsonObject(with: encoder.encode(results))
        var body: [String: Any] = ["inline_query_id": id, "results": resultsJSON, "cache_time": cacheTime, "is_personal": true]
        if let nextOffset { body["next_offset"] = nextOffset }
        if let emptyButton { body["button"] = ["text": emptyButton, "start_parameter": "inline"] }
        let _: Bool = try await call("answerInlineQuery", json: body)
    }

    public func setCommands(_ commands: [TGCommand]) async throws {
        let list = commands.map { ["command": $0.command, "description": $0.description] }
        let _: Bool = try await call("setMyCommands", json: ["commands": list])
    }

    public func getFile(fileID: String) async throws -> TGFile { try await call("getFile", json: ["file_id": fileID]) }

    public func download(filePath: String) async throws -> Data {
        let url = base.appendingPathComponent("file/bot\(token)").appendingPathComponent(filePath)
        let (data, status) = try await perform(URLRequest(url: url))
        guard status == 200 else { throw TelegramError("download \(filePath): HTTP \(status)") }
        return data
    }

    /// multipart/form-data upload (sendPhoto / sendVideo / …).
    public func sendMedia(_ kind: TGMediaKind, chatID: Int64, file: URL, silent: Bool) async throws -> TGMessage {
        let boundary = "memebooru-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("chat_id", String(chatID))
        if silent { field("disable_notification", "true") }
        let bytes = try Data(contentsOf: file)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(kind.field)\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: methodURL(kind.method))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await decode(kind.method, try await perform(req).0)
    }
}

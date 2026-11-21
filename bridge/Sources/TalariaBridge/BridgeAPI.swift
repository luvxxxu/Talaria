import Foundation

/// The HTTP API the Hermes plugin talks to.
///
///     GET  /health                         -> {"ok": true, "cursor": N, "version": "...", "typing": "off"|"ui"}
///     GET  /events?after=<id>&timeout=<s>  -> {"events": [...], "cursor": N}  (long poll)
///     POST /send {"text", "chat_guid"?, "to"?} -> {"ok": true}
///     POST /typing {"chat_guid"?, "to"?, "active"?} -> {"ok": true, "enabled": Bool}
///
/// Every request needs `Authorization: Bearer <TALARIA_TOKEN>`. Messages are only
/// accepted from, and only sent to, handles in the allowlist.
public struct BridgeAPI: Sendable {
    public static let defaultWait = 25.0
    public static let maxWait = 55.0
    public static let maxTextScalars = 20_000

    public typealias ChatLookupFunction = @Sendable (String) -> String?

    public let hub: EventHub
    public let sender: any MessageSending
    public let policy: AccessPolicy
    /// Finds the existing 1:1 chat for a handle when /send only names `to`.
    private let chatLookup: ChatLookupFunction?
    /// nil when TALARIA_TYPING is off: /typing then answers `enabled: false`.
    private let typing: TypingController?
    private let expectedAuthorization: [UInt8]

    public init(hub: EventHub, sender: any MessageSending, policy: AccessPolicy, token: String,
                chatLookup: ChatLookupFunction? = nil, typing: TypingController? = nil) {
        self.hub = hub
        self.sender = sender
        self.policy = policy
        self.chatLookup = chatLookup
        self.typing = typing
        self.expectedAuthorization = Array("Bearer \(token)".utf8)
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let authorization = request.headers["authorization"]
        guard authorized(authorization) else {
            let reason = Self.authorizationProblem(authorization)
            Log.warning("rejected \(request.method) \(request.path): \(reason)")
            return .json(401, ["error": "unauthorized", "reason": reason])
        }
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .json(200, ["ok": true, "cursor": await hub.cursor, "version": bridgeVersion,
                               "typing": (typing == nil ? TypingMode.off : .ui).rawValue])
        case ("GET", "/events"):
            return await events(request.query)
        case ("POST", "/send"):
            return await send(request.body)
        case ("POST", "/typing"):
            return await typingRequest(request.body)
        default:
            return .json(404, ["error": "not found"])
        }
    }

    /// Why a request failed authorization, without revealing anything about the token.
    static func authorizationProblem(_ header: String?) -> String {
        guard let header, !header.isEmpty else {
            return "no Authorization header"
        }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.first?.lowercased() == "bearer" else {
            return "Authorization must be 'Bearer <TALARIA_TOKEN>'"
        }
        guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else {
            return "empty Bearer token (is the token variable set in the client's shell?)"
        }
        return "token does not match TALARIA_TOKEN"
    }

    /// Constant-time comparison of the Authorization header.
    func authorized(_ header: String?) -> Bool {
        let given = Array((header ?? "").utf8)
        guard given.count == expectedAuthorization.count else { return false }
        var difference: UInt8 = 0
        for index in given.indices {
            difference |= given[index] ^ expectedAuthorization[index]
        }
        return difference == 0
    }

    private func events(_ query: [String: String]) async -> HTTPResponse {
        let badParameters = HTTPResponse.json(400, ["error": "after must be an integer and timeout a number"])
        var after = await hub.cursor
        if let raw = query["after"] {
            guard let value = Int64(raw) else { return badParameters }
            after = value
        }
        var timeout = Self.defaultWait
        if let raw = query["timeout"] {
            guard let value = Double(raw), value.isFinite else { return badParameters }
            timeout = min(max(value, 0), Self.maxWait)
        }
        let (events, cursor) = await hub.wait(after: after, timeout: timeout)
        return .json(200, encoding: EventsBody(events: events, cursor: cursor))
    }

    private func parseBody(_ data: Data) -> Result<[String: Any], HTTPResponseError> {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data.isEmpty ? Data("{}".utf8) : data)
        } catch {
            return .failure(HTTPResponseError(.json(400, ["error": "body must be JSON"])))
        }
        guard let body = parsed as? [String: Any] else {
            return .failure(HTTPResponseError(.json(400, ["error": "body must be a JSON object"])))
        }
        return .success(body)
    }

    private func typingRequest(_ data: Data) async -> HTTPResponse {
        let body: [String: Any]
        switch parseBody(data) {
        case .success(let parsed): body = parsed
        case .failure(let error): return error.response
        }
        let active: Bool
        switch body["active"] {
        case nil, is NSNull: active = true
        case let value as Bool: active = value
        default: return .json(400, ["error": "active must be true or false"])
        }
        let handle: String
        switch resolveTarget(body) {
        case .success(let target): handle = target.1
        case .failure(.badRequest(let reason)): return .json(400, ["error": reason])
        case .failure(.forbidden(let reason)): return .json(403, ["error": reason])
        }
        guard let typing else {
            return .json(200, ["ok": true, "enabled": false])
        }
        if active {
            await typing.request(handle: handle)
        } else {
            await typing.cancel(handle: handle)
        }
        return .json(200, ["ok": true, "enabled": true])
    }

    private func send(_ data: Data) async -> HTTPResponse {
        let body: [String: Any]
        switch parseBody(data) {
        case .success(let parsed): body = parsed
        case .failure(let error): return error.response
        }
        guard let text = body["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .json(400, ["error": "text is required"])
        }
        guard text.unicodeScalars.count <= Self.maxTextScalars else {
            return .json(400, ["error": "text longer than \(Self.maxTextScalars) characters"])
        }

        var chatGUID: String?
        let handle: String
        switch resolveTarget(body) {
        case .success(let target):
            (chatGUID, handle) = target
            if chatGUID == nil { chatGUID = chatLookup?(handle) }
        case .failure(.badRequest(let reason)):
            return .json(400, ["error": reason])
        case .failure(.forbidden(let reason)):
            return .json(403, ["error": reason])
        }

        // Take the typing placeholder out first, so it isn't left behind the reply.
        await typing?.clearNow()
        do {
            try await sender.sendText(text, chatGUID: chatGUID, handle: handle)
        } catch {
            Log.error("send to \(handle) failed: \(error)")
            return .json(502, ["error": "\(error)"])
        }
        Log.info("sent message to \(handle)")
        return .json(200, ["ok": true])
    }

    enum TargetError: Error {
        case badRequest(String)
        case forbidden(String)
    }

    /// Validates a /send body and returns (chat GUID, handle).
    func resolveTarget(_ body: [String: Any]) -> Result<(String?, String), TargetError> {
        func optionalString(_ key: String) -> Result<String?, TargetError> {
            switch body[key] {
            case nil, is NSNull: return .success(nil)
            case let value as String: return .success(value.isEmpty ? nil : value)
            default: return .failure(.badRequest("\(key) must be a string"))
            }
        }
        let chatGUID: String?
        var handle: String?
        switch (optionalString("chat_guid"), optionalString("to")) {
        case (.failure(let error), _), (_, .failure(let error)):
            return .failure(error)
        case (.success(let guid), .success(let to)):
            chatGUID = guid
            handle = to
        }

        if let chatGUID {
            guard let chatHandle = handleFromChatGUID(chatGUID) else {
                return .failure(.forbidden("group chats are not supported"))
            }
            if let handle, normalizeHandle(handle) != normalizeHandle(chatHandle) {
                return .failure(.badRequest("to does not match chat_guid"))
            }
            handle = chatHandle
        }
        guard let handle else {
            return .failure(.badRequest("chat_guid or to is required"))
        }
        guard policy.isAllowed(handle) else {
            return .failure(.forbidden("recipient is not in TALARIA_ALLOWED_HANDLES"))
        }
        return .success((chatGUID, handle))
    }
}

struct HTTPResponseError: Error {
    let response: HTTPResponse
    init(_ response: HTTPResponse) { self.response = response }
}

private struct EventsBody: Encodable {
    var events: [IncomingMessage]
    var cursor: Int64
}

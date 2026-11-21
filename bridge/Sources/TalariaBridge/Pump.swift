import Foundation

/// Polls chat.db and keeps only allowed, recent, 1:1 messages.
///
/// `cursor` is the highest ROWID already looked at. It moves past every row,
/// including dropped ones, so nothing is examined twice. Not thread-safe.
public final class MessagePump: @unchecked Sendable {
    public typealias DropHandler = (IncomingMessage, String) -> Void

    public let db: ChatDB
    public let policy: AccessPolicy
    public var cursor: Int64
    public var maxAge: Double
    private let onDropped: DropHandler
    private let clock: () -> Double

    public init(db: ChatDB, policy: AccessPolicy, cursor: Int64, maxAge: Double,
                onDropped: DropHandler? = nil,
                clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.db = db
        self.policy = policy
        self.cursor = cursor
        self.maxAge = maxAge
        self.onDropped = onDropped ?? { message, reason in
            Log.info("dropped message \(message.rowid) from \(message.sender): \(reason)")
        }
        self.clock = clock
    }

    public func poll() throws -> [IncomingMessage] {
        let top = try db.maxRowID()
        if top < cursor {
            // chat.db was recreated (e.g. Messages signed out and back in).
            Log.warning("chat.db ROWID went backwards (\(cursor) -> \(top)); resetting cursor")
            cursor = top
            return []
        }
        if top == cursor { return [] }

        var accepted: [IncomingMessage] = []
        for message in try db.fetchIncoming(after: cursor, upTo: top) {
            if let reason = rejectReason(message) {
                onDropped(message, reason)
            } else {
                accepted.append(message)
            }
        }
        cursor = top
        return accepted
    }

    private func rejectReason(_ message: IncomingMessage) -> String? {
        if message.isGroup { return "group chat" }
        if !policy.isAllowed(message.sender) { return "sender not in TALARIA_ALLOWED_HANDLES" }
        let age = clock() - message.timestamp
        if maxAge > 0 && age > maxAge {
            return "older than \(Int(maxAge))s (\(Int(age))s)"
        }
        return nil
    }
}

/// Persists the pump cursor so messages that arrive while the bridge is down are
/// still delivered after a restart (subject to the max-age limit).
public struct CursorStore: Sendable {
    public let path: String

    public init(path: String) {
        self.path = expandingTilde(path)
    }

    public func load() -> Int64? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cursor = object["cursor"] as? NSNumber else { return nil }
        return cursor.int64Value
    }

    public func save(_ cursor: Int64) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["cursor": cursor])
        try data.write(to: url, options: .atomic)
    }
}

import Foundation
import SQLite3

/// Seconds between the Unix epoch (1970) and Apple's reference date (2001-01-01).
public let appleEpochOffset: Double = 978_307_200
private let chatStyleGroup: Int64 = 43

public let fullDiskAccessHint = """
    Cannot read chat.db. Grant Full Disk Access to the app running this (Terminal, \
    or the talaria-bridge binary under launchd) in System Settings > Privacy & Security > \
    Full Disk Access, then restart it. If Messages was never signed in for this macOS \
    user, the file does not exist yet.
    """

private let incomingSQL = """
    SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.service,
           m.cache_has_attachments, h.id, c.guid, c.chat_identifier, c.style
    FROM message m
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    LEFT JOIN chat c ON c.ROWID = cmj.chat_id
    WHERE m.ROWID > ? AND m.ROWID <= ?
      AND m.is_from_me = 0
      AND COALESCE(m.item_type, 0) = 0
      AND COALESCE(m.associated_message_type, 0) = 0
    ORDER BY m.ROWID
    """

private let attachmentsSQL = """
    SELECT a.filename, a.mime_type, a.transfer_name
    FROM attachment a
    JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
    WHERE maj.message_id = ?
    """

public struct ChatDBError: Error, CustomStringConvertible, Sendable {
    public let description: String

    static func access(_ detail: String) -> ChatDBError {
        ChatDBError(description: "\(fullDiskAccessHint) (\(detail))")
    }
}

public struct Attachment: Equatable, Sendable, Encodable {
    public var path: String?
    public var mimeType: String?
    public var name: String?

    enum CodingKeys: String, CodingKey {
        case path, mimeType = "mime_type", name
    }

    // Encode missing values as null so the JSON shape never changes.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(name, forKey: .name)
    }
}

public struct IncomingMessage: Equatable, Sendable, Encodable {
    public var rowid: Int64
    public var guid: String
    public var sender: String
    public var text: String
    public var chatGUID: String?
    public var chatIdentifier: String?
    public var isGroup: Bool
    public var timestamp: Double
    public var service: String?
    public var attachments: [Attachment]

    public init(rowid: Int64, guid: String, sender: String, text: String, chatGUID: String?,
                chatIdentifier: String?, isGroup: Bool, timestamp: Double, service: String?,
                attachments: [Attachment] = []) {
        self.rowid = rowid
        self.guid = guid
        self.sender = sender
        self.text = text
        self.chatGUID = chatGUID
        self.chatIdentifier = chatIdentifier
        self.isGroup = isGroup
        self.timestamp = timestamp
        self.service = service
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case rowid, guid, sender, text, timestamp, service, attachments
        case chatGUID = "chat_guid", chatIdentifier = "chat_identifier", isGroup = "is_group"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rowid, forKey: .rowid)
        try container.encode(guid, forKey: .guid)
        try container.encode(sender, forKey: .sender)
        try container.encode(text, forKey: .text)
        try container.encode(chatGUID, forKey: .chatGUID)
        try container.encode(chatIdentifier, forKey: .chatIdentifier)
        try container.encode(isGroup, forKey: .isGroup)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(service, forKey: .service)
        try container.encode(attachments, forKey: .attachments)
    }
}

/// Converts a `message.date` value to a Unix timestamp.
public func appleTimeToUnix(_ value: Int64?) -> Double {
    guard let value, value != 0 else { return 0 }
    var seconds = Double(value)
    // Since macOS 10.13 the column holds nanoseconds; older rows hold seconds.
    if seconds > 1e12 { seconds /= 1e9 }
    return seconds + appleEpochOffset
}

/// Read-only access to Messages' chat.db. Not thread-safe: one owner at a time.
public final class ChatDB: @unchecked Sendable {
    public let path: String
    private var handle: OpaquePointer?

    public init(path: String) {
        self.path = expandingTilde(path)
    }

    deinit { close() }

    public func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    public func maxRowID() throws -> Int64 {
        var value: Int64 = 0
        try query("SELECT COALESCE(MAX(ROWID), 0) FROM message") { value = sqlite3_column_int64($0, 0) }
        return value
    }

    /// Incoming messages with `after < ROWID <= upTo`, oldest first.
    ///
    /// Own messages, tapbacks and group events are filtered out here; who is
    /// allowed to talk to the bot is decided by the caller.
    public func fetchIncoming(after: Int64, upTo: Int64) throws -> [IncomingMessage] {
        struct Row {
            var rowid: Int64, guid: String, text: String?, body: Data?, date: Int64?, service: String?
            var hasAttachments: Bool, sender: String?, chatGUID: String?, chatIdentifier: String?, style: Int64?
        }
        var rows: [Row] = []
        try query(incomingSQL, [after, upTo]) { stmt in
            rows.append(Row(
                rowid: sqlite3_column_int64(stmt, 0),
                guid: columnText(stmt, 1) ?? "",
                text: columnText(stmt, 2),
                body: columnBlob(stmt, 3),
                date: columnInt(stmt, 4),
                service: columnText(stmt, 5),
                hasAttachments: (columnInt(stmt, 6) ?? 0) != 0,
                sender: columnText(stmt, 7),
                chatGUID: columnText(stmt, 8),
                chatIdentifier: columnText(stmt, 9),
                style: columnInt(stmt, 10)
            ))
        }

        var messages: [IncomingMessage] = []
        var seen = Set<Int64>()
        for row in rows {
            guard let sender = row.sender, !sender.isEmpty, seen.insert(row.rowid).inserted else { continue }
            var text = row.text ?? ""
            if text.isEmpty {
                text = AttributedBody.text(from: row.body) ?? ""
            }
            // Messages puts U+FFFC in the text where an attachment sits inline.
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let attachments = row.hasAttachments ? try fetchAttachments(of: row.rowid) : []
            if text.isEmpty && attachments.isEmpty { continue }
            messages.append(IncomingMessage(
                rowid: row.rowid,
                guid: row.guid,
                sender: sender,
                text: text,
                chatGUID: row.chatGUID,
                chatIdentifier: row.chatIdentifier,
                isGroup: row.style == chatStyleGroup,
                timestamp: appleTimeToUnix(row.date),
                service: row.service,
                attachments: attachments
            ))
        }
        return messages
    }

    /// GUID of the most recent 1:1 chat with `handle`, if Messages has one.
    ///
    /// Sending to an existing chat by its id is more reliable than sending to a
    /// bare participant, which recent macOS versions sometimes reject or drop.
    public func directChatGUID(for handle: String) throws -> String? {
        let wanted = normalizeHandle(handle)
        var match: String?
        try query("SELECT guid, chat_identifier FROM chat WHERE COALESCE(style, 0) != \(chatStyleGroup) ORDER BY ROWID DESC") { stmt in
            guard match == nil, let guid = columnText(stmt, 0), let identifier = columnText(stmt, 1),
                  handleFromChatGUID(guid) != nil, normalizeHandle(identifier) == wanted else { return }
            match = guid
        }
        return match
    }

    private func fetchAttachments(of rowid: Int64) throws -> [Attachment] {
        var result: [Attachment] = []
        try query(attachmentsSQL, [rowid]) { stmt in
            result.append(Attachment(
                path: columnText(stmt, 0).map(expandingTilde),
                mimeType: columnText(stmt, 1),
                name: columnText(stmt, 2)
            ))
        }
        return result
    }

    private func connection() throws -> OpaquePointer {
        if let handle { return handle }
        // No existence check first: without Full Disk Access, macOS hides the
        // file and a "not found" error would point at the wrong problem.
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (\(rc))"
            sqlite3_close_v2(db)
            throw ChatDBError.access(detail)
        }
        sqlite3_busy_timeout(db, 5000)
        handle = db
        return db
    }

    private func query(_ sql: String, _ params: [Int64] = [], row: (OpaquePointer) throws -> Void) throws {
        let db = try connection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let detail = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(statement)
            close()
            throw ChatDBError.access(detail)
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in params.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), value)
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try row(statement)
            case SQLITE_DONE:
                return
            default:
                let detail = String(cString: sqlite3_errmsg(db))
                close()
                throw ChatDBError.access(detail)
            }
        }
    }
}

/// Thread-safe chat lookups on a separate connection from the watcher's.
public final class ChatLookup: @unchecked Sendable {
    private let db: ChatDB
    private let lock = NSLock()

    public init(path: String) {
        db = ChatDB(path: path)
    }

    public func directChatGUID(for handle: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try db.directChatGUID(for: handle)
        } catch {
            Log.warning("chat lookup for \(handle) failed: \(error)")
            return nil
        }
    }
}

private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let pointer = sqlite3_column_text(statement, index) else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
}

private func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let pointer = sqlite3_column_blob(statement, index) else { return nil }
    return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
}

private func columnInt(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(statement, index)
}

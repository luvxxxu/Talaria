import Foundation
import SQLite3
import XCTest
@testable import TalariaBridge

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Real NSArchiver output for NSMutableAttributedString, made by scripts/generate-fixtures.swift.
func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func appleNanoseconds(_ unixTime: Double = Date().timeIntervalSince1970) -> Int64 {
    Int64((unixTime - appleEpochOffset) * 1e9)
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("talaria-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func message(rowid: Int64, text: String, sender: String = "me@icloud.com") -> IncomingMessage {
    IncomingMessage(rowid: rowid, guid: "MSG-\(rowid)", sender: sender, text: text,
                    chatGUID: "any;-;\(sender)", chatIdentifier: sender, isGroup: false,
                    timestamp: Date().timeIntervalSince1970, service: "iMessage")
}

/// A throwaway chat.db with the subset of Messages' schema the bridge reads.
final class FakeChatDB {
    static let schema = """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, service TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, chat_identifier TEXT, style INTEGER);
        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT, text TEXT, attributedBody BLOB,
            handle_id INTEGER, is_from_me INTEGER DEFAULT 0, date INTEGER, service TEXT,
            item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0,
            cache_has_attachments INTEGER DEFAULT 0
        );
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, mime_type TEXT, transfer_name TEXT);
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        """

    let path: String
    private var db: OpaquePointer?
    private var guidCounter = 0

    init(directory: URL) throws {
        path = directory.appendingPathComponent("chat.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw failure("open") }
        guard sqlite3_exec(db, Self.schema, nil, nil, nil) == SQLITE_OK else { throw failure("schema") }
    }

    deinit { sqlite3_close(db) }

    func handle(_ address: String) throws -> Int64 {
        try insert("INSERT INTO handle (id, service) VALUES (?, 'iMessage')", [address])
    }

    func chat(_ guid: String, _ identifier: String, group: Bool = false) throws -> Int64 {
        try insert("INSERT INTO chat (guid, chat_identifier, style) VALUES (?, ?, ?)", [guid, identifier, group ? 43 : 45])
    }

    @discardableResult
    func message(chat: Int64, handle: Int64, text: String?, body: Data? = nil, fromMe: Bool = false,
                 sentAt: Double? = nil, itemType: Int = 0, associatedType: Int = 0,
                 attachment: String? = nil) throws -> Int64 {
        guidCounter += 1
        let rowid = try insert(
            """
            INSERT INTO message (guid, text, attributedBody, handle_id, is_from_me, date, service,
                                 item_type, associated_message_type, cache_has_attachments)
            VALUES (?, ?, ?, ?, ?, ?, 'iMessage', ?, ?, ?)
            """,
            ["MSG-\(guidCounter)", text, body, handle, fromMe ? 1 : 0,
             appleNanoseconds(sentAt ?? Date().timeIntervalSince1970),
             itemType, associatedType, attachment == nil ? 0 : 1]
        )
        try insert("INSERT INTO chat_message_join VALUES (?, ?)", [chat, rowid])
        if let attachment {
            let attachmentID = try insert(
                "INSERT INTO attachment (filename, mime_type, transfer_name) VALUES (?, 'image/jpeg', 'photo.jpg')",
                [attachment]
            )
            try insert("INSERT INTO message_attachment_join VALUES (?, ?)", [rowid, attachmentID])
        }
        return rowid
    }

    @discardableResult
    private func insert(_ sql: String, _ values: [Any?]) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure("prepare") }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            guard let value else {
                sqlite3_bind_null(statement, index)
                continue
            }
            switch value {
            case let text as String:
                sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case let data as Data:
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), sqliteTransient) }
            case let number as Int:
                sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Int64:
                sqlite3_bind_int64(statement, index, number)
            default:
                XCTFail("unsupported value \(value)")
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("insert") }
        return sqlite3_last_insert_rowid(db)
    }

    private func failure(_ step: String) -> Error {
        NSError(domain: "FakeChatDB", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(step): \(String(cString: sqlite3_errmsg(db)))"])
    }
}

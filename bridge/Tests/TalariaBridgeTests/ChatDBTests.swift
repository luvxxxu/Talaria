import XCTest
@testable import TalariaBridge

final class ChatDBTests: XCTestCase {
    let me = "me@icloud.com"
    var directory: URL!
    var fake: FakeChatDB!
    var meHandle: Int64 = 0
    var dm: Int64 = 0
    var db: ChatDB!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
        fake = try FakeChatDB(directory: directory)
        meHandle = try fake.handle(me)
        dm = try fake.chat("any;-;\(me)", me)
        db = ChatDB(path: fake.path)
    }

    override func tearDownWithError() throws {
        db.close()
        fake = nil
        try FileManager.default.removeItem(at: directory)
    }

    func fetchAll() throws -> [IncomingMessage] {
        try db.fetchIncoming(after: 0, upTo: db.maxRowID())
    }

    func testPlainTextMessage() throws {
        let rowid = try fake.message(chat: dm, handle: meHandle, text: "hi bot")
        let messages = try fetchAll()
        XCTAssertEqual(messages.count, 1)
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(message.rowid, rowid)
        XCTAssertEqual(message.sender, me)
        XCTAssertEqual(message.text, "hi bot")
        XCTAssertEqual(message.chatGUID, "any;-;\(me)")
        XCTAssertFalse(message.isGroup)
        XCTAssertEqual(message.timestamp, Date().timeIntervalSince1970, accuracy: 5)
    }

    func testTextOnlyInAttributedBody() throws {
        try fake.message(chat: dm, handle: meHandle, text: nil, body: try fixture("korean"))
        XCTAssertEqual(try fetchAll().map(\.text), ["안녕하세요 Hermes 👋"])
    }

    func testSkipsOwnMessagesTapbacksAndEvents() throws {
        try fake.message(chat: dm, handle: meHandle, text: "sent by bot", fromMe: true)
        try fake.message(chat: dm, handle: meHandle, text: "Loved “hi”", associatedType: 2000)
        try fake.message(chat: dm, handle: meHandle, text: nil, itemType: 1)
        XCTAssertEqual(try fetchAll(), [])
    }

    func testGroupMessagesAreFlagged() throws {
        let group = try fake.chat("any;+;chat123", "chat123", group: true)
        try fake.message(chat: group, handle: meHandle, text: "hello group")
        XCTAssertEqual(try fetchAll().map(\.isGroup), [true])
    }

    func testAttachmentOnlyMessage() throws {
        try fake.message(chat: dm, handle: meHandle, text: "\u{FFFC}", attachment: "~/Library/Messages/Attachments/a/b/photo.jpg")
        let message = try XCTUnwrap(try fetchAll().first)
        XCTAssertEqual(message.text, "")
        XCTAssertEqual(message.attachments.count, 1)
        let path = try XCTUnwrap(message.attachments.first?.path)
        XCTAssertTrue(path.hasSuffix("Library/Messages/Attachments/a/b/photo.jpg"))
        XCTAssertFalse(path.hasPrefix("~"))
        XCTAssertEqual(message.attachments.first?.mimeType, "image/jpeg")
    }

    func testRangeIsRespected() throws {
        let first = try fake.message(chat: dm, handle: meHandle, text: "one")
        try fake.message(chat: dm, handle: meHandle, text: "two")
        XCTAssertEqual(try db.fetchIncoming(after: first, upTo: db.maxRowID()).map(\.text), ["two"])
    }

    func testDirectChatLookup() throws {
        _ = try fake.chat("any;+;chat999", "+821012345678", group: true)
        _ = try fake.chat("iMessage;-;+821012345678", "+821012345678")
        _ = try fake.chat("any;-;+821012345678", "+821012345678")
        XCTAssertEqual(try db.directChatGUID(for: "+82 10-1234-5678"), "any;-;+821012345678")
        XCTAssertEqual(try db.directChatGUID(for: "ME@icloud.com"), "any;-;\(me)")
        XCTAssertNil(try db.directChatGUID(for: "+15550001111"))
        XCTAssertEqual(ChatLookup(path: fake.path).directChatGUID(for: "+821012345678"), "any;-;+821012345678")
        XCTAssertNil(ChatLookup(path: directory.appendingPathComponent("missing/chat.db").path).directChatGUID(for: me))
    }

    func testUnreadableDatabase() {
        let missing = ChatDB(path: directory.appendingPathComponent("missing/chat.db").path)
        XCTAssertThrowsError(try missing.maxRowID()) { error in
            XCTAssertTrue(error is ChatDBError)
        }
    }

    func testAppleTime() {
        let now = Date().timeIntervalSince1970
        XCTAssertEqual(appleTimeToUnix(appleNanoseconds(now)), now, accuracy: 0.001)
        XCTAssertEqual(appleTimeToUnix(0), 0)
        XCTAssertEqual(appleTimeToUnix(nil), 0)
    }

    func testJSONShapeMatchesTheAPI() throws {
        var incoming = message(rowid: 7, text: "hi")
        incoming.chatIdentifier = nil
        incoming.attachments = [Attachment(path: "/tmp/a.jpg", mimeType: nil, name: "a.jpg")]
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(incoming)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys ?? [:].keys), [
            "rowid", "guid", "sender", "text", "chat_guid", "chat_identifier",
            "is_group", "timestamp", "service", "attachments",
        ])
        XCTAssertTrue(object?["chat_identifier"] is NSNull)
        let attachment = (object?["attachments"] as? [[String: Any]])?.first
        XCTAssertTrue(attachment?["mime_type"] is NSNull)
    }
}

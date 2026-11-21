import XCTest
@testable import TalariaBridge

final class PolicyTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(normalizeHandle(" Me@iCloud.com "), "me@icloud.com")
        XCTAssertEqual(normalizeHandle("+82 10-1234-5678"), "+821012345678")
        XCTAssertEqual(normalizeHandle("tel:+821012345678"), "+821012345678")
        XCTAssertEqual(normalizeHandle("mailto:me@icloud.com"), "me@icloud.com")
    }

    func testAllowlist() {
        let policy = AccessPolicy(["me@icloud.com", "+82 10 1234 5678", " "])
        XCTAssertEqual(policy.count, 2)
        XCTAssertTrue(policy.isAllowed("ME@icloud.com"))
        XCTAssertTrue(policy.isAllowed("+821012345678"))
        XCTAssertFalse(policy.isAllowed("+15550001111"))
        XCTAssertFalse(policy.isAllowed(nil))
        XCTAssertFalse(policy.isAllowed(""))
    }

    func testChatGUID() {
        XCTAssertEqual(handleFromChatGUID("any;-;+821012345678"), "+821012345678")
        XCTAssertEqual(handleFromChatGUID("iMessage;-;me@icloud.com"), "me@icloud.com")
        XCTAssertNil(handleFromChatGUID("any;+;chat123456"))
        XCTAssertNil(handleFromChatGUID("any;-;"))
    }
}

final class MessagePumpTests: XCTestCase {
    let me = "me@icloud.com"
    let stranger = "+15550001111"
    var directory: URL!
    var fake: FakeChatDB!
    var db: ChatDB!
    var dropped: [(String, String)] = []
    var pump: MessagePump!
    var meHandle: Int64 = 0, strangerHandle: Int64 = 0
    var dm: Int64 = 0, strangerDM: Int64 = 0, group: Int64 = 0

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
        fake = try FakeChatDB(directory: directory)
        meHandle = try fake.handle(me)
        strangerHandle = try fake.handle(stranger)
        dm = try fake.chat("any;-;\(me)", me)
        strangerDM = try fake.chat("any;-;\(stranger)", stranger)
        group = try fake.chat("any;+;chat1", "chat1", group: true)
        db = ChatDB(path: fake.path)
        pump = MessagePump(db: db, policy: AccessPolicy([me]), cursor: 0, maxAge: 600) { [unowned self] message, reason in
            self.dropped.append((message.text, reason))
        }
    }

    override func tearDownWithError() throws {
        db.close()
        fake = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testOnlyAllowedRecentDirectMessagesPass() throws {
        try fake.message(chat: dm, handle: meHandle, text: "keep me")
        try fake.message(chat: strangerDM, handle: strangerHandle, text: "spam")
        try fake.message(chat: group, handle: meHandle, text: "group hello")
        try fake.message(chat: dm, handle: meHandle, text: "too old", sentAt: Date().timeIntervalSince1970 - 3600)
        let last = try fake.message(chat: dm, handle: meHandle, text: "mine", fromMe: true)

        XCTAssertEqual(try pump.poll().map(\.text), ["keep me"])
        XCTAssertEqual(dropped.map(\.0), ["spam", "group hello", "too old"])
        XCTAssertEqual(pump.cursor, last)
        XCTAssertEqual(try pump.poll(), [])
    }

    func testMaxAgeZeroDisablesTheCheck() throws {
        pump.maxAge = 0
        try fake.message(chat: dm, handle: meHandle, text: "very old", sentAt: Date().timeIntervalSince1970 - 86400)
        XCTAssertEqual(try pump.poll().map(\.text), ["very old"])
    }

    func testCursorResetsWhenDatabaseShrinks() throws {
        pump.cursor = 500
        XCTAssertEqual(try pump.poll(), [])
        XCTAssertEqual(pump.cursor, 0)
    }

    func testCursorStoreRoundTrip() throws {
        let store = CursorStore(path: directory.appendingPathComponent("nested/state.json").path)
        XCTAssertNil(store.load())
        try store.save(42)
        XCTAssertEqual(store.load(), 42)
    }
}

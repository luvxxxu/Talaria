import Foundation
import XCTest
@testable import TalariaBridge

actor FakeTypingDriver: TypingDriver {
    private(set) var calls: [String] = []
    private var beginResult = true

    func setBeginResult(_ value: Bool) { beginResult = value }

    func begin(handle: String) async -> Bool {
        calls.append("begin \(handle)")
        return beginResult
    }

    func refresh() async { calls.append("refresh") }
    func end() async { calls.append("end") }
}

func eventually(timeout: Double = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

final class TypingControllerTests: XCTestCase {
    var driver: FakeTypingDriver!
    var controller: TypingController!

    override func setUp() {
        driver = FakeTypingDriver()
        controller = TypingController(driver: driver, lease: 0.3, refreshEvery: 60, retryAfterFailure: 0.6, tick: 0.02)
    }

    override func tearDown() async throws {
        await controller.stop()
    }

    func testBeginsOnceWhileRequestsKeepComingThenEndsWhenTheyStop() async {
        for _ in 0..<5 {
            await controller.request(handle: "+821012345678")
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let ended = await eventually { await self.driver.calls.contains("end") }
        XCTAssertTrue(ended)
        let calls = await driver.calls
        XCTAssertEqual(calls, ["begin +821012345678", "end"])
    }

    func testCancelEndsTyping() async {
        await controller.request(handle: "me@icloud.com")
        let began = await eventually { await self.driver.calls.count == 1 }
        XCTAssertTrue(began)
        await controller.cancel(handle: "ME@icloud.com")
        let ended = await eventually { await self.driver.calls.last == "end" }
        XCTAssertTrue(ended)
        let active = await controller.activeHandle
        XCTAssertNil(active)
    }

    func testSwitchingChatsEndsTheOldOneFirst() async {
        await controller.request(handle: "a@icloud.com")
        _ = await eventually { await self.driver.calls.count == 1 }
        await controller.request(handle: "b@icloud.com")
        let switched = await eventually { await self.driver.calls.count == 3 }
        XCTAssertTrue(switched)
        let calls = await driver.calls
        XCTAssertEqual(calls, ["begin a@icloud.com", "end", "begin b@icloud.com"])
    }

    func testClearNowWaitsForThePlaceholderToGo() async {
        await controller.request(handle: "me@icloud.com")
        _ = await eventually { await self.controller.activeHandle != nil }
        await controller.clearNow()
        let active = await controller.activeHandle
        XCTAssertNil(active)
        let calls = await driver.calls
        XCTAssertEqual(calls.last, "end")
    }

    func testFailedStartBacksOff() async {
        await driver.setBeginResult(false)
        for _ in 0..<8 {
            await controller.request(handle: "me@icloud.com")
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        let calls = await driver.calls
        XCTAssertEqual(calls, ["begin me@icloud.com"])
    }

    func testLongRepliesRefreshTheIndicator() async {
        await controller.stop()
        controller = TypingController(driver: driver, lease: 0.3, refreshEvery: 0.4, tick: 0.02)
        for _ in 0..<12 {
            await controller.request(handle: "me@icloud.com")
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        let calls = await driver.calls
        XCTAssertEqual(calls.first, "begin me@icloud.com")
        XCTAssertTrue(calls.contains("refresh"), "\(calls)")
        XCTAssertFalse(calls.contains("end"))
    }
}

final class TypingEndpointTests: XCTestCase {
    let token = String(repeating: "t", count: 32)
    let me = "+821012345678"

    func request(_ api: BridgeAPI, _ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = await api.handle(HTTPRequest(method: method, path: path, query: [:],
                                                    headers: ["authorization": "Bearer \(token)"], body: data))
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        return (response.status, json)
    }

    func testDisabledByDefault() async throws {
        let api = BridgeAPI(hub: EventHub(), sender: FakeSender(), policy: AccessPolicy([me]), token: token)
        let (status, body) = try await request(api, "POST", "/typing", ["to": me])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["enabled"] as? Bool, false)
        let (_, health) = try await request(api, "GET", "/health")
        XCTAssertEqual(health["typing"] as? String, "off")
    }

    func testStartStopAndClearBeforeSending() async throws {
        let driver = FakeTypingDriver()
        let typing = TypingController(driver: driver, lease: 5, tick: 0.02)
        let sender = FakeSender()
        let api = BridgeAPI(hub: EventHub(), sender: sender, policy: AccessPolicy([me]), token: token, typing: typing)
        defer { Task { await typing.stop() } }

        let (_, health) = try await request(api, "GET", "/health")
        XCTAssertEqual(health["typing"] as? String, "ui")

        let (status, body) = try await request(api, "POST", "/typing", ["chat_guid": "any;-;\(me)", "active": true])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["enabled"] as? Bool, true)
        let began = await eventually { await driver.calls == ["begin \(me)"] }
        XCTAssertTrue(began)

        let (sent, _) = try await request(api, "POST", "/send", ["to": me, "text": "reply"])
        XCTAssertEqual(sent, 200)
        let calls = await driver.calls
        XCTAssertEqual(calls, ["begin \(me)", "end"], "placeholder must be gone before the reply is sent")
        let sends = await sender.calls
        XCTAssertEqual(sends.count, 1)

        _ = try await request(api, "POST", "/typing", ["to": me])
        _ = await eventually { await driver.calls.count == 3 }
        let (stopped, _) = try await request(api, "POST", "/typing", ["to": me, "active": false])
        XCTAssertEqual(stopped, 200)
        let ended = await eventually {
            let calls = await driver.calls
            return calls.last == "end" && calls.count == 4
        }
        XCTAssertTrue(ended)
    }

    func testRejectsStrangersAndBadBodies() async throws {
        let typing = TypingController(driver: FakeTypingDriver())
        let api = BridgeAPI(hub: EventHub(), sender: FakeSender(), policy: AccessPolicy([me]), token: token, typing: typing)
        defer { Task { await typing.stop() } }
        let stranger = try await request(api, "POST", "/typing", ["to": "+15550001111"])
        XCTAssertEqual(stranger.0, 403)
        let group = try await request(api, "POST", "/typing", ["chat_guid": "any;+;chat1"])
        XCTAssertEqual(group.0, 403)
        let badActive = try await request(api, "POST", "/typing", ["to": me, "active": "yes"])
        XCTAssertEqual(badActive.0, 400)
    }
}

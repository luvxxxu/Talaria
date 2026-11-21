import Network
import XCTest
@testable import TalariaBridge

private let token = String(repeating: "t", count: 32)
private let me = "me@icloud.com"

actor FakeSender: MessageSending {
    private(set) var calls: [[String?]] = []
    private var failure: String?

    func fail(with message: String?) { failure = message }

    func sendText(_ text: String, chatGUID: String?, handle: String?) async throws {
        if let failure { throw SendError(failure) }
        calls.append([text, chatGUID, handle])
    }
}

final class ServerTests: XCTestCase {
    var hub: EventHub!
    var sender: FakeSender!
    var server: HTTPServer!
    var base = ""

    override func setUp() async throws {
        hub = EventHub()
        sender = FakeSender()
        let api = BridgeAPI(hub: hub, sender: sender, policy: AccessPolicy([me]), token: token)
        server = try HTTPServer(host: "127.0.0.1", port: 0) { await api.handle($0) }
        let port = try await server.start()
        base = "http://127.0.0.1:\(port)"
    }

    override func tearDown() async throws {
        server.stop()
    }

    func request(_ path: String, body: Any? = nil, rawBody: Data? = nil,
                 authorization: String? = "Bearer \(token)") async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: base + path)!)
        request.timeoutInterval = 15
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if let rawBody {
            request.httpMethod = "POST"
            request.httpBody = rawBody
        }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    func testRequiresToken() async throws {
        let rejected: [(String?, String)] = [
            (nil, "no Authorization header"),
            ("Bearer ", "empty Bearer token"),
            ("Token abc", "must be 'Bearer"),
            ("Bearer wrong", "does not match"),
        ]
        for (authorization, reason) in rejected {
            let (status, body) = try await request("/health", authorization: authorization)
            XCTAssertEqual(status, 401, "\(String(describing: authorization))")
            XCTAssertTrue((body["reason"] as? String ?? "").contains(reason), "\(body)")
        }
        let (status, body) = try await request("/health")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["ok"] as? Bool, true)
        XCTAssertEqual(body["version"] as? String, bridgeVersion)
    }

    func testEventsLongPollWakesOnPublish() async throws {
        await hub.advance(to: 10)
        let hub = self.hub!
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await hub.publish(message(rowid: 11, text: "hi"))
        }
        let started = Date()
        let (status, body) = try await request("/events?after=10&timeout=5")
        XCTAssertEqual(status, 200)
        let events = body["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 1)
        XCTAssertEqual(events?.first?["text"] as? String, "hi")
        XCTAssertEqual(events?.first?["chat_guid"] as? String, "any;-;\(me)")
        XCTAssertEqual(body["cursor"] as? Int, 11)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testEventsTimeoutReturnsCursor() async throws {
        await hub.advance(to: 7)
        let (status, body) = try await request("/events?timeout=0")
        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["events"] as? [Any])?.count, 0)
        XCTAssertEqual(body["cursor"] as? Int, 7)
    }

    func testEventsBadParameters() async throws {
        for path in ["/events?after=abc", "/events?timeout=nan"] {
            let (status, _) = try await request(path)
            XCTAssertEqual(status, 400, path)
        }
    }

    func testSendToAllowedChat() async throws {
        let (status, body) = try await request("/send", body: ["text": "안녕", "chat_guid": "any;-;\(me)"])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["ok"] as? Bool, true)
        let calls = await sender.calls
        XCTAssertEqual(calls, [["안녕", "any;-;\(me)", me]])
    }

    func testSendToAllowedHandle() async throws {
        let (status, _) = try await request("/send", body: ["text": "hi", "to": "ME@icloud.com"])
        XCTAssertEqual(status, 200)
        let calls = await sender.calls
        XCTAssertEqual(calls, [["hi", nil, "ME@icloud.com"]])
    }

    func testSendToHandleUsesExistingChat() async throws {
        let sender = FakeSender()
        let api = BridgeAPI(hub: hub, sender: sender, policy: AccessPolicy(["+821012345678"]), token: token,
                            chatLookup: { $0 == "+821012345678" ? "any;-;+821012345678" : nil })
        let body = try JSONSerialization.data(withJSONObject: ["text": "hi", "to": "+821012345678"])
        let request = HTTPRequest(method: "POST", path: "/send", query: [:],
                                  headers: ["authorization": "Bearer \(token)"], body: body)
        let response = await api.handle(request)
        XCTAssertEqual(response.status, 200)
        let calls = await sender.calls
        XCTAssertEqual(calls, [["hi", "any;-;+821012345678", "+821012345678"]])
    }

    func testSendRejections() async throws {
        let cases: [([String: Any], Int)] = [
            (["text": "hi", "to": "+15550001111"], 403),
            (["text": "hi", "chat_guid": "any;+;chat123"], 403),
            (["text": "hi", "chat_guid": "any;-;\(me)", "to": "+15550001111"], 400),
            (["text": "   ", "to": me], 400),
            (["to": me], 400),
            (["text": "hi"], 400),
            (["text": "hi", "to": ["x"]], 400),
            (["text": String(repeating: "a", count: BridgeAPI.maxTextScalars + 1), "to": me], 400),
        ]
        for (body, expected) in cases {
            let (status, _) = try await request("/send", body: body)
            XCTAssertEqual(status, expected, "\(body)")
        }
        let (notObject, _) = try await request("/send", body: ["a", "b"])
        XCTAssertEqual(notObject, 400)
        let (notJSON, _) = try await request("/send", rawBody: Data("{nope".utf8))
        XCTAssertEqual(notJSON, 400)
        let calls = await sender.calls
        XCTAssertEqual(calls, [])
    }

    func testSendFailureIs502() async throws {
        await sender.fail(with: "Messages got an error")
        let (status, body) = try await request("/send", body: ["text": "hi", "to": me])
        XCTAssertEqual(status, 502)
        XCTAssertTrue((body["error"] as? String ?? "").contains("Messages got an error"))
    }

    func testBodyTooLarge() async throws {
        let big = Data(repeating: UInt8(ascii: "a"), count: HTTPServer.maxBodyBytes + 1)
        let (status, _) = try await request("/send", rawBody: big)
        XCTAssertEqual(status, 413)
    }

    func testUnknownPath() async throws {
        let (status, _) = try await request("/nope")
        XCTAssertEqual(status, 404)
    }

    func testMalformedRequestGets400() async throws {
        let port = try XCTUnwrap(URL(string: base)?.port)
        let reply = try await rawExchange(port: UInt16(port), Data("NONSENSE\r\n\r\n".utf8))
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 400"), reply)
    }

    private func rawExchange(port: UInt16, _ payload: Data) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        connection.send(content: payload, completion: .idempotent)
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: String(decoding: data ?? Data(), as: UTF8.self)) }
            }
        }
    }
}

@MainActor
final class AppleScriptRunnerTests: XCTestCase {
    func testHandlerReceivesArgumentsVerbatim() throws {
        let runner = try AppleScriptRunner(source: """
            on joinargs(a, b)
                return a & "|" & b
            end joinargs
            """)
        let tricky = "안녕 \"quoted\" \\ end tell\nline two"
        XCTAssertEqual(try runner.call("joinArgs", [tricky, "two"]).stringValue, "\(tricky)|two")
    }

    func testErrorsBecomeSendError() throws {
        let runner = try AppleScriptRunner(source: "on fails()\nerror \"boom\"\nend fails")
        XCTAssertThrowsError(try runner.call("fails", [])) { error in
            XCTAssertTrue("\(error)".contains("boom"))
        }
        XCTAssertThrowsError(try AppleScriptRunner(source: "this is not applescript ("))
    }
}

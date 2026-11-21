import Foundation
@preconcurrency import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }

    public static func json<T: Encodable>(_ status: Int, encoding value: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return .json(500, ["error": "could not encode response"])
        }
        return HTTPResponse(status: status, body: data)
    }
}

enum HTTPRequestError: Error {
    case badRequest(String)
    case tooLarge
    case closed
}

/// A deliberately small HTTP/1.1 server: one request per connection
/// (`Connection: close`), Content-Length bodies only, strict size limits.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 256 * 1024
    /// Time a client gets to send its whole request (long polls wait after this).
    static let readTimeout: TimeInterval = 15

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "talaria.http")

    public init(host: String, port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let localPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: localPort)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    /// Starts listening and returns the bound port.
    public func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let listener = self.listener
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.fire() {
                        continuation.resume(throwing: error)
                    } else {
                        Log.error("listener failed: \(error)")
                    }
                case .waiting(let error):
                    // e.g. the Tailscale address isn't up yet.
                    if once.fire() {
                        listener.cancel()
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.readTimeout, execute: timeout)
        let handler = self.handler
        Task {
            let response: HTTPResponse
            do {
                let request = try await Self.readRequest(connection)
                timeout.cancel()
                response = await handler(request)
            } catch HTTPRequestError.badRequest(let reason) {
                timeout.cancel()
                response = .json(400, ["error": reason])
            } catch HTTPRequestError.tooLarge {
                timeout.cancel()
                response = .json(413, ["error": "request too large"])
            } catch {
                connection.cancel()
                return
            }
            await Self.write(response, to: connection)
            connection.cancel()
        }
    }

    static func readRequest(_ connection: NWConnection) async throws -> HTTPRequest {
        let separator = Data("\r\n\r\n".utf8)
        var buffer = Data()
        var headerEnd = buffer.range(of: separator)
        while headerEnd == nil {
            guard buffer.count <= maxHeaderBytes else { throw HTTPRequestError.tooLarge }
            buffer.append(try await receive(connection))
            headerEnd = buffer.range(of: separator)
        }
        guard let headerEnd, headerEnd.lowerBound <= maxHeaderBytes else { throw HTTPRequestError.tooLarge }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            throw HTTPRequestError.badRequest("headers must be UTF-8")
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), requestLine[1].hasPrefix("/") else {
            throw HTTPRequestError.badRequest("malformed request line")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPRequestError.badRequest("malformed header")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil {
            throw HTTPRequestError.badRequest("chunked bodies are not supported")
        }
        var length = 0
        if let raw = headers["content-length"] {
            guard let value = Int(raw), value >= 0 else { throw HTTPRequestError.badRequest("invalid Content-Length") }
            length = value
        }
        guard length <= maxBodyBytes else { throw HTTPRequestError.tooLarge }

        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < length {
            body.append(try await receive(connection))
        }
        body = Data(body.prefix(length))

        let target = String(requestLine[1])
        let components = URLComponents(string: "http://bridge" + target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        return HTTPRequest(
            method: requestLine[0].uppercased(),
            path: components?.path ?? target,
            query: query,
            headers: headers,
            body: body
        )
    }

    private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: HTTPRequestError.closed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func write(_ response: HTTPResponse, to connection: NWConnection) async {
        let head = [
            "HTTP/1.1 \(response.status) \(reasonPhrase(response.status))",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(response.body.count)",
            "Connection: close",
            "Server: TalariaBridge/\(bridgeVersion)",
            "", "",
        ].joined(separator: "\r\n")
        var data = Data(head.utf8)
        data.append(response.body)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 502: return "Bad Gateway"
        default: return "Error"
        }
    }
}

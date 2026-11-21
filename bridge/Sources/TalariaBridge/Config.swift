import Foundation

public struct ConfigError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Bridge settings, read from an env file and TALARIA_* environment variables.
public struct BridgeConfig: Sendable {
    public static let defaultEnvFile = "~/.config/talaria/bridge.env"
    public static let minTokenLength = 24

    public var token = ""
    public var allowedHandles: [String] = []
    public var host = "127.0.0.1"
    public var port: UInt16 = 8790
    public var dbPath = "~/Library/Messages/chat.db"
    public var statePath = "~/Library/Application Support/Talaria/state.json"
    public var pollInterval = 1.0
    public var maxAge = 600.0
    public var typing = TypingMode.off
    public var envFile: String?

    public init() {}

    public func requireToken() throws {
        guard token.count >= Self.minTokenLength else {
            throw ConfigError("""
                TALARIA_TOKEN must be at least \(Self.minTokenLength) characters. \
                Generate one with: talaria-bridge gen-token
                """)
        }
    }

    public func requireAllowlist() throws {
        guard !allowedHandles.isEmpty else {
            throw ConfigError("""
                TALARIA_ALLOWED_HANDLES is empty. Set it to the address(es) your iPhone sends \
                from, e.g. me@icloud.com,+821012345678. Run 'talaria-bridge watch' and text \
                the bot to see the address.
                """)
        }
    }

    /// Env file first, then the process environment on top of it.
    public static func load(envFile: String? = nil,
                            environment: [String: String] = ProcessInfo.processInfo.environment) throws -> BridgeConfig {
        var values: [String: String] = [:]
        var config = BridgeConfig()
        let path = expandingTilde(envFile ?? defaultEnvFile)
        if FileManager.default.fileExists(atPath: path) {
            values.merge(try readEnvFile(path)) { _, new in new }
            config.envFile = path
        } else if envFile != nil {
            throw ConfigError("env file not found: \(path)")
        }
        values.merge(environment.filter { $0.key.hasPrefix("TALARIA_") }) { _, new in new }

        config.token = values["TALARIA_TOKEN", default: ""].trimmingCharacters(in: .whitespaces)
        config.allowedHandles = values["TALARIA_ALLOWED_HANDLES", default: ""]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let host = values["TALARIA_HOST"] { config.host = host.trimmingCharacters(in: .whitespaces) }
        if let raw = values["TALARIA_PORT"] { config.port = try parse(raw, "TALARIA_PORT", UInt16.init) }
        if let raw = values["TALARIA_DB_PATH"] { config.dbPath = raw }
        if let raw = values["TALARIA_STATE_PATH"] { config.statePath = raw }
        if let raw = values["TALARIA_POLL_INTERVAL"] { config.pollInterval = try parse(raw, "TALARIA_POLL_INTERVAL", Double.init) }
        if let raw = values["TALARIA_MAX_AGE_SECONDS"] { config.maxAge = try parse(raw, "TALARIA_MAX_AGE_SECONDS", Double.init) }
        if let raw = values["TALARIA_TYPING"] {
            config.typing = try parse(raw.lowercased(), "TALARIA_TYPING (off or ui)") { TypingMode(rawValue: $0) }
        }
        guard config.pollInterval > 0 else { throw ConfigError("TALARIA_POLL_INTERVAL must be positive") }
        return config
    }

    private static func parse<T>(_ raw: String, _ key: String, _ make: (String) -> T?) throws -> T {
        guard let value = make(raw.trimmingCharacters(in: .whitespaces)) else {
            throw ConfigError("invalid setting \(key)=\(raw)")
        }
        return value
    }
}

/// Parses KEY=VALUE lines; '#' starts a comment line, quotes are optional.
public func readEnvFile(_ path: String) throws -> [String: String] {
    let contents: String
    do {
        contents = try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        throw ConfigError("cannot read \(path): \(error.localizedDescription)")
    }
    var values: [String: String] = [:]
    for (number, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("export ") { line.removeFirst("export ".count) }
        guard let equals = line.firstIndex(of: "=") else {
            throw ConfigError("\(path):\(number + 1): expected KEY=VALUE")
        }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == value.last, first == "'" || first == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        values[key] = value
    }
    return values
}

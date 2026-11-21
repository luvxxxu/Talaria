import Foundation

public let bridgeVersion = "0.3.1"

/// Minimal stderr logger. stderr is unbuffered, so lines show up immediately in
/// launchd's log files.
public enum Log {
    nonisolated(unsafe) public static var verbose = false

    public static func debug(_ message: @autoclosure () -> String) {
        if verbose { write("DEBUG", message()) }
    }

    public static func info(_ message: String) { write("INFO", message) }
    public static func warning(_ message: String) { write("WARNING", message) }
    public static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(level) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// Lets exactly one of several racing callbacks win.
public final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    public init() {}

    public func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

func expandingTilde(_ path: String) -> String {
    NSString(string: path).expandingTildeInPath
}

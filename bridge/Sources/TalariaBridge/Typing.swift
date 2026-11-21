import AppKit
import ApplicationServices
import Foundation

/// How the bridge shows "typing…" while Hermes works on a reply.
public enum TypingMode: String, Sendable {
    /// No typing indicator (default).
    case off
    /// Types a placeholder into the Messages compose field, which makes Messages
    /// send a real typing indicator. Needs Accessibility permission and the bot's
    /// macOS user on screen (not a background fast-user-switch session).
    case ui
}

/// Performs the UI side of a typing indicator. Only the controller calls it, one call at a time.
public protocol TypingDriver: Sendable {
    /// Opens the 1:1 chat with `handle` and starts "typing". True when the placeholder is in place.
    func begin(handle: String) async -> Bool
    /// Re-triggers the indicator for a long-running reply.
    func refresh() async
    /// Removes the placeholder.
    func end() async
}

/// Turns a stream of "still typing" requests into begin / refresh / end calls.
///
/// Hermes asks every ~2 seconds while the agent works. Each request extends a short
/// lease; when requests stop (reply sent, Hermes gone) the lease runs out and the
/// placeholder is removed. A single worker owns all UI work, so requests never
/// block and UI actions never overlap.
public actor TypingController {
    private let driver: any TypingDriver
    private let lease: Double
    private let refreshEvery: Double
    private let retryAfterFailure: Double
    private let tick: UInt64

    private var desired: (handle: String, until: Date)?
    private var actual: (handle: String, since: Date)?
    private var failedHandle: (handle: String, until: Date)?
    private var worker: Task<Void, Never>?

    public init(driver: any TypingDriver, lease: Double = 10, refreshEvery: Double = 30,
                retryAfterFailure: Double = 30, tick: Double = 0.25) {
        self.driver = driver
        self.lease = lease
        self.refreshEvery = refreshEvery
        self.retryAfterFailure = retryAfterFailure
        self.tick = UInt64(tick * 1_000_000_000)
    }

    /// Hermes is (still) working on a reply to `handle`.
    public func request(handle: String) {
        desired = (handle, Date().addingTimeInterval(lease))
        startWorker()
    }

    /// Hermes stopped working on `handle`.
    public func cancel(handle: String) {
        if let desired, normalizeHandle(desired.handle) == normalizeHandle(handle) {
            self.desired = nil
        }
    }

    /// Removes any placeholder before a reply goes out, waiting up to `timeout` seconds.
    public func clearNow(timeout: Double = 3) async {
        desired = nil
        let deadline = Date().addingTimeInterval(timeout)
        while actual != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: tick)
        }
    }

    public var activeHandle: String? { actual?.handle }

    public func stop() {
        worker?.cancel()
        worker = nil
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.reconcile()
                try? await Task.sleep(nanoseconds: self.tick)
            }
        }
    }

    private func reconcile() async {
        let now = Date()
        if let desired, desired.until <= now { self.desired = nil }
        let wanted = desired?.handle

        if let current = actual, wanted.map(normalizeHandle) != normalizeHandle(current.handle) {
            await driver.end()
            actual = nil
        }
        // Re-read state after each await: requests may have arrived meanwhile.
        guard let target = desired?.handle else { return }
        if actual == nil {
            if let failed = failedHandle, failed.until > now, normalizeHandle(failed.handle) == normalizeHandle(target) {
                return
            }
            if await driver.begin(handle: target) {
                actual = (target, Date())
                failedHandle = nil
            } else {
                failedHandle = (target, Date().addingTimeInterval(retryAfterFailure))
            }
        } else if let current = actual, Date().timeIntervalSince(current.since) >= refreshEvery {
            await driver.refresh()
            actual = (current.handle, Date())
        }
    }
}

/// Drives the Messages window through System Events. Experimental: depends on the
/// Messages UI, so a macOS update can break it.
///
/// Safety rules: it only ever types a single "." into the focused compose field
/// (an AXTextArea), only when that field is empty or already holds its own ".",
/// and only deletes that same "." again. It never presses Return.
public struct UITypingDriver: TypingDriver {
    public init() {}

    public func begin(handle: String) async -> Bool {
        guard let url = URL(string: "imessage:" + handle) else { return false }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            Log.warning("typing: could not open the chat in Messages")
            return false
        }
        try? await Task.sleep(nanoseconds: 800_000_000)  // let Messages switch conversations
        let result = await run("typeplaceholder")
        if result != "typed" {
            Log.warning("typing: did not start (\(result))")
        }
        return result == "typed"
    }

    public func refresh() async {
        _ = await run("refreshplaceholder")
    }

    public func end() async {
        let result = await run("clearplaceholder")
        if result != "cleared" {
            Log.debug("typing: clear \(result)")
        }
    }

    private func run(_ handler: String) async -> String {
        await MainActor.run {
            do {
                return try TypingScript.runner().call(handler, []).stringValue ?? ""
            } catch {
                return "error: \(error)"
            }
        }
    }

    /// Whether this process may use Accessibility; `prompt` shows the system dialog.
    @MainActor
    public static func accessibilityTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }
}

@MainActor
enum TypingScript {
    // Every key event is preceded by three checks: Messages is the frontmost app,
    // its focused element is the compose field (AXTextArea), and that field holds
    // exactly what we expect. Key events go to the frontmost app, so skipping any
    // check could type into the wrong place.
    static let source = """
        on bringmessagesfront()
            tell application "Messages" to activate
            delay 0.3
            tell application "System Events"
                return (name of first process whose frontmost is true) is "Messages"
            end tell
        end bringmessagesfront

        on composefield()
            tell application "System Events" to tell process "Messages"
                set target to value of attribute "AXFocusedUIElement"
                if target is missing value then return missing value
                if (value of attribute "AXRole" of target) is not "AXTextArea" then return missing value
                return target
            end tell
        end composefield

        on fieldtext(target)
            tell application "System Events"
                set current to value of attribute "AXValue" of target
            end tell
            if current is missing value then return ""
            return current
        end fieldtext

        on typeplaceholder()
            if not bringmessagesfront() then return "skipped: Messages is not frontmost"
            set target to composefield()
            if target is missing value then return "skipped: the compose field is not focused"
            set current to fieldtext(target)
            if current is "." then return "typed"
            if current is not "" then return "skipped: the compose field has a draft"
            tell application "System Events" to keystroke "."
            return "typed"
        end typeplaceholder

        on clearplaceholder()
            set target to composefield()
            if target is missing value then return "skipped: the compose field is not focused"
            if fieldtext(target) is not "." then return "skipped: no placeholder"
            if not bringmessagesfront() then return "skipped: Messages is not frontmost"
            set target to composefield()
            if target is missing value then return "skipped: the compose field is not focused"
            if fieldtext(target) is not "." then return "skipped: no placeholder"
            tell application "System Events" to key code 51
            return "cleared"
        end clearplaceholder

        on refreshplaceholder()
            if clearplaceholder() is not "cleared" then return "skipped"
            delay 0.3
            return typeplaceholder()
        end refreshplaceholder
        """

    private static var cached: AppleScriptRunner?

    static func runner() throws -> AppleScriptRunner {
        if let cached { return cached }
        let runner = try AppleScriptRunner(source: source)
        cached = runner
        return runner
    }
}

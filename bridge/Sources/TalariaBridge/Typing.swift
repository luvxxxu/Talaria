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


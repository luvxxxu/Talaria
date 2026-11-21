import Foundation

/// Recent accepted messages, with waiting reads for long polling.
public actor EventHub {
    private var events: [IncomingMessage] = []
    private let capacity: Int
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Highest chat.db ROWID the bridge has looked at (dropped rows included).
    public private(set) var cursor: Int64 = 0

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    public func publish(_ message: IncomingMessage) {
        events.append(message)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        cursor = max(cursor, message.rowid)
        wakeAll()
    }

    public func advance(to newCursor: Int64) {
        guard newCursor > cursor else { return }
        cursor = newCursor
        wakeAll()
    }

    /// Messages newer than `after`, waiting up to `timeout` seconds for one to arrive.
    public func wait(after: Int64, timeout: Double) async -> (events: [IncomingMessage], cursor: Int64) {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let found = events.filter { $0.rowid > after }
            let remaining = deadline.timeIntervalSinceNow
            if !found.isEmpty || remaining <= 0 {
                return (found, cursor)
            }
            await waitForChange(atMost: remaining)
        }
    }

    private func waitForChange(atMost seconds: Double) async {
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[id] = continuation
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self.expire(id)
            }
        }
    }

    private func expire(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    private func wakeAll() {
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

/// Feeds the hub from chat.db until cancelled.
public final class Watcher: Sendable {
    private let pump: MessagePump
    private let hub: EventHub
    private let store: CursorStore
    private let pollInterval: Double

    public init(pump: MessagePump, hub: EventHub, store: CursorStore, pollInterval: Double) {
        self.pump = pump
        self.hub = hub
        self.store = store
        self.pollInterval = pollInterval
    }

    public func run() async {
        await hub.advance(to: pump.cursor)
        var failing = false
        while !Task.isCancelled {
            do {
                for message in try pump.poll() {
                    Log.info("message \(message.rowid) from \(message.sender)")
                    await hub.publish(message)
                }
                await hub.advance(to: pump.cursor)
                try store.save(pump.cursor)
                if failing {
                    Log.info("chat.db readable again")
                    failing = false
                }
            } catch let error as ChatDBError {
                if !failing {
                    Log.error(error.description)
                    failing = true
                }
            } catch {
                Log.error("watcher error: \(error)")
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }
}

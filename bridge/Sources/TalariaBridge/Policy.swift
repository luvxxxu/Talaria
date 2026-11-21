import Foundation

// 1:1 chats have GUIDs like "iMessage;-;+821012345678" or "any;-;me@icloud.com";
// group chats use ";+;" instead.
private let directChatSeparator = ";-;"

/// Canonical form for comparison: lowercase emails, bare E.164 phone numbers.
public func normalizeHandle(_ handle: String) -> String {
    var value = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for prefix in ["mailto:", "tel:"] where value.hasPrefix(prefix) {
        value.removeFirst(prefix.count)
    }
    if value.contains("@") { return value }
    return String(value.filter { $0 == "+" || ("0"..."9").contains($0) })
}

/// The other party's handle for a 1:1 chat GUID, or nil for group chats.
public func handleFromChatGUID(_ chatGUID: String) -> String? {
    guard let range = chatGUID.range(of: directChatSeparator, options: .backwards) else { return nil }
    let handle = String(chatGUID[range.upperBound...])
    return handle.isEmpty ? nil : handle
}

/// Who may talk to the bot: a fixed allowlist of iMessage handles.
public struct AccessPolicy: Sendable {
    private let allowed: Set<String>

    public init(_ handles: [String]) {
        allowed = Set(handles
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(normalizeHandle))
    }

    public var count: Int { allowed.count }
    public var isEmpty: Bool { allowed.isEmpty }

    public func isAllowed(_ handle: String?) -> Bool {
        guard let handle, !handle.isEmpty else { return false }
        return allowed.contains(normalizeHandle(handle))
    }
}

import Foundation

public struct SendError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public let automationHint = """
    If this says 'Not authorized to send Apple events', allow the app running this to \
    control Messages in System Settings > Privacy & Security > Automation.
    """

public protocol MessageSending: Sendable {
    func sendText(_ text: String, chatGUID: String?, handle: String?) async throws
}

/// Sends iMessages by calling AppleScript handlers inside this process.
public struct MessagesSender: MessageSending {
    public init() {}

    /// Sends to the existing chat, falling back to the handle.
    public func sendText(_ text: String, chatGUID: String?, handle: String?) async throws {
        guard !text.isEmpty else { throw SendError("text is empty") }
        var attempts: [(label: String, handler: String, target: String)] = []
        if let chatGUID, !chatGUID.isEmpty { attempts.append(("chat", "sendtochat", chatGUID)) }
        if let handle, !handle.isEmpty { attempts.append(("handle", "sendtohandle", handle)) }
        guard !attempts.isEmpty else { throw SendError("chat_guid or handle is required") }

        var errors: [String] = []
        for attempt in attempts {
            do {
                // NSAppleScript must run on the main thread; this also makes sends
                // one at a time, which Messages handles most reliably.
                try await MainActor.run {
                    _ = try MessagesScript.runner().call(attempt.handler, [attempt.target, text])
                }
                Log.debug("sent via \(attempt.label) \(attempt.target)")
                return
            } catch let error as SendError {
                Log.debug("send via \(attempt.label) \(attempt.target) failed: \(error)")
                errors.append("\(attempt.label) \(attempt.target): \(error)")
            }
        }
        throw SendError(errors.joined(separator: "; "))
    }

    /// Number of iMessage accounts in Messages. Triggers the Automation prompt.
    public func iMessageAccountCount() async throws -> Int {
        try await MainActor.run {
            Int(try MessagesScript.runner().call("imessageaccountcount", []).int32Value)
        }
    }
}

@MainActor
enum MessagesScript {
    // Handler names are lowercase: AppleScript matches subroutine events by
    // their lowercased name.
    static let source = """
        on sendtochat(chatId, messageText)
            tell application "Messages"
                send messageText to chat id chatId
            end tell
        end sendtochat

        on sendtohandle(handleId, messageText)
            tell application "Messages"
                set imessageAccount to first account whose service type = iMessage
                send messageText to participant handleId of imessageAccount
            end tell
        end sendtohandle

        on imessageaccountcount()
            tell application "Messages"
                return count (every account whose service type = iMessage)
            end tell
        end imessageaccountcount
        """

    private static var cached: AppleScriptRunner?

    static func runner() throws -> AppleScriptRunner {
        if let cached { return cached }
        let runner = try AppleScriptRunner(source: source)
        cached = runner
        return runner
    }
}

/// Compiles an AppleScript once and calls its handlers with string arguments.
/// Arguments travel as Apple event descriptors, never spliced into source code,
/// so message text can't break out of the script.
@MainActor
public final class AppleScriptRunner {
    private let script: NSAppleScript

    public init(source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw SendError("could not create AppleScript")
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            throw SendError(Self.describe(error))
        }
        self.script = script
    }

    @discardableResult
    public func call(_ handler: String, _ arguments: [String]) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: fourCharCode("ascr"),     // kASAppleScriptSuite
            eventID: fourCharCode("psbr"),        // kASSubroutineEvent
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setDescriptor(NSAppleEventDescriptor(string: handler.lowercased()),
                            forKeyword: fourCharCode("snam"))  // keyASSubroutineName
        let parameters = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            parameters.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        event.setParam(parameters, forKeyword: fourCharCode("----"))  // keyDirectObject

        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error { throw SendError(Self.describe(error)) }
        return result
    }

    private static func describe(_ error: NSDictionary?) -> String {
        let message = error?[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"
        if let number = error?[NSAppleScript.errorNumber] as? Int {
            return "\(message) (\(number))"
        }
        return message
    }
}

private func fourCharCode(_ code: String) -> FourCharCode {
    code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}

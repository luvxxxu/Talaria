import Foundation
import Security
import TalariaBridge

enum CLI {
    static let usage = """
        usage: talaria-bridge [--env-file PATH] [-v] <command>

        commands:
          check                      check chat.db access, the Messages account and settings
          watch                      print incoming messages as they arrive
          send (--to H | --chat G) TEXT
                                     send a test message to an allowed handle or 1:1 chat
          typing --to H [--seconds N]
                                     show "typing…" to an allowed handle for N seconds (TALARIA_TYPING=ui test)
          typing --inspect [--to H]  show what the typing driver sees in the Messages window (types nothing)
          serve                      run the HTTP bridge for Hermes
          gen-token                  print a random token for TALARIA_TOKEN

        options:
          --env-file PATH            settings file (default: ~/.config/talaria/bridge.env)
          -v, --verbose              debug logging
          --version                  print the version
        """

    static func run(_ arguments: [String]) async -> Int32 {
        var args = arguments[...]
        var envFile: String?
        while let first = args.first, first.hasPrefix("-") {
            args.removeFirst()
            switch first {
            case "--env-file":
                guard let value = args.popFirst() else { return fail("--env-file needs a path") }
                envFile = value
            case "-v", "--verbose":
                Log.verbose = true
            case "--version":
                print(bridgeVersion)
                return 0
            case "-h", "--help":
                print(usage)
                return 0
            default:
                return fail("unknown option \(first)")
            }
        }
        guard let command = args.popFirst() else { return fail("missing command") }
        if command == "gen-token" { return genToken() }

        let config: BridgeConfig
        do {
            config = try BridgeConfig.load(envFile: envFile)
        } catch {
            printError("config error: \(error)")
            return 2
        }
        do {
            switch command {
            case "check": return await check(config)
            case "watch": return await watch(config)
            case "send": return await send(config, Array(args))
            case "typing": return await typingTest(config, Array(args))
            case "serve": return try await serve(config)
            default: return fail("unknown command \(command)")
            }
        } catch let error as ConfigError {
            printError("config error: \(error)")
            return 2
        } catch {
            printError("error: \(error)")
            return 1
        }
    }

    // MARK: commands

    static func check(_ config: BridgeConfig) async -> Int32 {
        var ok = true
        print("config file      : \(config.envFile ?? "(none, using defaults/env)")")
        print("listen address   : \(config.host):\(config.port)")
        print("allowed handles  : \(config.allowedHandles.count)")
        print("token            : \(config.token.isEmpty ? "MISSING (needed for serve)" : "set")")

        do {
            let top = try ChatDB(path: config.dbPath).maxRowID()
            print("chat.db          : readable (latest ROWID \(top))")
        } catch {
            ok = false
            print("chat.db          : FAILED\n  \(error)")
        }

        do {
            let count = try await MessagesSender().iMessageAccountCount()
            if count > 0 {
                print("Messages         : \(count) iMessage account(s)")
            } else {
                ok = false
                print("Messages         : no iMessage account. Sign in to Messages with the bot Apple Account.")
            }
        } catch {
            ok = false
            print("Messages         : FAILED\n  \(error)\n  \(automationHint)")
        }

        if config.typing == .ui {
            if await MainActor.run(body: { UITypingDriver.accessibilityTrusted(prompt: true) }) {
                print("typing (ui)      : Accessibility granted")
            } else {
                ok = false
                print("typing (ui)      : Accessibility NOT granted\n  \(accessibilityHint)")
            }
        } else {
            print("typing           : off")
        }
        return ok ? 0 : 1
    }

    static let accessibilityHint = """
        Allow the app running this (Terminal, or talaria-bridge under launchd) in System Settings > \
        Privacy & Security > Accessibility, then restart it.
        """

    static func typingTest(_ config: BridgeConfig, _ arguments: [String]) async -> Int32 {
        var args = arguments[...]
        var to: String?
        var seconds = 8.0
        var inspectOnly = false
        while let arg = args.popFirst() {
            switch arg {
            case "--to": to = args.popFirst()
            case "--inspect": inspectOnly = true
            case "--seconds":
                guard let value = args.popFirst().flatMap(Double.init), value > 0 else {
                    return fail("--seconds needs a positive number")
                }
                seconds = value
            default: return fail("unexpected argument \(arg)")
            }
        }
        if inspectOnly {
            // Read-only: reports what the driver sees, types nothing.
            guard await MainActor.run(body: { UITypingDriver.accessibilityTrusted(prompt: true) }) else {
                printError("Accessibility is not granted. \(accessibilityHint)")
                return 1
            }
            print(await UITypingDriver().inspect(handle: to))
            return 0
        }
        guard let handle = to else { return fail("usage: typing --to HANDLE [--seconds N] | typing --inspect [--to HANDLE]") }
        do {
            try config.requireAllowlist()
        } catch {
            printError("config error: \(error)")
            return 2
        }
        guard AccessPolicy(config.allowedHandles).isAllowed(handle) else {
            printError("\(handle) is not in TALARIA_ALLOWED_HANDLES.")
            return 1
        }
        guard await MainActor.run(body: { UITypingDriver.accessibilityTrusted(prompt: true) }) else {
            printError("Accessibility is not granted. \(accessibilityHint)")
            return 1
        }
        let driver = UITypingDriver()
        print("Opening the chat with \(handle) in Messages and typing a placeholder...")
        guard await driver.begin(handle: handle) else {
            printError("Typing did not start; the warning above says why.")
            return 1
        }
        print("The iPhone should show \"typing…\" for \(Int(seconds)) seconds.")
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await driver.end()
        print("Cleared.")
        return 0
    }

    static func watch(_ config: BridgeConfig) async -> Int32 {
        let db = ChatDB(path: config.dbPath)
        let policy = AccessPolicy(config.allowedHandles)
        let pump: MessagePump
        do {
            pump = MessagePump(db: db, policy: policy, cursor: try db.maxRowID(), maxAge: config.maxAge) { message, reason in
                print("[dropped] \(message.sender): \(reason)")
            }
        } catch {
            printError("\(error)")
            return 1
        }
        if policy.isEmpty {
            print("TALARIA_ALLOWED_HANDLES is empty: every message will show as [dropped] with its sender address.")
        }
        print("Waiting for new messages (Ctrl+C to stop)...")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        while true {
            do {
                for message in try pump.poll() {
                    let when = formatter.string(from: Date(timeIntervalSince1970: message.timestamp))
                    let extra = message.attachments.isEmpty ? "" : " (+\(message.attachments.count) attachment(s))"
                    print("[\(when)] \(message.sender) via \(message.chatGUID ?? "?"): \(message.text)\(extra)")
                }
            } catch {
                printError("\(error)")
                return 1
            }
            try? await Task.sleep(nanoseconds: UInt64(config.pollInterval * 1_000_000_000))
        }
    }

    static func send(_ config: BridgeConfig, _ arguments: [String]) async -> Int32 {
        var args = arguments[...]
        var to: String?
        var chat: String?
        var text: String?
        while let arg = args.popFirst() {
            switch arg {
            case "--to": to = args.popFirst()
            case "--chat": chat = args.popFirst()
            default:
                guard text == nil else { return fail("send takes one TEXT argument (quote it)") }
                text = arg
            }
        }
        guard let text, (to == nil) != (chat == nil) else {
            return fail("usage: send (--to HANDLE | --chat CHAT_GUID) TEXT")
        }
        do {
            try config.requireAllowlist()
        } catch {
            printError("config error: \(error)")
            return 2
        }
        let policy = AccessPolicy(config.allowedHandles)
        guard let handle = to ?? chat.flatMap(handleFromChatGUID) else {
            printError("--chat must be a 1:1 chat GUID like any;-;+821012345678 (as printed by watch).")
            return 1
        }
        guard policy.isAllowed(handle) else {
            printError("""
                \(handle) is not in TALARIA_ALLOWED_HANDLES. Use the address exactly as watch \
                prints it, e.g. +821012345678 rather than 010-1234-5678.
                """)
            return 1
        }
        // Prefer the existing conversation: Messages sends to a chat id more
        // reliably than to a bare participant.
        let chatGUID = chat ?? ChatLookup(path: config.dbPath).directChatGUID(for: handle)
        print("sending to \(handle) via \(chatGUID.map { "chat \($0)" } ?? "participant (no existing chat found)")")
        do {
            try await MessagesSender().sendText(text, chatGUID: chatGUID, handle: handle)
        } catch {
            printError("send failed: \(error)\n\(automationHint)")
            return 1
        }
        print("Messages accepted the message. Check that it arrives on the iPhone.")
        return 0
    }

    static func serve(_ config: BridgeConfig) async throws -> Int32 {
        try config.requireToken()
        try config.requireAllowlist()
        if config.host == "0.0.0.0" || config.host == "::" {
            Log.warning("listening on all interfaces; prefer the Mac's Tailscale IP for TALARIA_HOST")
        }

        let db = ChatDB(path: config.dbPath)
        let store = CursorStore(path: config.statePath)
        let cursor: Int64
        do {
            cursor = try store.load() ?? db.maxRowID()
        } catch {
            Log.error("\(error)")
            return 1
        }

        let policy = AccessPolicy(config.allowedHandles)
        let pump = MessagePump(db: db, policy: policy, cursor: cursor, maxAge: config.maxAge)
        let hub = EventHub()
        let watcher = Watcher(pump: pump, hub: hub, store: store, pollInterval: config.pollInterval)
        var typing: TypingController?
        if config.typing == .ui {
            if !(await MainActor.run(body: { UITypingDriver.accessibilityTrusted(prompt: true) })) {
                Log.warning("TALARIA_TYPING=ui: Accessibility is not granted, so typing will not show. \(accessibilityHint)")
            }
            typing = TypingController(driver: UITypingDriver())
        }
        let lookup = ChatLookup(path: config.dbPath)
        let api = BridgeAPI(hub: hub, sender: MessagesSender(), policy: policy, token: config.token,
                            chatLookup: { lookup.directChatGUID(for: $0) }, typing: typing)
        let server = try HTTPServer(host: config.host, port: config.port) { request in
            await api.handle(request)
        }

        let port: UInt16
        do {
            port = try await server.start()
        } catch {
            Log.error("cannot listen on \(config.host):\(config.port): \(error)")
            return 1
        }
        let watcherTask = Task { await watcher.run() }
        Log.info("Talaria bridge \(bridgeVersion) listening on http://\(config.host):\(port) "
                 + "(\(policy.count) allowed handle(s), typing \(config.typing.rawValue))")

        await waitForTerminationSignal()
        watcherTask.cancel()
        server.stop()
        await typing?.clearNow()
        await typing?.stop()
        Log.info("stopped")
        return 0
    }

    static func genToken() -> Int32 {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return fail("could not generate random bytes")
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        print(token)
        return 0
    }

    // MARK: helpers

    /// Returns on SIGINT or SIGTERM (launchd stops services with SIGTERM).
    static func waitForTerminationSignal() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "talaria.signals")
            let once = OnceFlag()
            for signalNumber in [SIGINT, SIGTERM] {
                signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
                source.setEventHandler {
                    if once.fire() { continuation.resume() }
                }
                source.resume()
                SignalSources.retain(source)
            }
        }
    }

    static func fail(_ message: String) -> Int32 {
        printError("\(message)\n\n\(usage)")
        return 2
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Keeps signal sources alive for the life of the process.
enum SignalSources {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    static func retain(_ source: DispatchSourceSignal) { sources.append(source) }
}

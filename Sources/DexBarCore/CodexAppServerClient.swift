import Foundation

public enum CodexClientError: LocalizedError, Sendable {
    case cliUnavailable
    case launchFailed(String)
    case authenticationRequired
    case server(String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .cliUnavailable:
            return "Codex CLI was not found. Install Codex, then sign in with ChatGPT."
        case .launchFailed(let message):
            return "Could not start Codex: \(message)"
        case .authenticationRequired:
            return "Codex needs you to sign in again."
        case .server(let message):
            return message
        case .malformedResponse:
            return "Codex returned an unreadable usage response."
        }
    }
}

public enum CodexCLI {
    public static var executableURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            environment["DEXBAR_CODEX_PATH"],
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
        ].compactMap { $0 }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }
}

public struct CodexAppServerClient: Sendable {
    private let executableURL: URL?

    public init(executableURL: URL? = CodexCLI.executableURL) {
        self.executableURL = executableURL
    }

    public func fetch(now: Date = Date()) async throws -> UsageSnapshot {
        guard let executableURL else { throw CodexClientError.cliUnavailable }
        let payload = try await Task.detached(priority: .utility) {
            try Self.readPayload(executableURL: executableURL)
        }.value
        return try UsageMapper.snapshot(from: payload, now: now)
    }

    private static func readPayload(executableURL: URL) throws -> AppServerRateLimitsPayload {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do { try process.run() }
        catch { throw CodexClientError.launchFailed(error.localizedDescription) }

        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        func send(_ messages: [[String: Any]]) throws {
            var data = Data()
            for message in messages {
                data.append(try JSONSerialization.data(withJSONObject: message))
                data.append(0x0A)
            }
            input.fileHandleForWriting.write(data)
        }

        var buffer = Data()
        var protocolLines: [String] = []
        func nextObject() -> [String: Any]? {
            while true {
                if let newline = buffer.firstRange(of: Data([0x0A])) {
                    let line = buffer[..<newline.lowerBound]
                    buffer.removeSubrange(...newline.lowerBound)
                    guard !line.isEmpty else { continue }
                    if let text = String(data: line, encoding: .utf8) {
                        protocolLines.append(text)
                    }
                    return try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { return nil }
                buffer.append(chunk)
            }
        }

        try send([[
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": [
                    "name": "dexbar",
                    "title": "DexBar",
                    "version": "0.1.0",
                ],
                "capabilities": [
                    "optOutNotificationMethods": [
                        "thread/started", "item/started", "item/completed",
                        "item/agentMessage/delta", "turn/completed",
                    ],
                ],
            ],
        ]])

        var initialized = false
        while let object = nextObject() {
            guard let id = object["id"] as? NSNumber, id.intValue == 1 else { continue }
            if let error = object["error"] as? [String: Any] {
                throw CodexClientError.server(error["message"] as? String ?? "Codex initialization failed.")
            }
            initialized = object["result"] != nil
            break
        }
        guard initialized else { throw CodexClientError.malformedResponse }

        try send([
            ["method": "initialized", "params": [:]],
            ["method": "account/rateLimits/read", "id": 2],
        ])

        while let object = nextObject() {
            guard let id = object["id"] as? NSNumber, id.intValue == 2 else { continue }
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Codex could not read account limits."
                if message.localizedCaseInsensitiveContains("auth")
                    || message.localizedCaseInsensitiveContains("login") {
                    throw CodexClientError.authenticationRequired
                }
                throw CodexClientError.server(message)
            }
            guard let result = object["result"] else { throw CodexClientError.malformedResponse }
            let data = try JSONSerialization.data(withJSONObject: result)
            do { return try JSONDecoder().decode(AppServerRateLimitsPayload.self, from: data) }
            catch {
                throw CodexClientError.server("Codex usage response changed shape: \(error.localizedDescription)")
            }
        }

        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = String(data: stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(300)
        if let diagnostic, !diagnostic.isEmpty {
            if diagnostic.localizedCaseInsensitiveContains("auth")
                || diagnostic.localizedCaseInsensitiveContains("login") {
                throw CodexClientError.authenticationRequired
            }
            throw CodexClientError.server(String(diagnostic))
        }
        if ProcessInfo.processInfo.environment["DEXBAR_DEBUG_PROTOCOL"] == "1",
           !protocolLines.isEmpty {
            throw CodexClientError.server("No rate-limit result. Protocol output: \(protocolLines.joined(separator: "\n").prefix(2_000))")
        }
        throw CodexClientError.malformedResponse
    }
}

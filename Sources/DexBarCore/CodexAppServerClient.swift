import Foundation
import Darwin

public enum CodexClientError: LocalizedError, Sendable {
    case cliUnavailable
    case launchFailed(String)
    case authenticationRequired
    case timeout
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
        case .timeout:
            return "Codex did not return usage in time."
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

private struct AppServerReadResult {
    let rateLimits: AppServerRateLimitsPayload
    let serviceTier: UsageServiceTier?
}

public struct CodexAppServerClient: Sendable {
    private let executableURL: URL?
    private let requestTimeout: TimeInterval
    private let terminationGrace: TimeInterval

    public init(
        executableURL: URL? = CodexCLI.executableURL,
        requestTimeout: TimeInterval = 15,
        terminationGrace: TimeInterval = 1
    ) {
        self.executableURL = executableURL
        self.requestTimeout = requestTimeout
        self.terminationGrace = terminationGrace
    }

    public func fetch(now: Date = Date()) async throws -> UsageSnapshot {
        guard let executableURL else { throw CodexClientError.cliUnavailable }
        let payload = try await Task.detached(priority: .utility) {
            try Self.readPayload(
                executableURL: executableURL,
                requestTimeout: requestTimeout,
                terminationGrace: terminationGrace
            )
        }.value
        return try UsageMapper.snapshot(
            from: payload.rateLimits,
            serviceTier: payload.serviceTier,
            now: now
        )
    }

    private static func readPayload(
        executableURL: URL,
        requestTimeout: TimeInterval,
        terminationGrace: TimeInterval
    ) throws -> AppServerReadResult {
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

        let controller = ChildProcessController(
            process: process,
            input: input.fileHandleForWriting,
            errors: errors.fileHandleForReading,
            terminationGrace: terminationGrace
        )
        process.terminationHandler = { [weak controller] _ in controller?.noteExit() }

        do { try process.run() }
        catch { throw CodexClientError.launchFailed(error.localizedDescription) }

        controller.startCollectingErrors()
        controller.armTimeout(after: requestTimeout)
        defer { controller.shutdown() }

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
                    let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                    if ProcessInfo.processInfo.environment["DEXBAR_DEBUG_PROTOCOL"] == "1",
                       protocolLines.count < 64,
                       let object {
                        let id = (object["id"] as? NSNumber)?.stringValue ?? "notification"
                        let keys = object.keys.sorted().joined(separator: ",")
                        protocolLines.append("response id=\(id) keys=\(keys)")
                    }
                    return object
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
                    "version": Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "development",
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
        if controller.didTimeOut { throw CodexClientError.timeout }
        guard initialized else { throw CodexClientError.malformedResponse }

        try send([
            ["method": "initialized", "params": [:]],
            ["method": "config/read", "id": 2, "params": ["includeLayers": false]],
            ["method": "account/rateLimits/read", "id": 3],
        ])

        var serviceTier: UsageServiceTier?
        while let object = nextObject() {
            guard let id = object["id"] as? NSNumber else { continue }
            switch id.intValue {
            case 2:
                guard object["error"] == nil, let result = object["result"],
                      let data = try? JSONSerialization.data(withJSONObject: result),
                      let payload = try? JSONDecoder().decode(AppServerConfigReadPayload.self, from: data)
                else { continue }
                serviceTier = UsageServiceTier(appServerValue: payload.config.serviceTier)
            case 3:
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
                do {
                    let rateLimits = try JSONDecoder().decode(AppServerRateLimitsPayload.self, from: data)
                    if controller.didTimeOut { throw CodexClientError.timeout }
                    return AppServerReadResult(rateLimits: rateLimits, serviceTier: serviceTier)
                } catch let error as CodexClientError {
                    throw error
                } catch {
                    throw CodexClientError.server("Codex usage response changed shape: \(error.localizedDescription)")
                }
            default:
                continue
            }
        }

        controller.shutdown()
        if controller.didTimeOut { throw CodexClientError.timeout }
        let stderr = controller.collectedErrors
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
            throw CodexClientError.server("No rate-limit result. Protocol summary: \(protocolLines.joined(separator: "\n").prefix(2_000))")
        }
        throw CodexClientError.malformedResponse
    }
}

private final class ChildProcessController: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let errors: FileHandle
    private let terminationGrace: TimeInterval
    private let exitSemaphore = DispatchSemaphore(value: 0)
    private let collectorGroup = DispatchGroup()
    private let lock = NSLock()

    private var timeoutWork: DispatchWorkItem?
    private var stopped = false
    private var timedOut = false
    private var errorData = Data()

    init(
        process: Process,
        input: FileHandle,
        errors: FileHandle,
        terminationGrace: TimeInterval
    ) {
        self.process = process
        self.input = input
        self.errors = errors
        self.terminationGrace = max(0.05, terminationGrace)
    }

    var didTimeOut: Bool {
        lock.withLock { timedOut }
    }

    var collectedErrors: Data {
        lock.withLock { errorData }
    }

    func noteExit() {
        exitSemaphore.signal()
    }

    func startCollectingErrors() {
        collectorGroup.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer { self.collectorGroup.leave() }
            while true {
                let chunk = self.errors.availableData
                guard !chunk.isEmpty else { return }
                self.lock.withLock {
                    let remaining = max(0, 64 * 1_024 - self.errorData.count)
                    if remaining > 0 { self.errorData.append(chunk.prefix(remaining)) }
                }
            }
        }
    }

    func armTimeout(after interval: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.expire() }
        lock.withLock { timeoutWork = work }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0.05, interval),
            execute: work
        )
    }

    func shutdown() {
        let shouldStop = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            timeoutWork?.cancel()
            return true
        }
        guard shouldStop else { return }

        try? input.close()
        if process.isRunning { process.terminate() }
        if exitSemaphore.wait(timeout: .now() + terminationGrace) == .timedOut,
           process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = exitSemaphore.wait(timeout: .now() + terminationGrace)
        }
        process.terminationHandler = nil
        _ = collectorGroup.wait(timeout: .now() + terminationGrace)
    }

    private func expire() {
        let shouldTerminate = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            timedOut = true
            return true
        }
        guard shouldTerminate, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminationGrace) { [weak self] in
            guard let self, self.process.isRunning else { return }
            Darwin.kill(self.process.processIdentifier, SIGKILL)
        }
    }
}

import Foundation
import CoreServices

/// Watches Codex session files only to choose a fresher polling cadence. The rate-limit
/// read is free and does not create an inference turn, so activity is an optimisation,
/// not a safety boundary.
final class ActivityMonitor {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.victorrodrigues.DexBar.fsevents", qos: .utility)
    private let lock = NSLock()
    private var storedLastActivity: Date
    private let onActivity: () -> Void

    var lastActivity: Date {
        lock.lock(); defer { lock.unlock() }
        return storedLastActivity
    }
    var idleFor: TimeInterval { Date().timeIntervalSince(lastActivity) }

    init(onActivity: @escaping () -> Void) {
        self.onActivity = onActivity
        let sessions = Self.sessionsURL
        storedLastActivity = (try? sessions.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        start()
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private static var sessionsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private func start() {
        let watched = Self.sessionsURL
        guard FileManager.default.fileExists(atPath: watched.path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ActivityMonitor>.fromOpaque(info).takeUnretainedValue().noteActivity()
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [watched.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    private func noteActivity() {
        lock.lock()
        storedLastActivity = Date()
        lock.unlock()
        onActivity()
    }
}

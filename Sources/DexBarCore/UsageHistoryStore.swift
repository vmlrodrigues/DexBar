import Foundation
import CryptoKit

/// A cumulative allowance reading at an absolute instant. No recording time zone or
/// local-day key is stored; cycle identity is resolved once, before any presentation.
struct UsageHistoryReading: Codable, Equatable, Sendable {
    let windowID: String
    let timestamp: Date
    let usedPercent: Double
    let resetsAt: Date
    let durationMinutes: Int
    let cycleStartedAt: Date
    let cycleStartKnown: Bool
}

public final class UsageHistoryStore {
    private struct Document: Codable {
        var schemaVersion = 2
        var timestampEncoding = "unixSecondsUTC"
        var readings: [UsageHistoryReading] = []
        var legacyIntervals: [LegacyUsageInterval]? = []
        // Optional additions preserve compatibility with existing UTC documents.
        // Bind legacy observations on first identified refresh; future identity
        // changes establish a forecast cutoff without deleting daily history.
        var projectionIdentity: String?
        var projectionHistorySince: Date?
        var projectionIdentityUnavailable: Bool?
    }

    /// Older schema-2 writers discard unfamiliar inline fields. Keep the scope
    /// separately, with a checkpoint that cannot bless their later observations.
    private struct ForecastScope: Codable {
        var schemaVersion = 1
        var timestampEncoding = "unixSecondsUTC"
        var identity: String?
        var historySince: Date?
        var identityUnavailable: Bool
        var recordedThrough: Date?
        var readingsHash: String?
    }

    private var document = Document()
    private let url: URL?
    private let legacyURL: URL?
    private let calendar: Calendar
    private let retention: TimeInterval
    private var canPersist = true
    private var durableForecastScope: ForecastScope?
    private var forecastScopeBlocked = false
    private var forecastScopeNeedsFreshBaseline = false
    private var forecastScopeError: String?
    private var isLoading = false
    private var pendingHistoryPersistence = false
    private var forecastScopeURL: URL? { url?.appendingPathExtension("forecast-scope.json") }
    private struct PresentationCache {
        let calendar: Calendar
        let reducer: UsageHistoryAccumulator
        var readingCount: Int
    }
    private var presentationCache: PresentationCache?
    public private(set) var persistenceError: String?

    public convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DexBar", isDirectory: true)
        // Older releases silently replace an unfamiliar schema. A separate file
        // prevents a rollback or stale login item from destroying the UTC readings.
        self.init(url: directory.appendingPathComponent("usage-readings.json"),
                  legacyURL: directory.appendingPathComponent("usage-history.json"))
    }

    public init(url: URL, calendar: Calendar = .autoupdatingCurrent,
                retention: TimeInterval = 13 * 7 * 86_400, legacyURL: URL? = nil) {
        self.url = url
        self.legacyURL = legacyURL
        self.calendar = calendar
        self.retention = retention
        isLoading = true
        loadForecastScope()
        defer { finishLoadingForecastScope() }
        let source = FileManager.default.fileExists(atPath: url.path) ? url : (legacyURL ?? url)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            let data = try Data(contentsOf: source)
            let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            switch header?["schemaVersion"] as? Int {
            case 2:
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                document = try decoder.decode(Document.self, from: data)
                guard document.timestampEncoding == "unixSecondsUTC",
                      document.readings.allSatisfy(Self.isValid) else {
                    throw CocoaError(.coderReadCorrupt)
                }
                document.readings.sort { $0.timestamp < $1.timestamp }
                let repaired = Self.repairCorrectionSplits(document.readings)
                if repaired != document.readings {
                    // A failed backup must not turn a valid document into an empty one.
                    do { try backup(data, kind: "v2") }
                    catch {
                        canPersist = false
                        persistenceError = "Could not back up usage history before repair: \(error.localizedDescription)"
                        return
                    }
                    document.readings = repaired
                    persist()
                }
                // Recover summary evidence omitted by the first UTC development
                // builds without replacing their newer readings.
                if document.legacyIntervals == nil, let legacyURL,
                   let bytes = try? Data(contentsOf: legacyURL),
                   let legacy = try? UsageHistoryAccumulator(legacyData: bytes) {
                    try backup(data, kind: "v2")
                    let cycles = Set(document.readings.map { CycleKey(windowID: $0.windowID, start: $0.cycleStartedAt) })
                    document.legacyIntervals = Self.intervals(from: legacy).filter {
                        cycles.contains(CycleKey(windowID: $0.windowID, start: $0.cycleStartedAt))
                    }
                    persist()
                }
            case 1:
                let legacy = try UsageHistoryAccumulator(legacyData: data)
                // Back up the exact original bytes before replacing the v1 document.
                try backup(data, kind: "v1")
                let projectionURL = url.deletingLastPathComponent().appendingPathComponent("projection-history.json")
                let projection = (try? Data(contentsOf: projectionURL))
                    .flatMap { try? JSONDecoder().decode([ProjectionSample].self, from: $0) } ?? []
                document.readings = Self.migrate(legacy, projection: projection)
                document.legacyIntervals = Self.intervals(from: legacy)
                persist()
            case .some:
                // A newer app may own this schema. Never overwrite it with an empty history.
                canPersist = false
                persistenceError = "Usage history was written by a newer DexBar version."
            case .none:
                throw CocoaError(.coderReadCorrupt)
            }
        } catch {
            // Preserve unreadable data for recovery too. If the backup cannot be made,
            // leave the original untouched and keep this session's readings in memory.
            do {
                try backup(try Data(contentsOf: source), kind: "unreadable")
                document = Document()
            } catch {
                canPersist = false
            }
            persistenceError = "Could not load usage history: \(error.localizedDescription)"
        }
    }

    private init(calendar: Calendar) {
        url = nil
        legacyURL = nil
        self.calendar = calendar
        retention = 13 * 7 * 86_400
    }

    public static func inMemory(calendar: Calendar = .autoupdatingCurrent) -> UsageHistoryStore {
        UsageHistoryStore(calendar: calendar)
    }

    public func record(_ snapshot: UsageSnapshot) {
        let previousLatest = document.readings.map(\.timestamp).max()
        guard ingest(window: snapshot.weekly, at: snapshot.fetchedAt) else { return }
        updateProjectionIdentity(snapshot, previousLatest: previousLatest)
        trim(relativeTo: snapshot.fetchedAt)
        persist()
    }

    /// Weekly forecasts share the daily view's canonical UTC allowance identity.
    /// Only recent measured readings contribute; local calendar boundaries do not.
    public func weeklyProjection(for snapshot: UsageSnapshot) -> Projection? {
        guard !forecastScopeBlocked, !forecastScopeNeedsFreshBaseline, forecastScopeError == nil else { return nil }
        let now = snapshot.fetchedAt
        let identity = Self.projectionIdentity(for: snapshot)
        // Rejected duplicate/out-of-order polls must not expose another account's
        // mature current-cycle forecast, or replay evidence from a future clock.
        guard identity == document.projectionIdentity,
              document.readings.last(where: { $0.windowID == snapshot.weekly.id })?.timestamp == now else {
            return nil
        }
        let cutoff = max(now.addingTimeInterval(-8 * 86_400), document.projectionHistorySince ?? .distantPast)
        let readings = document.readings.filter {
            $0.windowID == snapshot.weekly.id && $0.durationMinutes == snapshot.weekly.durationMinutes
                && $0.timestamp >= cutoff && $0.timestamp <= now
        }
        let groups = Dictionary(grouping: readings, by: \.cycleStartedAt)
        let cycles = groups.values.compactMap { group -> WeeklyProjectionCycle? in
            guard let first = group.first else { return nil }
            return WeeklyProjectionCycle(startsAt: first.cycleStartedAt, startKnown: first.cycleStartKnown,
                durationMinutes: first.durationMinutes,
                samples: group.map {
                    ProjectionSample(windowID: $0.windowID, timestamp: $0.timestamp,
                                     usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
                })
        }.sorted { $0.samples[0].timestamp < $1.samples[0].timestamp }
        return ProjectionCalculator.weekly(window: snapshot.weekly, cycles: cycles, now: now,
            allowHistorical: identity != nil && identity == document.projectionIdentity)
    }

    private static func projectionIdentity(for snapshot: UsageSnapshot) -> String? {
        guard let account = snapshot.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !account.isEmpty else { return nil }
        let plan = snapshot.planType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let data = try? JSONEncoder().encode([account, plan])
        return data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    private func updateProjectionIdentity(_ snapshot: UsageSnapshot, previousLatest: Date?) {
        let identity = Self.projectionIdentity(for: snapshot)
        // A poll can be fresh for a newly selected bucket while the clock is
        // behind another bucket's old observations. Exclude every prior-scope
        // reading, including those whose timestamps are still in the future.
        let cutoff: Date
        if let previousLatest, previousLatest >= snapshot.fetchedAt {
            // The persisted Unix epoch can have a larger ULP than Date's reference
            // epoch. Advance both so JSON round trips retain a strict exclusion.
            cutoff = max(
                Date(timeIntervalSinceReferenceDate: previousLatest.timeIntervalSinceReferenceDate.nextUp),
                Date(timeIntervalSince1970: previousLatest.timeIntervalSince1970.nextUp)
            )
        } else {
            cutoff = snapshot.fetchedAt
        }
        // An older writer may have appended observations after the durable
        // checkpoint. Only a new accepted identified/unknown reading can bind
        // this session again; calendar replay and repairs cannot do so.
        if forecastScopeNeedsFreshBaseline {
            document.projectionHistorySince = cutoff
            forecastScopeNeedsFreshBaseline = false
        }
        if identity == nil {
            if document.projectionIdentityUnavailable != true {
                document.projectionHistorySince = cutoff
            }
            document.projectionIdentity = nil
            document.projectionIdentityUnavailable = true
        } else {
            if document.projectionIdentityUnavailable == true
                || (document.projectionIdentity != nil && document.projectionIdentity != identity) {
                document.projectionHistorySince = cutoff
            }
            document.projectionIdentity = identity
            document.projectionIdentityUnavailable = false
        }
    }

    /// Backfill only a genuinely new history. A migrated document already incorporates
    /// the available projection samples; repeated launches must not import them again.
    public func backfill(samples: [ProjectionSample], for window: UsageWindow) {
        guard !document.readings.contains(where: { $0.windowID == window.id }) else { return }
        var changed = false
        for sample in samples.filter({ $0.windowID == window.id }).sorted(by: { $0.timestamp < $1.timestamp }) {
            let historicalWindow = UsageWindow(
                id: window.id, bucketID: window.bucketID, bucketName: window.bucketName,
                usedPercent: sample.usedPercent, durationMinutes: window.durationMinutes,
                resetsAt: sample.resetsAt
            )
            changed = ingest(window: historicalWindow, at: sample.timestamp) || changed
        }
        if changed {
            trim(relativeTo: document.readings.map(\.timestamp).max() ?? Date())
            persist()
        }
    }

    /// Changing calendars only changes this derived view; it never mutates stored readings.
    public func windows(for windowID: String, calendar displayCalendar: Calendar? = nil) -> [UsageHistoryWindow] {
        // Freeze an autoupdating calendar into a value. Otherwise a cached
        // reducer could quietly change zones while retaining its old local days.
        let requested = displayCalendar ?? calendar
        var frozen = Calendar(identifier: requested.identifier)
        frozen.timeZone = TimeZone(identifier: requested.timeZone.identifier) ?? requested.timeZone
        frozen.locale = requested.locale
        if presentationCache?.calendar != frozen {
            presentationCache = PresentationCache(calendar: frozen, reducer: UsageHistoryAccumulator(calendar: frozen), readingCount: 0)
        }
        var cache = presentationCache!
        for reading in document.readings.dropFirst(cache.readingCount) { cache.reducer.append(reading) }
        cache.readingCount = document.readings.count
        presentationCache = cache
        return cache.reducer.windows(for: windowID).map { window in
            Self.applying(document.legacyIntervals ?? [], to: window, calendar: frozen)
        }
    }

    public func clear() {
        document = Document()
        presentationCache = nil
        canPersist = true
        persistenceError = nil
        durableForecastScope = nil
        forecastScopeBlocked = false
        forecastScopeNeedsFreshBaseline = false
        forecastScopeError = nil
        pendingHistoryPersistence = false
        guard let url else { return }
        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            // Otherwise clearing followed by a relaunch would re-import the retired file.
            if let legacyURL, manager.fileExists(atPath: legacyURL.path) { try manager.removeItem(at: legacyURL) }
            if let forecastScopeURL, manager.fileExists(atPath: forecastScopeURL.path) {
                try manager.removeItem(at: forecastScopeURL)
            }
            // Clear automatic migration backups along with the live history.
            let siblings = try manager.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            for file in siblings where file.lastPathComponent.hasPrefix(url.lastPathComponent + ".v1-backup-")
                || file.lastPathComponent.hasPrefix(url.lastPathComponent + ".unreadable-backup-")
                || file.lastPathComponent.hasPrefix(url.lastPathComponent + ".v2-backup-") {
                try manager.removeItem(at: file)
            }
        } catch {
            forecastScopeBlocked = true
            forecastScopeError = "Could not clear usage history: \(error.localizedDescription)"
            persistenceError = forecastScopeError
        }
    }

    private func ingest(window: UsageWindow, at timestamp: Date) -> Bool {
        guard window.usedPercent.isFinite, window.usedPercent >= 0,
              window.durationMinutes > 0, window.durationMinutes <= 525_600,
              timestamp <= window.resetsAt.addingTimeInterval(60) else { return false }
        let previous = document.readings.last { $0.windowID == window.id }
        // A timestamp is immutable. Duplicate and out-of-order polls cannot change a cycle.
        guard previous == nil || timestamp > previous!.timestamp else { return false }
        let highWater = previous.map { previous in
            document.readings.lazy.filter {
                $0.windowID == previous.windowID && $0.cycleStartedAt == previous.cycleStartedAt
            }.map(\.usedPercent).max() ?? previous.usedPercent
        } ?? window.usedPercent
        let sameCycle = previous.map {
            Self.isSameCycle(previous: $0, percent: window.usedPercent, reset: window.resetsAt,
                             duration: window.durationMinutes, at: timestamp, highWater: highWater)
        } ?? false
        let start: Date
        let known: Bool
        if let previous, sameCycle {
            start = previous.cycleStartedAt
            known = previous.cycleStartKnown
        } else {
            let reportedStart = window.resetsAt.addingTimeInterval(-Double(window.durationMinutes) * 60)
            known = reportedStart <= timestamp.addingTimeInterval(60)
                && (previous == nil || reportedStart > previous!.timestamp)
            start = known ? reportedStart : timestamp
        }
        if let last = document.readings.last, timestamp < last.timestamp { presentationCache = nil }
        document.readings.append(UsageHistoryReading(
            windowID: window.id, timestamp: timestamp, usedPercent: window.usedPercent,
            resetsAt: window.resetsAt, durationMinutes: window.durationMinutes,
            cycleStartedAt: start, cycleStartKnown: known
        ))
        // Persist quiet polls as well: they establish baselines around midnight in
        // any time zone, including one the user has not visited yet.
        return true
    }

    private static func isSameCycle(previous: UsageHistoryReading, percent: Double, reset: Date,
                                    duration: Int, at timestamp: Date, highWater: Double) -> Bool {
        guard previous.durationMinutes == duration, highWater - percent <= 2 else { return false }
        // Only a new downward movement needs the stricter correction check. A flat
        // or recovering reading still follows normal schedule-revision rules, even
        // if it has not yet reached the previous peak.
        if percent < previous.usedPercent {
            return isSmallCorrection(previous: previous, percent: percent,
                                     reset: reset, at: timestamp, highWater: highWater)
        }
        if abs(previous.resetsAt.timeIntervalSince(reset)) < 60 { return true }
        let reportedStart = reset.addingTimeInterval(-Double(duration) * 60)
        if previous.usedPercent > 0,
           reportedStart > previous.timestamp.addingTimeInterval(60),
           reportedStart <= timestamp.addingTimeInterval(60) { return false }
        return timestamp < previous.resetsAt
    }

    // Match the forecast's two-percentage-point tolerance, but require the same
    // unexpired reset schedule. Use the cycle peak so repeated dips cannot ratchet
    // the baseline down indefinitely. This is a heuristic, not an upstream guarantee.
    private static func isSmallCorrection(previous: UsageHistoryReading, percent: Double,
                                          reset: Date, at timestamp: Date, highWater: Double) -> Bool {
        highWater - percent <= 2
            && abs(previous.resetsAt.timeIntervalSince(reset)) < 60
            && timestamp < previous.resetsAt
    }

    /// Repair only the uncertain boundaries that older builds invented at a small
    /// dip. Keep all raw percentages, timestamps, and independently known resets.
    private static func repairCorrectionSplits(_ readings: [UsageHistoryReading]) -> [UsageHistoryReading] {
        var latest: [String: UsageHistoryReading] = [:]
        var peaks: [CycleKey: Double] = [:]
        var replacements: [CycleKey: UsageHistoryReading] = [:]
        return readings.map { reading in
            let key = CycleKey(windowID: reading.windowID, start: reading.cycleStartedAt)
            if replacements[key] == nil, !reading.cycleStartKnown,
               reading.cycleStartedAt == reading.timestamp,
               let previous = latest[reading.windowID],
               previous.cycleStartedAt != reading.cycleStartedAt,
               previous.durationMinutes == reading.durationMinutes,
               reading.usedPercent < peaks[CycleKey(windowID: previous.windowID, start: previous.cycleStartedAt), default: previous.usedPercent],
               isSameCycle(previous: previous, percent: reading.usedPercent,
                   reset: reading.resetsAt, duration: reading.durationMinutes, at: reading.timestamp,
                   highWater: peaks[CycleKey(windowID: previous.windowID, start: previous.cycleStartedAt)] ?? previous.usedPercent) {
                replacements[key] = previous
            }
            let replacement = replacements[key]
            let repaired = UsageHistoryReading(windowID: reading.windowID, timestamp: reading.timestamp,
                usedPercent: reading.usedPercent, resetsAt: reading.resetsAt, durationMinutes: reading.durationMinutes,
                cycleStartedAt: replacement?.cycleStartedAt ?? reading.cycleStartedAt,
                cycleStartKnown: replacement?.cycleStartKnown ?? reading.cycleStartKnown)
            latest[reading.windowID] = repaired
            let canonical = CycleKey(windowID: repaired.windowID, start: repaired.cycleStartedAt)
            peaks[canonical] = max(peaks[canonical] ?? repaired.usedPercent, repaired.usedPercent)
            return repaired
        }
    }

    private static func isValid(_ reading: UsageHistoryReading) -> Bool {
        reading.usedPercent.isFinite && reading.usedPercent >= 0
            && reading.durationMinutes > 0 && reading.durationMinutes <= 525_600
            && reading.timestamp.timeIntervalSince1970.isFinite
            && reading.resetsAt.timeIntervalSince1970.isFinite
            && reading.cycleStartedAt.timeIntervalSince1970.isFinite
            && reading.cycleStartedAt <= reading.timestamp.addingTimeInterval(60)
            && reading.timestamp <= reading.resetsAt.addingTimeInterval(60)
    }

    private func trim(relativeTo now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        let previousCount = document.readings.count
        let groups = Dictionary(grouping: document.readings) { CycleKey(windowID: $0.windowID, start: $0.cycleStartedAt) }
        document.readings = groups.values.flatMap { readings -> [UsageHistoryReading] in
            guard let last = readings.last, last.timestamp >= cutoff else { return [] }
            // Keep the last baseline before the cutoff for a cycle still in progress.
            let baseline = readings.last { $0.timestamp < cutoff }
            return (baseline.map { [$0] } ?? []) + readings.filter { $0.timestamp >= cutoff }
        }.sorted { $0.timestamp < $1.timestamp }
        if document.readings.count != previousCount { presentationCache = nil }
        document.legacyIntervals?.removeAll { $0.intervalEnd < cutoff }
    }

    private func backup(_ data: Data, kind: String) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("\(kind)-backup-\(UUID().uuidString).json")
        try data.write(to: backup, options: .withoutOverwriting)
    }

    private func persist() {
        if isLoading {
            pendingHistoryPersistence = true
            return
        }
        guard canPersist, let url else { return }
        guard !forecastScopeBlocked else {
            persistenceError = forecastScopeError
            return
        }
        // Initial repairs must not advance a checkpoint past unscoped readings.
        guard !forecastScopeNeedsFreshBaseline, persistForecastScope() else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(document).write(to: url, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = "Could not save usage history: \(error.localizedDescription)" }
    }

    private func loadForecastScope() {
        guard let forecastScopeURL, FileManager.default.fileExists(atPath: forecastScopeURL.path) else { return }
        do {
            let data = try Data(contentsOf: forecastScopeURL)
            let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard header?["schemaVersion"] as? Int == 1 else {
                forecastScopeBlocked = true
                forecastScopeError = "Weekly forecast scope was written by an unsupported DexBar version."
                persistenceError = forecastScopeError
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let scope = try decoder.decode(ForecastScope.self, from: data)
            func validHash(_ value: String) -> Bool {
                value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
            }
            guard scope.timestampEncoding == "unixSecondsUTC",
                  scope.identity.map(validHash) ?? scope.identityUnavailable,
                  scope.identity == nil || !scope.identityUnavailable,
                  scope.historySince.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  scope.recordedThrough.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  scope.readingsHash.map(validHash) ?? true else {
                throw CocoaError(.coderReadCorrupt)
            }
            durableForecastScope = scope
        } catch {
            // Preserve unreadable and future scope files exactly. Re-adopting the
            // history here would restore evidence deliberately excluded earlier.
            forecastScopeBlocked = true
            forecastScopeError = "Could not load weekly forecast scope: \(error.localizedDescription)"
            persistenceError = forecastScopeError
        }
    }

    private func finishLoadingForecastScope() {
        isLoading = false
        if let scope = durableForecastScope {
            document.projectionIdentity = scope.identity
            document.projectionHistorySince = scope.historySince
            document.projectionIdentityUnavailable = scope.identityUnavailable
            let latest = document.readings.max { $0.timestamp < $1.timestamp }
            forecastScopeNeedsFreshBaseline = scope.recordedThrough == nil
                || scope.readingsHash == nil
                || latest?.timestamp != scope.recordedThrough
                || Self.forecastReadingsHash(document.readings) != scope.readingsHash
        } else if !forecastScopeBlocked,
                  document.projectionIdentity != nil || document.projectionIdentityUnavailable != nil
                    || document.projectionHistorySince != nil {
            // Migrate the inline scope before an older writer can erase it. This
            // does not rewrite the history document merely because it was opened.
            _ = persistForecastScope()
        }
        if pendingHistoryPersistence {
            pendingHistoryPersistence = false
            persist()
        }
        if let forecastScopeError { persistenceError = forecastScopeError }
    }

    private static func forecastReadingsHash(_ readings: [UsageHistoryReading]) -> String? {
        let normalized = readings.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.windowID != $1.windowID { return $0.windowID < $1.windowID }
            if $0.resetsAt != $1.resetsAt { return $0.resetsAt < $1.resetsAt }
            if $0.cycleStartedAt != $1.cycleStartedAt { return $0.cycleStartedAt < $1.cycleStartedAt }
            if $0.durationMinutes != $1.durationMinutes { return $0.durationMinutes < $1.durationMinutes }
            if $0.usedPercent != $1.usedPercent { return $0.usedPercent < $1.usedPercent }
            return !$0.cycleStartKnown && $1.cycleStartKnown
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(normalized)).map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The sidecar is committed before the history document. A failed scope write
    /// must never leave new-account readings behind under the previous scope.
    private func persistForecastScope() -> Bool {
        guard let forecastScopeURL else { return true }
        guard !forecastScopeBlocked else { return false }
        guard document.projectionIdentity != nil || document.projectionIdentityUnavailable != nil
                || document.projectionHistorySince != nil else { return true }
        let latest = document.readings.max { $0.timestamp < $1.timestamp }
        let scope = ForecastScope(identity: document.projectionIdentity,
            historySince: document.projectionHistorySince,
            identityUnavailable: document.projectionIdentityUnavailable ?? (document.projectionIdentity == nil),
            recordedThrough: latest?.timestamp, readingsHash: Self.forecastReadingsHash(document.readings))
        do {
            try FileManager.default.createDirectory(at: forecastScopeURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(scope).write(to: forecastScopeURL, options: .atomic)
            durableForecastScope = scope
            forecastScopeError = nil
            return true
        } catch {
            forecastScopeError = "Could not save weekly forecast scope: \(error.localizedDescription)"
            persistenceError = forecastScopeError
            return false
        }
    }

    private struct CycleKey: Hashable {
        let windowID: String
        let start: Date
    }

    /// Evidence from a v1 daily summary, expressed as absolute interval bounds.
    /// These are deliberately separate from actual timestamped readings: a summary
    /// baseline must never be fabricated as a sample at firstObservedAt.
    private struct LegacyUsageInterval: Codable {
        let windowID: String
        let cycleStartedAt: Date
        let intervalStart: Date
        let intervalEnd: Date
        let firstObservedAt: Date?
        let lastObservedAt: Date
        let startingPercent: Double
        let endingPercent: Double
        let coverage: DailyUsageCoverage
    }

    private static func intervals(from legacy: UsageHistoryAccumulator) -> [LegacyUsageInterval] {
        legacy.legacyDays.compactMap { day in
            guard let start = day.startingPercent, let end = day.endingPercent,
                  start.isFinite, end.isFinite, end >= start,
                  let last = day.lastObservedAt,
                  let zone = TimeZone(identifier: day.timeZoneIdentifier) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day.dayStart) else { return nil }
            return LegacyUsageInterval(windowID: day.windowID, cycleStartedAt: day.effectiveWindowStart,
                intervalStart: day.dayStart, intervalEnd: dayEnd,
                firstObservedAt: day.firstObservedAt, lastObservedAt: last,
                startingPercent: start, endingPercent: end, coverage: day.coverage)
        }
    }

    private static func applying(_ intervals: [LegacyUsageInterval], to window: UsageHistoryWindow,
                                 calendar: Calendar) -> UsageHistoryWindow {
        var days = window.days
        for interval in intervals where interval.windowID == window.windowID
            && interval.cycleStartedAt == window.startsAt {
            // The original daily total is meaningful only when these absolute
            // boundaries match a day in the requested calendar. In another zone,
            // rely on the real samples and their honest uncertainty instead.
            guard calendar.startOfDay(for: interval.intervalStart) == interval.intervalStart,
                  calendar.date(byAdding: .day, value: 1, to: interval.intervalStart) == interval.intervalEnd,
                  let index = days.firstIndex(where: { $0.dayStart == interval.intervalStart }) else { continue }
            var day = days[index]
            if day.coverage == .observed,
               let baseline = day.startingPercent, baseline <= interval.startingPercent,
               let last = day.lastObservedAt, last >= interval.lastObservedAt { continue }
            if let baseline = day.startingPercent, baseline < interval.startingPercent { continue }
            day.startingPercent = interval.startingPercent
            day.firstObservedAt = interval.firstObservedAt
            // Subsequent live readings can extend the original summary's endpoint.
            if (day.lastObservedAt ?? .distantPast) < interval.lastObservedAt {
                day.lastObservedAt = interval.lastObservedAt
                day.endingPercent = interval.endingPercent
            }
            day.coverage = interval.coverage
            days[index] = day
        }
        return UsageHistoryWindow(windowID: window.windowID, resetsAt: window.resetsAt,
            durationMinutes: window.durationMinutes, days: days, startsAt: window.startsAt)
    }

    private static func migrate(_ legacy: UsageHistoryAccumulator, projection: [ProjectionSample]) -> [UsageHistoryReading] {
        let groups = Dictionary(grouping: legacy.legacyDays) {
            CycleKey(windowID: $0.windowID, start: $0.effectiveWindowStart)
        }
        var result: [UsageHistoryReading] = []
        for (key, days) in groups {
            let firstTime = days.compactMap(\.firstObservedAt).min() ?? key.start
            let nextStart = groups.keys.filter { $0.windowID == key.windowID && $0.start > key.start }.map(\.start).min()
            guard let lastDay = days.max(by: { ($0.lastObservedAt ?? .distantPast) < ($1.lastObservedAt ?? .distantPast) }) else { continue }
            let reset = lastDay.windowResetsAt
            let duration = lastDay.windowDurationMinutes
            let known = abs(key.start.timeIntervalSince(reset.addingTimeInterval(-Double(duration) * 60))) < 60
                || days.contains { $0.startingPercent == 0 && $0.coverage == .observed }
            var anchors: [Date: Double] = [:]
            // Ending percentages are actual observations. A summary's starting value
            // is NOT necessarily the value at firstObservedAt, so do not invent it.
            for day in days {
                if let at = day.lastObservedAt, let percent = day.endingPercent { anchors[at] = percent }
                if day.startingPercent == day.endingPercent,
                   let at = day.firstObservedAt, let percent = day.startingPercent { anchors[at] = percent }
                // In v1, an observed baseline across a long midnight gap was only
                // possible when the first reading was unchanged. Recover that real
                // quiet reading; otherwise the retained projection samples can make
                // an originally observed day look estimated after migration.
                if day.coverage == .observed, let first = day.firstObservedAt,
                   let baseline = day.startingPercent,
                   let previous = days.filter({
                       $0.timeZoneIdentifier == day.timeZoneIdentifier && $0.dayStart < day.dayStart
                           && $0.lastObservedAt != nil && $0.lastObservedAt! < first
                   }).max(by: { $0.lastObservedAt! < $1.lastObservedAt! }),
                   previous.endingPercent == baseline,
                   first.timeIntervalSince(previous.lastObservedAt!) > 15 * 60 {
                    anchors[first] = baseline
                }
            }
            for sample in projection + legacy.legacyLatest where sample.windowID == key.windowID {
                guard sample.timestamp >= min(key.start, firstTime),
                      sample.timestamp < (nextStart ?? reset.addingTimeInterval(60)),
                      sample.usedPercent.isFinite, sample.usedPercent >= 0 else { continue }
                // Surviving summaries constrain the imported samples. This avoids
                // moving a reading across a reset just because a schedule drifted.
                let before = anchors.filter { $0.key < sample.timestamp }.max { $0.key < $1.key }?.value
                let after = anchors.filter { $0.key > sample.timestamp }.min { $0.key < $1.key }?.value
                guard sample.usedPercent >= (before ?? 0), sample.usedPercent <= (after ?? .infinity) else { continue }
                if anchors[sample.timestamp] == nil { anchors[sample.timestamp] = sample.usedPercent }
            }
            for (timestamp, percent) in anchors.sorted(by: { $0.key < $1.key }) {
                let reading = UsageHistoryReading(
                    windowID: key.windowID, timestamp: timestamp, usedPercent: percent,
                    resetsAt: reset, durationMinutes: duration, cycleStartedAt: key.start, cycleStartKnown: known
                )
                if isValid(reading) { result.append(reading) }
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }
}

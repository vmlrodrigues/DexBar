import Foundation

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
    }

    private var document = Document()
    private let url: URL?
    private let legacyURL: URL?
    private let calendar: Calendar
    private let retention: TimeInterval
    private var canPersist = true
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
        guard ingest(window: snapshot.weekly, at: snapshot.fetchedAt) else { return }
        trim(relativeTo: snapshot.fetchedAt)
        persist()
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
        guard let url else { return }
        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            // Otherwise clearing followed by a relaunch would re-import the retired file.
            if let legacyURL, manager.fileExists(atPath: legacyURL.path) { try manager.removeItem(at: legacyURL) }
            // Clear automatic migration backups along with the live history.
            let siblings = try manager.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            for file in siblings where file.lastPathComponent.hasPrefix(url.lastPathComponent + ".v1-backup-")
                || file.lastPathComponent.hasPrefix(url.lastPathComponent + ".unreadable-backup-")
                || file.lastPathComponent.hasPrefix(url.lastPathComponent + ".v2-backup-") {
                try manager.removeItem(at: file)
            }
        } catch { persistenceError = "Could not clear usage history: \(error.localizedDescription)" }
    }

    private func ingest(window: UsageWindow, at timestamp: Date) -> Bool {
        guard window.usedPercent.isFinite, window.usedPercent >= 0,
              window.durationMinutes > 0, window.durationMinutes <= 525_600,
              timestamp <= window.resetsAt.addingTimeInterval(60) else { return false }
        let previous = document.readings.last { $0.windowID == window.id }
        // A timestamp is immutable. Duplicate and out-of-order polls cannot change a cycle.
        guard previous == nil || timestamp > previous!.timestamp else { return false }
        let sameCycle = previous.map { Self.isSameCycle(previous: $0, window: window, at: timestamp) } ?? false
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

    private static func isSameCycle(previous: UsageHistoryReading, window: UsageWindow, at timestamp: Date) -> Bool {
        guard previous.durationMinutes == window.durationMinutes,
              window.usedPercent >= previous.usedPercent else { return false }
        if abs(previous.resetsAt.timeIntervalSince(window.resetsAt)) < 60 { return true }
        let reportedStart = window.resetsAt.addingTimeInterval(-Double(window.durationMinutes) * 60)
        if previous.usedPercent > 0,
           reportedStart > previous.timestamp.addingTimeInterval(60),
           reportedStart <= timestamp.addingTimeInterval(60) { return false }
        return timestamp < previous.resetsAt
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
        guard canPersist, let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(document).write(to: url, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = "Could not save usage history: \(error.localizedDescription)" }
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

import Foundation

private enum UsageHistoryConstants {
    static let schemaVersion = 1
    static let resetTolerance: TimeInterval = 60
    static let midnightObservationTolerance: TimeInterval = 15 * 60
    static let defaultRetention: TimeInterval = 13 * 7 * 86_400
}

public enum DailyUsageCoverage: String, Codable, Equatable, Sendable {
    /// The day has a trustworthy baseline, either from the usage-window reset or
    /// from observations close to the local midnight boundary.
    case observed
    /// The baseline crosses midnight through a longer polling gap. The delta is
    /// useful, but its day attribution is approximate.
    case estimated
    /// Observation began after the day had already started, so the delta is only
    /// a lower bound for that day.
    case partial
    /// A multi-day observation gap prevents a responsible daily attribution.
    case unavailable
}

public struct DailyUsageRecord: Codable, Equatable, Identifiable, Sendable {
    public let windowID: String
    public var windowResetsAt: Date
    public var windowDurationMinutes: Int
    public let dayStart: Date
    public let timeZoneIdentifier: String
    public var startingPercent: Double?
    public var endingPercent: Double?
    public var firstObservedAt: Date?
    public var lastObservedAt: Date?
    public var coverage: DailyUsageCoverage
    /// Stable identity for a usage cycle. OpenAI can report a provisional reset
    /// that moves forward on every poll while a freshly-reset window is at 0%.
    /// Older documents omit this field and derive it from the reported window.
    public var windowStartedAt: Date?

    public init(
        windowID: String,
        windowResetsAt: Date,
        windowDurationMinutes: Int,
        dayStart: Date,
        timeZoneIdentifier: String,
        startingPercent: Double?,
        endingPercent: Double?,
        firstObservedAt: Date?,
        lastObservedAt: Date?,
        coverage: DailyUsageCoverage,
        windowStartedAt: Date? = nil
    ) {
        self.windowID = windowID
        self.windowResetsAt = windowResetsAt
        self.windowDurationMinutes = windowDurationMinutes
        self.dayStart = dayStart
        self.timeZoneIdentifier = timeZoneIdentifier
        self.startingPercent = startingPercent
        self.endingPercent = endingPercent
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.coverage = coverage
        self.windowStartedAt = windowStartedAt
    }

    public var effectiveWindowStart: Date {
        windowStartedAt ?? windowResetsAt.addingTimeInterval(
            -TimeInterval(windowDurationMinutes * 60)
        )
    }

    public var id: String {
        "\(windowID)|\(Int(effectiveWindowStart.timeIntervalSince1970.rounded()))"
            + "|\(Int(dayStart.timeIntervalSince1970.rounded()))|\(timeZoneIdentifier)"
    }

    public var usedPercent: Double? {
        guard let startingPercent, let endingPercent else { return nil }
        return max(0, endingPercent - startingPercent)
    }
}

public struct UsageHistoryWindow: Equatable, Identifiable, Sendable {
    public let windowID: String
    public let resetsAt: Date
    public let durationMinutes: Int
    public let days: [DailyUsageRecord]
    public let startsAt: Date

    public init(
        windowID: String,
        resetsAt: Date,
        durationMinutes: Int,
        days: [DailyUsageRecord],
        startsAt: Date? = nil
    ) {
        self.windowID = windowID
        self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
        self.days = days
        self.startsAt = startsAt ?? resetsAt.addingTimeInterval(-TimeInterval(durationMinutes * 60))
    }

    public var id: String {
        "\(windowID)|\(Int(startsAt.timeIntervalSince1970.rounded()))"
    }

    public var lastObservedDay: DailyUsageRecord? {
        days.filter { $0.lastObservedAt != nil }.max {
            $0.lastObservedAt! < $1.lastObservedAt!
        }
    }

    /// Each recorded time zone is a separate calendar view of the same allowance.
    /// Never reinterpret a stored day's total against another zone's midnight.
    public func historyTimeZones(including current: TimeZone? = nil) -> [TimeZone] {
        var identifiers = Set(days.map(\.timeZoneIdentifier))
        if let current { identifiers.insert(current.identifier) }
        return identifiers.sorted().compactMap(TimeZone.init(identifier:))
    }

    public func lastObservedDay(in timeZone: TimeZone) -> DailyUsageRecord? {
        days.filter { $0.timeZoneIdentifier == timeZone.identifier && $0.lastObservedAt != nil }
            .max { $0.lastObservedAt! < $1.lastObservedAt! }
    }

    public func completedDescription(resetEarly: Bool) -> String {
        let label = resetEarly ? "Week reset early" : "Week ended"
        guard let percent = lastObservedDay?.endingPercent else {
            return "\(label) · total unavailable"
        }
        return "\(label) · last seen \(Int(percent.rounded()))%"
    }

    /// All calendar days, including an extended provisional zero-usage cycle.
    /// The view pages this range instead of silently dropping later days.
    public func calendarDays(endingAt end: Date, calendar: Calendar) -> [Date] {
        let lastDay = calendar.startOfDay(for: max(startsAt, end.addingTimeInterval(-0.001)))
        var day = calendar.startOfDay(for: startsAt)
        var result: [Date] = []
        while day <= lastDay {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return result
    }

    /// Start with the most recent eight dates, including the current day and
    /// remaining week for a sliding zero window. Earlier pages remain reachable.
    public func calendarDayPage(endingAt end: Date, calendar: Calendar, offsetFromEnd: Int = 0) -> [Date] {
        let days = calendarDays(endingAt: end, calendar: calendar)
        let start = max(0, days.count - 8 - max(0, offsetFromEnd))
        return Array(days[start..<min(days.count, start + 8)])
    }

    public func record(on day: Date, timeZone: TimeZone) -> DailyUsageRecord? {
        days.filter { $0.dayStart == day && $0.timeZoneIdentifier == timeZone.identifier }
            .max { ($0.lastObservedAt ?? .distantPast) < ($1.lastObservedAt ?? .distantPast) }
    }
}

@MainActor
public final class UsageHistoryStore {
    private struct Observation: Codable, Equatable {
        let windowID: String
        let timestamp: Date
        let usedPercent: Double
        let resetsAt: Date
        let durationMinutes: Int
        let timeZoneIdentifier: String
        let cycleStartedAt: Date?

        var effectiveCycleStart: Date {
            cycleStartedAt ?? resetsAt.addingTimeInterval(-TimeInterval(durationMinutes * 60))
        }
    }

    private struct Document: Codable, Equatable {
        var schemaVersion: Int
        var days: [DailyUsageRecord]
        var latestObservations: [Observation]

        static let empty = Document(
            schemaVersion: UsageHistoryConstants.schemaVersion,
            days: [],
            latestObservations: []
        )
    }

    private var document: Document
    private let url: URL?
    private let calendar: Calendar
    private let retention: TimeInterval

    public convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DexBar", isDirectory: true)
        self.init(url: directory.appendingPathComponent("usage-history.json"))
    }

    public init(
        url: URL,
        calendar: Calendar = .autoupdatingCurrent,
        retention: TimeInterval = 13 * 7 * 86_400
    ) {
        self.url = url
        self.calendar = calendar
        self.retention = retention
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Document.self, from: data),
           decoded.schemaVersion == UsageHistoryConstants.schemaVersion {
            document = decoded
            let original = document
            repairSlidingZeroCycles()
            if document != original {
                persist()
            }
        } else {
            document = .empty
        }
    }

    private init(calendar: Calendar) {
        url = nil
        self.calendar = calendar
        retention = UsageHistoryConstants.defaultRetention
        document = .empty
    }

    public static func inMemory(calendar: Calendar = .autoupdatingCurrent) -> UsageHistoryStore {
        UsageHistoryStore(calendar: calendar)
    }

    public func record(_ snapshot: UsageSnapshot) {
        let shouldPersist = requiresPersistence(
            windowID: snapshot.weekly.id,
            usedPercent: snapshot.weekly.usedPercent,
            resetsAt: snapshot.weekly.resetsAt,
            durationMinutes: snapshot.weekly.durationMinutes,
            timestamp: snapshot.fetchedAt
        )
        ingest(
            windowID: snapshot.weekly.id,
            usedPercent: snapshot.weekly.usedPercent,
            resetsAt: snapshot.weekly.resetsAt,
            durationMinutes: snapshot.weekly.durationMinutes,
            timestamp: snapshot.fetchedAt
        )
        guard shouldPersist else { return }
        trim(relativeTo: snapshot.fetchedAt)
        persist()
    }

    /// Seeds a newly-created history document from the short projection history
    /// already present on an upgraded installation. Existing daily history always
    /// wins, so this is safe to call on every launch.
    public func backfill(samples: [ProjectionSample], for window: UsageWindow) {
        guard !document.days.contains(where: { $0.windowID == window.id }) else { return }
        for sample in samples
            .filter({ $0.windowID == window.id })
            .sorted(by: { $0.timestamp < $1.timestamp }) {
            ingest(
                windowID: sample.windowID,
                usedPercent: sample.usedPercent,
                resetsAt: sample.resetsAt,
                durationMinutes: window.durationMinutes,
                timestamp: sample.timestamp
            )
        }
        guard !samples.isEmpty else { return }
        trim(relativeTo: samples.map(\.timestamp).max() ?? Date())
        persist()
    }

    public func windows(for windowID: String) -> [UsageHistoryWindow] {
        let grouped = Dictionary(grouping: document.days.filter { $0.windowID == windowID }) {
            Int($0.effectiveWindowStart.timeIntervalSince1970.rounded())
        }
        return grouped.values.compactMap { records in
            guard let first = records.first else { return nil }
            return UsageHistoryWindow(
                windowID: first.windowID,
                resetsAt: first.windowResetsAt,
                durationMinutes: first.windowDurationMinutes,
                days: records.sorted { $0.dayStart < $1.dayStart },
                startsAt: first.effectiveWindowStart
            )
        }
        .sorted { $0.startsAt > $1.startsAt }
    }

    public func clear() {
        document = .empty
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func requiresPersistence(
        windowID: String,
        usedPercent: Double,
        resetsAt: Date,
        durationMinutes: Int,
        timestamp: Date
    ) -> Bool {
        guard let previous = document.latestObservations.first(where: { $0.windowID == windowID }) else {
            return true
        }
        return abs(previous.resetsAt.timeIntervalSince(resetsAt)) >= UsageHistoryConstants.resetTolerance
            || previous.durationMinutes != durationMinutes
            || previous.usedPercent != usedPercent
            || previous.timeZoneIdentifier != calendar.timeZone.identifier
            || !calendar.isDate(previous.timestamp, inSameDayAs: timestamp)
    }

    private func ingest(
        windowID: String,
        usedPercent: Double,
        resetsAt: Date,
        durationMinutes: Int,
        timestamp: Date
    ) {
        guard usedPercent.isFinite, durationMinutes > 0 else { return }
        guard timestamp <= resetsAt.addingTimeInterval(UsageHistoryConstants.resetTolerance) else { return }

        let percent = max(0, usedPercent)
        let timeZoneIdentifier = calendar.timeZone.identifier
        let previousIndex = document.latestObservations.firstIndex { $0.windowID == windowID }
        let previous = previousIndex.map { document.latestObservations[$0] }
        guard previous == nil || timestamp >= previous!.timestamp else { return }

        let sameWindow = previous.map {
            isSameCycle(
                previous: $0,
                usedPercent: percent,
                resetsAt: resetsAt,
                durationMinutes: durationMinutes,
                timestamp: timestamp
            )
        } ?? false
        let cycleStart = sameWindow
            ? (date: previous!.effectiveCycleStart, known: true)
            : detectedCycleStart(
                resetsAt: resetsAt,
                durationMinutes: durationMinutes,
                timestamp: timestamp,
                previous: previous
            )
        let observation = Observation(
            windowID: windowID,
            timestamp: timestamp,
            usedPercent: percent,
            resetsAt: resetsAt,
            durationMinutes: durationMinutes,
            timeZoneIdentifier: timeZoneIdentifier,
            cycleStartedAt: cycleStart.date
        )

        if let previous, sameWindow {
            updateCycleMetadata(for: observation)
            advance(from: previous, to: observation)
        } else {
            // When a reset boundary is inferred from the first new reading,
            // only a same-day preceding reading proves the reset happened today.
            let resetKnownToday = calendar.isDate(cycleStart.date, inSameDayAs: timestamp)
                && (cycleStart.known || previous.map {
                    calendar.isDate($0.timestamp, inSameDayAs: timestamp)
                } == true)
            startCycle(with: observation, resetKnownToday: resetKnownToday)
        }

        if let previousIndex {
            document.latestObservations[previousIndex] = observation
        } else {
            document.latestObservations.append(observation)
        }
    }

    private func startCycle(with observation: Observation, resetKnownToday: Bool) {
        let dayStart = calendar.startOfDay(for: observation.timestamp)
        let startPercent = resetKnownToday ? 0 : observation.usedPercent
        let coverage: DailyUsageCoverage = resetKnownToday ? .observed : .partial
        upsert(DailyUsageRecord(
            windowID: observation.windowID,
            windowResetsAt: observation.resetsAt,
            windowDurationMinutes: observation.durationMinutes,
            dayStart: dayStart,
            timeZoneIdentifier: observation.timeZoneIdentifier,
            startingPercent: startPercent,
            endingPercent: observation.usedPercent,
            firstObservedAt: observation.timestamp,
            lastObservedAt: observation.timestamp,
            coverage: coverage,
            windowStartedAt: observation.effectiveCycleStart
        ))
    }

    private func advance(from previous: Observation, to current: Observation) {
        let currentDay = calendar.startOfDay(for: current.timestamp)
        let previousDay = calendar.startOfDay(for: previous.timestamp)

        guard previous.timeZoneIdentifier == current.timeZoneIdentifier else {
            upsert(partialRecord(for: current, dayStart: currentDay))
            return
        }

        if current.usedPercent < previous.usedPercent {
            upsert(partialRecord(for: current, dayStart: currentDay))
            return
        }

        if previousDay == currentDay {
            if let index = recordIndex(
                windowID: current.windowID,
                cycleStartedAt: current.effectiveCycleStart,
                dayStart: currentDay,
                timeZoneIdentifier: current.timeZoneIdentifier
            ) {
                document.days[index].endingPercent = current.usedPercent
                document.days[index].lastObservedAt = current.timestamp
            } else {
                upsert(DailyUsageRecord(
                    windowID: current.windowID,
                    windowResetsAt: current.resetsAt,
                    windowDurationMinutes: current.durationMinutes,
                    dayStart: currentDay,
                    timeZoneIdentifier: current.timeZoneIdentifier,
                    startingPercent: previous.usedPercent,
                    endingPercent: current.usedPercent,
                    firstObservedAt: previous.timestamp,
                    lastObservedAt: current.timestamp,
                    coverage: .partial,
                    windowStartedAt: current.effectiveCycleStart
                ))
            }
            return
        }

        let crossedDays = dayStarts(after: previousDay, through: currentDay)
        let delta = current.usedPercent - previous.usedPercent
        if crossedDays.count == 1 {
            let gap = current.timestamp.timeIntervalSince(previous.timestamp)
            let coverage: DailyUsageCoverage = delta > 0
                && gap > UsageHistoryConstants.midnightObservationTolerance ? .estimated : .observed
            upsert(DailyUsageRecord(
                windowID: current.windowID,
                windowResetsAt: current.resetsAt,
                windowDurationMinutes: current.durationMinutes,
                dayStart: currentDay,
                timeZoneIdentifier: current.timeZoneIdentifier,
                startingPercent: previous.usedPercent,
                endingPercent: current.usedPercent,
                firstObservedAt: current.timestamp,
                lastObservedAt: current.timestamp,
                coverage: coverage,
                windowStartedAt: current.effectiveCycleStart
            ))
            return
        }

        for dayStart in crossedDays {
            if delta == 0 {
                upsert(DailyUsageRecord(
                    windowID: current.windowID,
                    windowResetsAt: current.resetsAt,
                    windowDurationMinutes: current.durationMinutes,
                    dayStart: dayStart,
                    timeZoneIdentifier: current.timeZoneIdentifier,
                    startingPercent: current.usedPercent,
                    endingPercent: current.usedPercent,
                    firstObservedAt: dayStart == currentDay ? current.timestamp : nil,
                    lastObservedAt: dayStart == currentDay ? current.timestamp : nil,
                    coverage: .observed,
                    windowStartedAt: current.effectiveCycleStart
                ))
            } else {
                upsert(DailyUsageRecord(
                    windowID: current.windowID,
                    windowResetsAt: current.resetsAt,
                    windowDurationMinutes: current.durationMinutes,
                    dayStart: dayStart,
                    timeZoneIdentifier: current.timeZoneIdentifier,
                    startingPercent: nil,
                    endingPercent: dayStart == currentDay ? current.usedPercent : nil,
                    firstObservedAt: dayStart == currentDay ? current.timestamp : nil,
                    lastObservedAt: dayStart == currentDay ? current.timestamp : nil,
                    coverage: .unavailable,
                    windowStartedAt: current.effectiveCycleStart
                ))
            }
        }
    }

    private func partialRecord(for observation: Observation, dayStart: Date) -> DailyUsageRecord {
        DailyUsageRecord(
            windowID: observation.windowID,
            windowResetsAt: observation.resetsAt,
            windowDurationMinutes: observation.durationMinutes,
            dayStart: dayStart,
            timeZoneIdentifier: observation.timeZoneIdentifier,
            startingPercent: observation.usedPercent,
            endingPercent: observation.usedPercent,
            firstObservedAt: observation.timestamp,
            lastObservedAt: observation.timestamp,
            coverage: .partial,
            windowStartedAt: observation.effectiveCycleStart
        )
    }

    private func dayStarts(after start: Date, through end: Date) -> [Date] {
        var result: [Date] = []
        var cursor = start
        while let next = calendar.date(byAdding: .day, value: 1, to: cursor), next <= end {
            result.append(next)
            cursor = next
        }
        return result
    }

    private func upsert(_ record: DailyUsageRecord) {
        if let index = recordIndex(
            windowID: record.windowID,
            cycleStartedAt: record.effectiveWindowStart,
            dayStart: record.dayStart,
            timeZoneIdentifier: record.timeZoneIdentifier
        ) {
            let existing = document.days[index]
            var merged = record
            if existing.coverage != .unavailable, record.coverage == .unavailable {
                merged = existing
            } else if existing.coverage == .partial, record.coverage == .partial {
                merged.startingPercent = existing.startingPercent
                merged.firstObservedAt = existing.firstObservedAt
            } else {
                if let existingFirst = existing.firstObservedAt,
                   record.firstObservedAt == nil || existingFirst < record.firstObservedAt! {
                    merged.startingPercent = existing.startingPercent
                    merged.firstObservedAt = existingFirst
                }
                if let existingLast = existing.lastObservedAt,
                   record.lastObservedAt == nil || existingLast > record.lastObservedAt! {
                    merged.endingPercent = existing.endingPercent
                    merged.lastObservedAt = existingLast
                }
            }
            document.days[index] = merged
        } else {
            document.days.append(record)
        }
    }

    private func recordIndex(
        windowID: String,
        cycleStartedAt: Date,
        dayStart: Date,
        timeZoneIdentifier: String
    ) -> Int? {
        document.days.firstIndex {
            $0.windowID == windowID
                && abs($0.effectiveWindowStart.timeIntervalSince(cycleStartedAt))
                    < UsageHistoryConstants.resetTolerance
                && $0.dayStart == dayStart
                && $0.timeZoneIdentifier == timeZoneIdentifier
        }
    }

    private func trim(relativeTo now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        document.days.removeAll { $0.dayStart < cutoff }
    }

    private func isSameCycle(
        previous: Observation,
        usedPercent: Double,
        resetsAt: Date,
        durationMinutes: Int,
        timestamp: Date
    ) -> Bool {
        guard previous.durationMinutes == durationMinutes,
              usedPercent >= previous.usedPercent else {
            return false
        }
        if abs(previous.resetsAt.timeIntervalSince(resetsAt)) < UsageHistoryConstants.resetTolerance {
            return true
        }
        let reportedStart = resetsAt.addingTimeInterval(-TimeInterval(durationMinutes * 60))
        // Usage may have overtaken our last reading after a reset while this Mac
        // was offline. A new start after a positive observation separates those
        // allowances even without a visible percentage drop. Keep the tolerance
        // for timestamp jitter, and leave sliding zero windows in one cycle.
        if previous.usedPercent > 0,
           reportedStart > previous.timestamp.addingTimeInterval(UsageHistoryConstants.resetTolerance),
           reportedStart <= timestamp.addingTimeInterval(UsageHistoryConstants.resetTolerance) {
            return false
        }
        return timestamp < previous.resetsAt
    }

    private func detectedCycleStart(
        resetsAt: Date,
        durationMinutes: Int,
        timestamp: Date,
        previous: Observation?
    ) -> (date: Date, known: Bool) {
        let reportedStart = resetsAt.addingTimeInterval(-TimeInterval(durationMinutes * 60))
        // A reported boundary after our preceding reading remains useful even
        // when this Mac was asleep for days before discovering the new cycle.
        if reportedStart <= timestamp.addingTimeInterval(UsageHistoryConstants.resetTolerance),
           previous == nil || reportedStart > previous!.timestamp {
            return (reportedStart, true)
        }
        // A drop with an unchanged/old reset schedule only tells us that the
        // replacement exists by this poll. It does not establish its start day.
        return (timestamp, false)
    }

    private func updateCycleMetadata(for observation: Observation) {
        for index in document.days.indices where
            document.days[index].windowID == observation.windowID
                && abs(document.days[index].effectiveWindowStart.timeIntervalSince(
                    observation.effectiveCycleStart
                )) < UsageHistoryConstants.resetTolerance {
            document.days[index].windowStartedAt = observation.effectiveCycleStart
            document.days[index].windowResetsAt = observation.resetsAt
            document.days[index].windowDurationMinutes = observation.durationMinutes
        }
    }

    /// Repairs documents written before cycles had a stable start identity. A run
    /// of zero-only windows whose next observation arrives before the prior reset
    /// is the provisional-reset bug: it is one cycle, not many weekly windows.
    private func repairSlidingZeroCycles() {
        guard document.days.contains(where: { $0.windowStartedAt == nil }) else { return }
        let groupedByWindow = Dictionary(grouping: document.days, by: \.windowID)
        var rewritten: [DailyUsageRecord] = []
        var preserved: [DailyUsageRecord] = []
        var cycleMap: [String: (start: Date, reset: Date)] = [:]

        for (_, records) in groupedByWindow {
            let cycleGroups = Dictionary(grouping: records) {
                Int($0.effectiveWindowStart.timeIntervalSince1970.rounded())
            }.values.sorted {
                groupFirstObserved($0) < groupFirstObserved($1)
            }
            var chains: [[[DailyUsageRecord]]] = []
            for group in cycleGroups {
                if let lastChain = chains.last,
                   let previous = lastChain.last,
                   isLegacyZeroOnly(previous), isLegacyZeroOnly(group),
                   Set((previous + group).map(\.windowDurationMinutes)).count == 1,
                   groupReset(group) >= groupReset(previous),
                   groupFirstObserved(group) < groupReset(previous) {
                    chains[chains.count - 1].append(group)
                } else {
                    chains.append([group])
                }
            }

            for chain in chains {
                guard let firstGroup = chain.first, let lastGroup = chain.last,
                      let firstRecord = firstGroup.first else { continue }
                // Stable cycle identities are authoritative, including in a
                // document that also contains older records awaiting migration.
                if chain.joined().contains(where: { $0.windowStartedAt != nil }) {
                    preserved.append(contentsOf: chain.joined())
                    continue
                }
                let canonicalStart = firstRecord.effectiveWindowStart
                let latestReset = groupReset(lastGroup)
                for group in chain {
                    for var record in group {
                        cycleMap[cycleKey(record.windowID, record.effectiveWindowStart)] = (
                            canonicalStart,
                            latestReset
                        )
                        record.windowStartedAt = canonicalStart
                        record.windowResetsAt = latestReset
                        rewritten.append(record)
                    }
                }
            }
        }

        document.days = []
        for record in rewritten.sorted(by: { ($0.firstObservedAt ?? $0.dayStart) < ($1.firstObservedAt ?? $1.dayStart) }) {
            upsert(record)
        }
        document.days.append(contentsOf: preserved)
        document.latestObservations = document.latestObservations.map { observation in
            guard observation.cycleStartedAt == nil else { return observation }
            let mapping = cycleMap[cycleKey(observation.windowID, observation.effectiveCycleStart)]
            return Observation(
                windowID: observation.windowID,
                timestamp: observation.timestamp,
                usedPercent: observation.usedPercent,
                resetsAt: mapping?.reset ?? observation.resetsAt,
                durationMinutes: observation.durationMinutes,
                timeZoneIdentifier: observation.timeZoneIdentifier,
                cycleStartedAt: mapping?.start ?? observation.effectiveCycleStart
            )
        }
    }

    private func groupFirstObserved(_ records: [DailyUsageRecord]) -> Date {
        records.compactMap(\.firstObservedAt).min() ?? records.map(\.dayStart).min() ?? .distantPast
    }

    private func groupReset(_ records: [DailyUsageRecord]) -> Date {
        records.map(\.windowResetsAt).max() ?? .distantPast
    }

    private func isLegacyZeroOnly(_ records: [DailyUsageRecord]) -> Bool {
        !records.isEmpty && records.allSatisfy {
            $0.windowStartedAt == nil && $0.startingPercent == 0 && $0.endingPercent == 0
        }
    }

    private func cycleKey(_ windowID: String, _ startedAt: Date) -> String {
        "\(windowID)|\(Int(startedAt.timeIntervalSince1970.rounded()))"
    }

    private func persist() {
        guard let url, let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

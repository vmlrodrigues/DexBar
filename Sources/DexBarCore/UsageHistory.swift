import Foundation

private enum UsageHistoryConstants {
    static let schemaVersion = 1
    static let resetTolerance: TimeInterval = 60
    static let midnightObservationTolerance: TimeInterval = 15 * 60
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

    /// Zones present in this derived view (or in a legacy summary during migration).
    /// Recalculate from readings to present another zone; never relabel a daily total.
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

/// Pure local-calendar aggregation, also used to decode and repair v1 summaries.
/// Its daily records are never written by the v2 store.
final class UsageHistoryAccumulator {
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

    private var document: Document = .empty
    private let calendar: Calendar

    init(calendar: Calendar) { self.calendar = calendar }

    init(legacyData: Data) throws {
        calendar = Calendar(identifier: .gregorian)
        document = try JSONDecoder().decode(Document.self, from: legacyData)
        guard document.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
        repairSlidingZeroCycles()
    }

    var legacyDays: [DailyUsageRecord] { document.days }

    var legacyLatest: [ProjectionSample] {
        document.latestObservations.map {
            ProjectionSample(windowID: $0.windowID, timestamp: $0.timestamp,
                             usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
        }
    }

    func append(_ reading: UsageHistoryReading) {
        let previous = document.latestObservations.first { $0.windowID == reading.windowID }
        let observation = Observation(
            windowID: reading.windowID, timestamp: reading.timestamp,
            usedPercent: reading.usedPercent, resetsAt: reading.resetsAt,
            durationMinutes: reading.durationMinutes, timeZoneIdentifier: calendar.timeZone.identifier,
            cycleStartedAt: reading.cycleStartedAt
        )
        if let previous, previous.effectiveCycleStart == reading.cycleStartedAt {
            updateCycleMetadata(for: observation)
            advance(from: previous, to: observation)
        } else {
            // An unchanged reset schedule gives a time interval, not an exact
            // reset instant. If both ends fall on this local day, its entire new
            // allowance consumption still belongs to the day.
            let resetKnownToday = calendar.isDate(reading.cycleStartedAt, inSameDayAs: reading.timestamp)
                && (reading.cycleStartKnown || previous.map {
                    calendar.isDate($0.timestamp, inSameDayAs: reading.timestamp)
                } == true)
            startCycle(with: observation, resetKnownToday: resetKnownToday)
        }
        document.latestObservations.removeAll { $0.windowID == reading.windowID }
        document.latestObservations.append(observation)
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

}

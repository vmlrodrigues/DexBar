import Foundation

public struct Projection: Equatable, Sendable {
    public enum Outlook: Equatable, Sendable { case onTrack, mayRunOut, likelyToRunOut }

    public let projectedPercent: Int
    public let pointsPerDay: Double
    public let longTermPointsPerDay: Double
    public let recentPointsPerDay: Double?
    public let lowerProjectedPercent: Int
    public let upperProjectedPercent: Int
    public let daysRemaining: Double
    public let outlook: Outlook
    public let limitReachedAt: Date?
    public let isPreliminary: Bool
    public let historicalPointsPerDay: Double?

    public init(
        projectedPercent: Int,
        pointsPerDay: Double,
        longTermPointsPerDay: Double? = nil,
        recentPointsPerDay: Double? = nil,
        lowerProjectedPercent: Int? = nil,
        upperProjectedPercent: Int? = nil,
        daysRemaining: Double,
        outlook: Outlook,
        limitReachedAt: Date?,
        isPreliminary: Bool = false,
        historicalPointsPerDay: Double? = nil
    ) {
        self.projectedPercent = projectedPercent
        self.pointsPerDay = pointsPerDay
        self.longTermPointsPerDay = longTermPointsPerDay ?? pointsPerDay
        self.recentPointsPerDay = recentPointsPerDay
        self.lowerProjectedPercent = lowerProjectedPercent ?? projectedPercent
        self.upperProjectedPercent = upperProjectedPercent ?? projectedPercent
        self.daysRemaining = daysRemaining
        self.outlook = outlook
        self.limitReachedAt = limitReachedAt
        self.isPreliminary = isPreliminary
        self.historicalPointsPerDay = historicalPointsPerDay
    }
}

public enum ProjectionKind: Equatable, Sendable {
    case short
    case weekly
}

public struct ProjectionSample: Codable, Equatable, Sendable {
    public let windowID: String
    public let timestamp: Date
    public let usedPercent: Double
    public let resetsAt: Date

    public init(
        windowID: String,
        timestamp: Date,
        usedPercent: Double,
        resetsAt: Date
    ) {
        self.windowID = windowID
        self.timestamp = timestamp
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// Cycle membership comes from the UTC history store, shared with daily history.
/// These are derived samples only; the recorded reset dates remain untouched.
struct WeeklyProjectionCycle {
    let startsAt: Date
    let startKnown: Bool
    let durationMinutes: Int
    let samples: [ProjectionSample]
}

public enum ProjectionCalculator {
    private static let resetTolerance: TimeInterval = 60
    private static let recentMinimumElapsed: TimeInterval = 6 * 3_600
    private static let recentMaximumElapsed: TimeInterval = 24 * 3_600
    private static let recentMinimumMovement = 3.0
    private static let recentHalfLife: TimeInterval = 12 * 3_600

    public static func calculate(
        window: UsageWindow,
        samples: [ProjectionSample],
        now: Date,
        kind: ProjectionKind = .weekly,
        minimumElapsed: TimeInterval? = nil
    ) -> Projection? {
        let matching = samples
            .filter {
                $0.windowID == window.id
                    && $0.timestamp <= now
                    && abs($0.resetsAt.timeIntervalSince(window.resetsAt)) < Self.resetTolerance
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard var baseline = matching.first else { return nil }
        for index in 1..<matching.count where matching[index].usedPercent < matching[index - 1].usedPercent - 2 {
            baseline = matching[index]
        }

        let elapsed = now.timeIntervalSince(baseline.timestamp)
        // A weekly estimate needs a full day. One hour is the equivalent share of
        // a five-hour window and matches ClawBar's backtested session estimator.
        let requiredHistory = minimumElapsed ?? (kind == .weekly ? 86_400 : 3_600)
        guard elapsed >= requiredHistory, elapsed > 0 else { return nil }
        let consumed = window.usedPercent - baseline.usedPercent
        guard consumed > 0 else { return nil }

        let longTermPointsPerDay = consumed / elapsed * 86_400
        let recentEstimate = kind == .weekly
            ? recentEstimate(for: window, samples: matching, baseline: baseline, now: now)
            : nil
        let recentPointsPerDay = recentEstimate?.rate

        let pointsPerDay: Double
        if let recentEstimate {
            pointsPerDay = recentEstimate.rate * recentEstimate.weight
                + longTermPointsPerDay * (1 - recentEstimate.weight)
        } else {
            pointsPerDay = longTermPointsPerDay
        }

        return makeProjection(window: window, now: now, kind: kind,
                              pointsPerDay: pointsPerDay, longTermPointsPerDay: longTermPointsPerDay,
                              recentPointsPerDay: recentPointsPerDay, elapsed: elapsed)
    }

    /// A new allowance borrows a measured pace, never an old cumulative percentage.
    /// Its own observations replace that prior continuously over the first day.
    static func weekly(window: UsageWindow, cycles: [WeeklyProjectionCycle], now: Date,
                       allowHistorical: Bool) -> Projection? {
        guard window.isWeekly, window.resetsAt > now,
              let current = cycles.last, let first = current.samples.first,
              let last = current.samples.last, last.timestamp == now,
              last.usedPercent == window.usedPercent,
              abs(last.resetsAt.timeIntervalSince(window.resetsAt)) < resetTolerance else { return nil }
        let elapsed = now.timeIntervalSince(first.timestamp)
        guard elapsed >= 0 else { return nil }

        // Normalize only a derived copy after the shared store has resolved identity.
        // Provisional zero-usage reset movement cannot throw away the actual baseline.
        func normalized(_ cycle: WeeklyProjectionCycle, reset: Date) -> [ProjectionSample] {
            cycle.samples.map {
                ProjectionSample(windowID: window.id, timestamp: $0.timestamp,
                                 usedPercent: $0.usedPercent, resetsAt: reset)
            }
        }
        let currentSamples = normalized(current, reset: window.resetsAt)
        let measured = calculate(window: window, samples: currentSamples, now: now,
                                 minimumElapsed: 0)
        if elapsed >= 86_400 {
            // A full quiet day is evidence of zero pace, rather than another blank
            // forecast. Small percentage corrections must not create negative spend.
            return measured ?? makeProjection(window: window, now: now, kind: .weekly,
                pointsPerDay: 0, longTermPointsPerDay: 0, recentPointsPerDay: nil, elapsed: elapsed)
        }
        guard allowHistorical else { return nil }

        // At least a day of actual observations is required in the previous
        // allowance, including a measured quiet day. An inferred cycle start
        // cannot mature evidence or justify skipping a recent pause.
        for previous in cycles.dropLast().reversed() where previous.durationMinutes == window.durationMinutes {
            guard let oldFirst = previous.samples.first, let oldLast = previous.samples.last,
                  oldLast.timestamp < first.timestamp else { continue }
            let span = oldLast.timestamp.timeIntervalSince(oldFirst.timestamp)
            guard span >= 86_400 else { continue }
            let oldWindow = UsageWindow(id: window.id, bucketID: window.bucketID,
                bucketName: window.bucketName, usedPercent: oldLast.usedPercent,
                durationMinutes: previous.durationMinutes, resetsAt: oldLast.resetsAt)
            guard let prior = calculate(window: oldWindow,
                samples: normalized(previous, reset: oldLast.resetsAt), now: oldLast.timestamp)
                ?? makeProjection(window: oldWindow, now: oldLast.timestamp, kind: .weekly,
                    pointsPerDay: 0, longTermPointsPerDay: 0, recentPointsPerDay: nil, elapsed: span) else { continue }

            // A deferred start after a closely observed natural expiry is a known
            // pause. Do not invent zero usage in an unobserved tail or a long gap.
            let tail = oldLast.resetsAt.timeIntervalSince(oldLast.timestamp)
            let gap = current.startsAt.timeIntervalSince(oldLast.resetsAt)
            let idle = current.startKnown && tail >= 0 && tail <= 3_600 && gap >= 0 && gap <= 86_400
                ? gap : 0
            let scale = span / (span + idle)
            let historical = prior.pointsPerDay * scale
            let historicalLong = prior.longTermPointsPerDay * scale
            let currentWeight = elapsed / 86_400
            let weight = 1 - currentWeight
            let measuredLong = measured?.longTermPointsPerDay ?? 0
            let measuredRate = measured?.pointsPerDay ?? 0
            let measuredRecent = measured?.recentPointsPerDay
            let oldLow = min(prior.longTermPointsPerDay, prior.recentPointsPerDay ?? prior.longTermPointsPerDay) * scale
            let oldHigh = max(prior.longTermPointsPerDay, prior.recentPointsPerDay ?? prior.longTermPointsPerDay) * scale
            let newLow = min(measuredLong, measuredRecent ?? measuredLong)
            let newHigh = max(measuredLong, measuredRecent ?? measuredLong)
            // Each rounded delta can be off by one percentage point. Propagate
            // those rate errors independently; averaging the observation spans
            // would hide a young current rate behind an older, longer baseline.
            let historicalRateError = weight * 86_400 / (span + idle)
            let currentRateError = elapsed > 0 ? currentWeight * 86_400 / elapsed : 0
            return makeProjection(window: window, now: now, kind: .weekly,
                pointsPerDay: historical * weight + measuredRate * currentWeight,
                longTermPointsPerDay: historicalLong * weight + measuredLong * currentWeight,
                recentPointsPerDay: measuredRecent,
                elapsed: elapsed,
                lowerRate: oldLow * weight + newLow * currentWeight,
                upperRate: oldHigh * weight + newHigh * currentWeight,
                measurementRateError: historicalRateError + currentRateError,
                isPreliminary: true, historicalPointsPerDay: historical)
        }
        return nil
    }

    private static func makeProjection(
        window: UsageWindow, now: Date, kind: ProjectionKind,
        pointsPerDay: Double, longTermPointsPerDay: Double, recentPointsPerDay: Double?, elapsed: TimeInterval,
        lowerRate: Double? = nil, upperRate: Double? = nil,
        measurementRateError: Double? = nil,
        isPreliminary: Bool = false, historicalPointsPerDay: Double? = nil
    ) -> Projection? {
        guard pointsPerDay.isFinite, pointsPerDay >= 0, window.usedPercent.isFinite else { return nil }
        let daysRemaining = max(0, window.resetsAt.timeIntervalSince(now)) / 86_400
        let rawProjection = window.usedPercent + pointsPerDay * daysRemaining
        let longTermProjection = window.usedPercent + longTermPointsPerDay * daysRemaining
        let recentProjection = recentPointsPerDay.map { window.usedPercent + $0 * daysRemaining }
        // The service currently reports whole percentage points. Preserve a conservative
        // evidence band even when only the long-term pace is available, so a rounded 99%
        // estimate is never presented as confidently below the limit.
        let rateMargin = measurementRateError.map { daysRemaining * $0 }
            ?? (daysRemaining / max(elapsed / 86_400, 1.0 / 24.0))
        let measurementMargin = max(2.0, 0.5 + rateMargin)
        let lowerProjection = max(
            window.usedPercent,
            (lowerRate.map { window.usedPercent + $0 * daysRemaining }
                ?? min(longTermProjection, recentProjection ?? longTermProjection)) - measurementMargin
        )
        let upperProjection = (upperRate.map { window.usedPercent + $0 * daysRemaining }
            ?? max(longTermProjection, recentProjection ?? longTermProjection))
            + measurementMargin
        let lowerProjectedPercent = Int(floor(lowerProjection))
        let upperProjectedPercent = max(lowerProjectedPercent, Int(ceil(upperProjection)))

        let outlook: Projection.Outlook
        if upperProjectedPercent < 100 { outlook = .onTrack }
        else if lowerProjectedPercent >= 100 { outlook = .likelyToRunOut }
        else { outlook = .mayRunOut }

        let limitReachedAt: Date?
        if rawProjection > 100, pointsPerDay > 0 {
            limitReachedAt = now.addingTimeInterval((100 - window.usedPercent) / pointsPerDay * 86_400)
        } else {
            limitReachedAt = nil
        }
        let projectedPercent = Int(rawProjection.rounded())
        // Short windows are front-loaded and commonly over-predict. Keep their
        // projection invisible until it points at a genuinely consequential result.
        if kind == .short, projectedPercent < 60 { return nil }

        return Projection(
            projectedPercent: projectedPercent,
            pointsPerDay: pointsPerDay,
            longTermPointsPerDay: longTermPointsPerDay,
            recentPointsPerDay: recentPointsPerDay,
            lowerProjectedPercent: lowerProjectedPercent,
            upperProjectedPercent: upperProjectedPercent,
            daysRemaining: daysRemaining,
            outlook: outlook,
            limitReachedAt: limitReachedAt,
            isPreliminary: isPreliminary,
            historicalPointsPerDay: historicalPointsPerDay
        )
    }

    private struct RecentEstimate {
        let rate: Double
        let weight: Double
    }

    private static func recentEstimate(
        for window: UsageWindow,
        samples: [ProjectionSample],
        baseline: ProjectionSample,
        now: Date
    ) -> RecentEstimate? {
        let cutoff = max(baseline.timestamp, now.addingTimeInterval(-recentMaximumElapsed))
        var hourlySamples: [Int: ProjectionSample] = [:]

        // Hour buckets prevent a burst of polls from outweighing quieter periods.
        for sample in samples where sample.timestamp >= cutoff && sample.timestamp <= now {
            let bucket = Int(floor(sample.timestamp.timeIntervalSinceReferenceDate / 3_600))
            if let existing = hourlySamples[bucket], existing.timestamp >= sample.timestamp {
                continue
            }
            hourlySamples[bucket] = sample
        }

        let currentBucket = Int(floor(now.timeIntervalSinceReferenceDate / 3_600))
        hourlySamples[currentBucket] = ProjectionSample(
            windowID: window.id,
            timestamp: now,
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt
        )

        let observations = hourlySamples.values.sorted { $0.timestamp < $1.timestamp }
        guard let first = observations.first, observations.count >= 2 else { return nil }

        let span = now.timeIntervalSince(first.timestamp)
        let minimumUsage = observations.map(\.usedPercent).min() ?? window.usedPercent
        let movement = window.usedPercent - minimumUsage
        guard span >= recentMinimumElapsed, movement >= recentMinimumMovement else { return nil }

        var totalWeight = 0.0
        var weightedX = 0.0
        var weightedY = 0.0
        let halfLifeCoefficient = log(2.0) / recentHalfLife

        for sample in observations {
            let age = max(0, now.timeIntervalSince(sample.timestamp))
            let weight = exp(-halfLifeCoefficient * age)
            let x = sample.timestamp.timeIntervalSince(now) / 86_400
            totalWeight += weight
            weightedX += weight * x
            weightedY += weight * sample.usedPercent
        }

        guard totalWeight > 0 else { return nil }
        let meanX = weightedX / totalWeight
        let meanY = weightedY / totalWeight
        var numerator = 0.0
        var denominator = 0.0

        for sample in observations {
            let age = max(0, now.timeIntervalSince(sample.timestamp))
            let weight = exp(-halfLifeCoefficient * age)
            let x = sample.timestamp.timeIntervalSince(now) / 86_400
            numerator += weight * (x - meanX) * (sample.usedPercent - meanY)
            denominator += weight * pow(x - meanX, 2)
        }

        guard denominator > .ulpOfOne else { return nil }
        let rate = numerator / denominator
        guard rate > 0 else { return nil }

        // Confidence grows smoothly with observed movement and time span. It never
        // overwhelms the full-window anchor, even during a short burst of activity.
        let movementWeight = min(
            0.75,
            0.25 + 0.15 * (movement - recentMinimumMovement)
        )
        let spanWeight = min(1.0, span / recentHalfLife)
        return RecentEstimate(rate: rate, weight: movementWeight * spanWeight)
    }
}

@MainActor
public final class ProjectionStore {
    private var samples: [ProjectionSample]
    private let url: URL?
    // Quiet observations are evidence for the recent-pace estimate too. Keep
    // hourly samples, and preserve changed reset timestamps even at zero usage.
    private static let minimumWriteGap: TimeInterval = 60 * 60
    private static let resetTolerance: TimeInterval = 60
    private static let retention: TimeInterval = 8 * 86_400

    public convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DexBar", isDirectory: true)
        self.init(url: directory.appendingPathComponent("projection-history.json"))
    }

    public init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([ProjectionSample].self, from: data) {
            samples = Self.compacted(decoded)
            if samples.count != decoded.count,
               let compactedData = try? JSONEncoder().encode(samples) {
                try? compactedData.write(to: url, options: .atomic)
            }
        } else {
            samples = []
        }
    }

    private init(samples: [ProjectionSample]) {
        self.url = nil
        self.samples = samples
    }

    public static func inMemory() -> ProjectionStore {
        ProjectionStore(samples: [])
    }

    public func record(_ snapshot: UsageSnapshot) {
        var changed = false
        for window in [snapshot.weekly] + snapshot.supplementary {
            let sample = ProjectionSample(
                windowID: window.id,
                timestamp: snapshot.fetchedAt,
                usedPercent: window.usedPercent,
                resetsAt: window.resetsAt
            )
            if let last = samples.last(where: { $0.windowID == sample.windowID }),
               last.usedPercent == sample.usedPercent,
               abs(last.resetsAt.timeIntervalSince(sample.resetsAt)) < Self.resetTolerance,
               sample.timestamp.timeIntervalSince(last.timestamp) < Self.minimumWriteGap {
                continue
            }
            samples.append(sample)
            changed = true
        }
        guard changed else { return }
        let cutoff = snapshot.fetchedAt.addingTimeInterval(-Self.retention)
        samples.removeAll { $0.timestamp < cutoff }
        persist()
    }

    public func projection(for window: UsageWindow, now: Date = Date()) -> Projection? {
        ProjectionCalculator.calculate(
            window: window,
            samples: samples,
            now: now,
            kind: window.isWeekly ? .weekly : .short
        )
    }

    /// A read-only copy used to seed the daily history introduced after projection
    /// sampling was already shipping. Projection remains the owner of this file.
    public func recordedSamples(for windowID: String) -> [ProjectionSample] {
        samples
            .filter { $0.windowID == windowID }
            .sorted { $0.timestamp < $1.timestamp }
    }

    public func clear() {
        samples.removeAll()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func persist() {
        guard let url else { return }
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func compacted(_ input: [ProjectionSample]) -> [ProjectionSample] {
        var result: [ProjectionSample] = []
        for sample in input.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let last = result.last(where: { $0.windowID == sample.windowID }),
               last.usedPercent == sample.usedPercent,
               abs(last.resetsAt.timeIntervalSince(sample.resetsAt)) < Self.resetTolerance,
               sample.timestamp.timeIntervalSince(last.timestamp) < Self.minimumWriteGap {
                continue
            }
            result.append(sample)
        }
        return result
    }
}

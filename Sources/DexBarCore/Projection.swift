import Foundation

public struct Projection: Equatable, Sendable {
    public enum Outlook: Equatable, Sendable { case onTrack, mayRunOut, likelyToRunOut }

    public let projectedPercent: Int
    public let pointsPerDay: Double
    public let daysRemaining: Double
    public let outlook: Outlook
    public let limitReachedAt: Date?

    public init(
        projectedPercent: Int,
        pointsPerDay: Double,
        daysRemaining: Double,
        outlook: Outlook,
        limitReachedAt: Date?
    ) {
        self.projectedPercent = projectedPercent
        self.pointsPerDay = pointsPerDay
        self.daysRemaining = daysRemaining
        self.outlook = outlook
        self.limitReachedAt = limitReachedAt
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

    public init(windowID: String, timestamp: Date, usedPercent: Double, resetsAt: Date) {
        self.windowID = windowID
        self.timestamp = timestamp
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public enum ProjectionCalculator {
    public static func calculate(
        window: UsageWindow,
        samples: [ProjectionSample],
        now: Date,
        kind: ProjectionKind = .weekly,
        minimumElapsed: TimeInterval? = nil
    ) -> Projection? {
        let matching = samples
            .filter { $0.windowID == window.id && abs($0.resetsAt.timeIntervalSince(window.resetsAt)) < 1 }
            .sorted { $0.timestamp < $1.timestamp }
        guard var baseline = matching.first else { return nil }
        for index in 1..<matching.count where matching[index].usedPercent < matching[index - 1].usedPercent - 2 {
            baseline = matching[index]
        }

        let elapsed = now.timeIntervalSince(baseline.timestamp)
        // A weekly estimate needs a full day. One hour is the equivalent share of
        // a five-hour window and matches ClawBar's backtested session estimator.
        let requiredHistory = minimumElapsed ?? (kind == .weekly ? 86_400 : 3_600)
        guard elapsed >= requiredHistory else { return nil }
        let consumed = window.usedPercent - baseline.usedPercent
        guard consumed > 0 else { return nil }

        let pointsPerDay = consumed / elapsed * 86_400
        let daysRemaining = max(0, window.resetsAt.timeIntervalSince(now)) / 86_400
        let rawProjection = window.usedPercent + pointsPerDay * daysRemaining
        let uncertainty = max(3, 1.5 * daysRemaining)

        let outlook: Projection.Outlook
        if rawProjection + uncertainty < 100 { outlook = .onTrack }
        else if rawProjection - uncertainty > 100 { outlook = .likelyToRunOut }
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
            daysRemaining: daysRemaining,
            outlook: outlook,
            limitReachedAt: limitReachedAt
        )
    }
}

@MainActor
public final class ProjectionStore {
    private var samples: [ProjectionSample]
    private let url: URL
    private static let minimumWriteGap: TimeInterval = 10 * 60
    private static let retention: TimeInterval = 8 * 86_400

    public init(url: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DexBar", isDirectory: true)
        self.url = url ?? directory.appendingPathComponent("projection-history.json")
        try? FileManager.default.createDirectory(
            at: self.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? JSONDecoder().decode([ProjectionSample].self, from: data) {
            samples = decoded
        } else {
            samples = []
        }
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
               last.resetsAt == sample.resetsAt,
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

    public func clear() {
        samples.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

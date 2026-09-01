import Foundation

public enum UsageHealth: Int, Codable, Sendable {
    case normal = 0
    case warning = 1
    case critical = 2

    public static func forPercent(_ percent: Double) -> UsageHealth {
        if percent >= 95 { return .critical }
        if percent >= 80 { return .warning }
        return .normal
    }
}

public struct UsageWindow: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let bucketID: String
    public let bucketName: String
    public let usedPercent: Double
    public let durationMinutes: Int
    public let resetsAt: Date
    public let rateLimitReachedType: String?

    public init(
        id: String,
        bucketID: String,
        bucketName: String,
        usedPercent: Double,
        durationMinutes: Int,
        resetsAt: Date,
        rateLimitReachedType: String? = nil
    ) {
        self.id = id
        self.bucketID = bucketID
        self.bucketName = bucketName
        self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
        self.rateLimitReachedType = rateLimitReachedType
    }

    public var roundedPercent: Int { Int(usedPercent.rounded()) }
    public var utilization: Double { min(max(usedPercent / 100, 0), 1) }
    public var health: UsageHealth { .forPercent(usedPercent) }
    public var isActive: Bool { usedPercent > 0.000_1 || rateLimitReachedType != nil }
    public var isWeekly: Bool { durationMinutes >= 6 * 24 * 60 }

    public var title: String {
        switch durationMinutes {
        case 300: return "5-hour window"
        case 10_080: return "Weekly window"
        default:
            if durationMinutes.isMultiple(of: 1_440) {
                return "\(durationMinutes / 1_440)-day window"
            }
            if durationMinutes.isMultiple(of: 60) {
                return "\(durationMinutes / 60)-hour window"
            }
            return "\(durationMinutes)-minute window"
        }
    }
}

public struct UsageCredits: Equatable, Codable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }

    public var isWorthShowing: Bool {
        unlimited || hasCredits || (balance.map { $0 != "0" && $0 != "0.0" } ?? false)
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let weekly: UsageWindow
    public let supplementary: [UsageWindow]
    public let planType: String?
    public let credits: UsageCredits?
    public let resetCreditsAvailable: Int
    public let fetchedAt: Date

    public init(
        weekly: UsageWindow,
        supplementary: [UsageWindow],
        planType: String?,
        credits: UsageCredits?,
        resetCreditsAvailable: Int,
        fetchedAt: Date
    ) {
        self.weekly = weekly
        self.supplementary = supplementary
        self.planType = planType
        self.credits = credits
        self.resetCreditsAvailable = resetCreditsAvailable
        self.fetchedAt = fetchedAt
    }

    /// The menu bar stays weekly unless a live supplementary window is genuinely more
    /// urgent. Inactive zero-valued windows never enter `supplementary` in the first place.
    public var preferredMenuWindow: UsageWindow {
        supplementary.reduce(weekly) { current, candidate in
            if candidate.health.rawValue != current.health.rawValue {
                return candidate.health.rawValue > current.health.rawValue ? candidate : current
            }
            return candidate.usedPercent > current.usedPercent ? candidate : current
        }
    }

    public var worstPercent: Int {
        ([weekly] + supplementary).map(\.roundedPercent).max() ?? weekly.roundedPercent
    }
}

struct AppServerRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: Int64
}

struct AppServerCredits: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct AppServerRateLimitBucket: Decodable {
    let limitId: String
    let limitName: String?
    let primary: AppServerRateLimitWindow?
    let secondary: AppServerRateLimitWindow?
    let rateLimitReachedType: String?
    let planType: String?
    let credits: AppServerCredits?
}

struct AppServerResetCredits: Decodable {
    let availableCount: Int
}

struct AppServerRateLimitsPayload: Decodable {
    let rateLimits: AppServerRateLimitBucket?
    let rateLimitsByLimitId: [String: AppServerRateLimitBucket]?
    let rateLimitResetCredits: AppServerResetCredits?
    let planType: String?
}

enum UsageMappingError: LocalizedError {
    case noRateLimits

    var errorDescription: String? {
        "Codex returned no usable rate-limit windows."
    }
}

enum UsageMapper {
    static func snapshot(from payload: AppServerRateLimitsPayload, now: Date) throws -> UsageSnapshot {
        var buckets = payload.rateLimitsByLimitId ?? [:]
        if buckets.isEmpty, let single = payload.rateLimits {
            buckets[single.limitId] = single
        }
        guard !buckets.isEmpty else { throw UsageMappingError.noRateLimits }

        let general: AppServerRateLimitBucket = buckets["codex"]
            ?? payload.rateLimits
            ?? buckets.sorted(by: { $0.key < $1.key }).first!.value

        let all = buckets.values.flatMap(Self.windows)
        let generalWindows = Self.windows(general)
        guard let weekly = generalWindows.max(by: { $0.durationMinutes < $1.durationMinutes })
                ?? all.max(by: { $0.durationMinutes < $1.durationMinutes }) else {
            throw UsageMappingError.noRateLimits
        }

        let supplementary = all
            .filter { $0.id != weekly.id }
            .filter { window in
                guard window.isActive else { return false }
                // Short active windows are relevant immediately. Peer long windows stay
                // quiet until warning territory, avoiding a stack of near-duplicate 0–5%
                // weekly meters while still surfacing a model-specific cap that matters.
                return window.durationMinutes < weekly.durationMinutes || window.usedPercent >= 80
            }
            .sorted {
                if $0.health.rawValue != $1.health.rawValue {
                    return $0.health.rawValue > $1.health.rawValue
                }
                if $0.durationMinutes != $1.durationMinutes {
                    return $0.durationMinutes < $1.durationMinutes
                }
                return $0.bucketName.localizedCaseInsensitiveCompare($1.bucketName) == .orderedAscending
            }

        let rawCredits = general.credits
        let credits = rawCredits.map {
            UsageCredits(hasCredits: $0.hasCredits, unlimited: $0.unlimited, balance: $0.balance)
        }

        return UsageSnapshot(
            weekly: weekly,
            supplementary: supplementary,
            planType: general.planType ?? payload.planType,
            credits: credits,
            resetCreditsAvailable: payload.rateLimitResetCredits?.availableCount ?? 0,
            fetchedAt: now
        )
    }

    private static func windows(_ bucket: AppServerRateLimitBucket) -> [UsageWindow] {
        let name = bucket.limitName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false ? name! : humanize(bucket.limitId))
        return [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { position, raw in
            raw.map {
                UsageWindow(
                    id: "\(bucket.limitId).\(position)",
                    bucketID: bucket.limitId,
                    bucketName: displayName,
                    usedPercent: $0.usedPercent,
                    durationMinutes: $0.windowDurationMins,
                    resetsAt: Date(timeIntervalSince1970: TimeInterval($0.resetsAt)),
                    rateLimitReachedType: bucket.rateLimitReachedType
                )
            }
        }
    }

    private static func humanize(_ id: String) -> String {
        if id == "codex" { return "General" }
        return id.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

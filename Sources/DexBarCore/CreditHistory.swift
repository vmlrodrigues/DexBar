import Foundation
import CryptoKit

public enum CreditBalance {
    /// Parse the service's decimal string without a binary floating-point round trip.
    public static func parse(_ text: String?) -> Decimal? {
        guard let text, text.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value >= 0 else { return nil }
        return value
    }

    public static func formatted(_ value: Decimal, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "Unavailable"
    }
}

public struct CreditSample: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let balance: Decimal

    public init(timestamp: Date, balance: Decimal) {
        self.timestamp = timestamp
        self.balance = balance
    }
}

public enum CreditForecast: Equatable, Sendable {
    case unavailable
    case waitingForSpending
    case collecting(hours: Int)
    case depleted
    case estimate(CreditEstimate)
}

public struct CreditEstimate: Equatable, Sendable {
    public let creditsPerDay: Double
    public let secondsRemaining: TimeInterval
    public let asOf: Date
    public let preliminary: Bool

    public var runsOutAt: Date { asOf.addingTimeInterval(secondsRemaining) }
}

public enum CreditForecastCalculator {
    public static func calculate(samples: [CreditSample]) -> CreditForecast {
        guard let last = samples.last,
              samples.allSatisfy({ !$0.balance.isNaN && $0.balance >= 0
                  && $0.timestamp >= .distantPast && $0.timestamp <= .distantFuture }) else { return .unavailable }
        if last.balance == 0 { return .depleted }
        // Only the latest uninterrupted, non-increasing segment is evidence.
        var start = 0
        for index in samples.indices.dropFirst() {
            if samples[index].timestamp <= samples[index - 1].timestamp { return .unavailable }
            if samples[index].balance > samples[index - 1].balance { start = index }
        }
        let segment = Array(samples[start...])
        guard let firstDrop = segment.indices.dropFirst().first(where: {
            segment[$0].balance < segment[$0 - 1].balance
        }) else { return .waitingForSpending }
        // Do not use days of unchanged credit balance before spending begins to
        // make a brand new spending rate appear mature or artificially slow.
        let observations = Array(segment[(firstDrop - 1)...])
        let first = observations[0]
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        let dropHours = Set(observations.indices.dropFirst().filter {
            observations[$0].balance < observations[$0 - 1].balance
        }.map { Int(floor(observations[$0].timestamp.timeIntervalSince1970 / 3600)) })
        guard span >= 6 * 3600, dropHours.count >= 2 else {
            return .collecting(hours: min(6, max(0, Int(span / 3600))))
        }
        // Stop presenting a depletion countdown after a full day of no observed
        // spending. A failed refresh never calls this calculator with a later clock.
        let lastDrop = observations.indices.dropFirst().last {
            observations[$0].balance < observations[$0 - 1].balance
        }!
        if last.timestamp.timeIntervalSince(observations[lastDrop].timestamp) >= 86400 {
            return .waitingForSpending
        }
        let spent = NSDecimalNumber(decimal: first.balance - last.balance).doubleValue
        let longRate = spent / span * 86400
        var rate = longRate
        // One observation per hour prevents frequent polling during busy periods
        // from dominating the recent trend. Weight recent hours more strongly.
        let cutoff = last.timestamp.addingTimeInterval(-86400)
        var hours: [Int: CreditSample] = [:]
        for sample in observations where sample.timestamp >= cutoff {
            hours[Int(floor(sample.timestamp.timeIntervalSince1970 / 3600))] = sample
        }
        let recent = hours.values.sorted { $0.timestamp < $1.timestamp }
        if let earliest = recent.first, recent.count >= 3,
           last.timestamp.timeIntervalSince(earliest.timestamp) >= 6 * 3600 {
            let points = recent.map { sample -> (x: Double, y: Double, w: Double) in
                let age = last.timestamp.timeIntervalSince(sample.timestamp)
                return (-age / 86400,
                        NSDecimalNumber(decimal: first.balance - sample.balance).doubleValue,
                        exp(-log(2) * age / (12 * 3600)))
            }
            let weight = points.reduce(0) { $0 + $1.w }
            let mx = points.reduce(0) { $0 + $1.x * $1.w } / weight
            let my = points.reduce(0) { $0 + $1.y * $1.w } / weight
            let numerator = points.reduce(0) { $0 + $1.w * ($1.x - mx) * ($1.y - my) }
            let denominator = points.reduce(0) { $0 + $1.w * pow($1.x - mx, 2) }
            if denominator > 0 {
                let recentRate = max(0, numerator / denominator)
                let blend = min(0.75, last.timestamp.timeIntervalSince(earliest.timestamp) / 86400 * 0.75)
                rate = longRate * (1 - blend) + recentRate * blend
            }
        }
        let remaining = NSDecimalNumber(decimal: last.balance).doubleValue / rate * 86400
        guard rate.isFinite, rate > 0, remaining.isFinite, remaining > 0 else { return .unavailable }
        return .estimate(CreditEstimate(creditsPerDay: rate, secondsRemaining: remaining,
                                        asOf: last.timestamp, preliminary: span < 86400))
    }
}

/// Confined to UsageHistoryWorker so loading and saving never block the UI.
public final class CreditHistoryStore {
    private struct Document: Codable {
        var schemaVersion = 1
        var scopeHash: String?
        var samples: [CreditSample] = []
        var lastRecordedAt: Date?
    }
    private var document = Document()
    private let url: URL?
    private var canPersist = true
    public private(set) var persistenceError: String?
    public private(set) var forecast: CreditForecast = .unavailable

    public init(url: URL?) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let loaded = try decoder.decode(Document.self, from: Data(contentsOf: url))
            guard loaded.schemaVersion == 1,
                  loaded.samples.allSatisfy({ !$0.balance.isNaN && $0.balance >= 0 && $0.timestamp >= .distantPast && $0.timestamp <= .distantFuture }),
                  zip(loaded.samples, loaded.samples.dropFirst()).allSatisfy({ $0.timestamp < $1.timestamp }),
                  loaded.samples.last.map({ last in loaded.lastRecordedAt.map { $0 >= last.timestamp } ?? false }) ?? true
            else { throw CocoaError(.coderReadCorrupt) }
            document = loaded
        } catch {
            // Never overwrite an unreadable or future-version credit history.
            canPersist = false
            persistenceError = "Could not load credit history: \(error.localizedDescription)"
        }
    }

    public static func persistent() -> CreditHistoryStore {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DexBar", isDirectory: true)
        return CreditHistoryStore(url: directory.appendingPathComponent("credit-history.json"))
    }

    public func record(_ snapshot: UsageSnapshot) {
        let now = snapshot.fetchedAt
        guard let accountID = snapshot.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.isEmpty, now >= .distantPast, now <= .distantFuture else {
            // Without identity, even two successive polls may belong to different
            // accounts. Invalid dates likewise cannot establish spending continuity.
            document = Document()
            forecast = .unavailable
            persist()
            return
        }
        // Store only a digest, never the account identifier itself. A plan change
        // also starts fresh because included usage can change the credit-spending pace.
        // Scope must be checked before comparing timestamps from different accounts.
        let identity = accountID + "|" + (snapshot.planType ?? "unknown")
        let scope = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if document.scopeHash != scope {
            document = Document(scopeHash: scope)
        }
        guard let credits = snapshot.credits, !credits.unlimited,
              let balance = CreditBalance.parse(credits.balance) else {
            document.lastRecordedAt = now
            document.samples = []
            forecast = .unavailable
            persist()
            return
        }
        let identicalDuplicate = document.lastRecordedAt == now
            && document.samples.last?.timestamp == now && document.samples.last?.balance == balance
        if let lastRecordedAt = document.lastRecordedAt, now <= lastRecordedAt, !identicalDuplicate {
            // Polls are serialized by AppModel. A backwards clock (or conflicting
            // readings at one timestamp) needs a new baseline, not an old estimate
            // attached to the fresh balance. Persist the reset so relaunches recover too.
            document = Document(scopeHash: scope)
        }
        if let last = document.samples.last,
           balance > last.balance || now.timeIntervalSince(last.timestamp) > 86400 {
            // A top-up/refund or a long offline gap makes the previous rate unsafe.
            document.samples = []
        }
        let hadBalance = document.samples.contains { $0.balance > 0 }
        if !identicalDuplicate { document.samples.append(CreditSample(timestamp: now, balance: balance)) }
        document.lastRecordedAt = now
        document.samples.removeAll { $0.timestamp < now.addingTimeInterval(-8 * 86400) }
        forecast = balance == 0 && !hadBalance && !credits.hasCredits
            ? .unavailable : CreditForecastCalculator.calculate(samples: document.samples)
        persist()
    }

    public func clear() {
        document = Document()
        forecast = .unavailable
        persistenceError = nil
        canPersist = true
        guard let url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch { persistenceError = "Could not clear credit history: \(error.localizedDescription)" }
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
        } catch { persistenceError = "Could not save credit history: \(error.localizedDescription)" }
    }
}

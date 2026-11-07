import XCTest
@testable import DexBarCore

final class WeeklyForecastScopeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// The schema-2 shape shipped in 0.2.5. Codable drops new inline scope fields.
    private struct OldDocument: Codable {
        var schemaVersion: Int
        var timestampEncoding: String
        var readings: [UsageHistoryReading]
        var legacyIntervals: [Int]?
    }

    private func snapshot(_ day: Double, _ percent: Double, reset: Double = 7,
                          account: String? = "account-a", plan: String = "pro",
                          windowID: String = "codex.primary") -> UsageSnapshot {
        UsageSnapshot(
            weekly: UsageWindow(id: windowID, bucketID: "codex", bucketName: "General",
                usedPercent: percent, durationMinutes: 10_080,
                resetsAt: start.addingTimeInterval(reset * 86_400)),
            supplementary: [], planType: plan, credits: nil, resetCreditsAvailable: 0,
            fetchedAt: start.addingTimeInterval(day * 86_400), accountID: account
        )
    }

    private func seed(_ store: UsageHistoryStore) {
        [snapshot(0, 10), snapshot(1, 20), snapshot(5, 60), snapshot(6.99, 79.9)].forEach(store.record)
    }

    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeeklyForecastScope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("usage-readings.json")
    }

    private func scopeURL(_ url: URL) -> URL { url.appendingPathExtension("forecast-scope.json") }

    private func oldWriterRoundtrip(_ url: URL, mutate: (inout OldDocument) -> Void = { _ in }) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var document = try decoder.decode(OldDocument.self, from: Data(contentsOf: url))
        mutate(&document)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    func testOldWriterCannotRestoreExcludedAccountOrPlanHistory() throws {
        for (account, plan) in [("account-b", "pro"), ("account-a", "plus")] {
            let url = try temporaryURL()
            var store = UsageHistoryStore(url: url)
            seed(store)
            let changed = snapshot(7, 0, reset: 14, account: account, plan: plan)
            store.record(changed)
            XCTAssertNil(store.weeklyProjection(for: changed))
            let durable = try Data(contentsOf: scopeURL(url))

            try oldWriterRoundtrip(url)
            XCTAssertEqual(try Data(contentsOf: scopeURL(url)), durable)
            store = UsageHistoryStore(url: url)
            let next = snapshot(7.1, 1, reset: 14, account: account, plan: plan)
            store.record(next)
            XCTAssertNil(store.weeklyProjection(for: next))
            XCTAssertEqual(store.windows(for: next.weekly.id).count, 2)
        }
    }

    func testStableIdentityOldWriterRoundtripPreservesForecast() throws {
        let url = try temporaryURL()
        var store = UsageHistoryStore(url: url)
        seed(store)
        let current = snapshot(7.25, 0, reset: 14.25)
        store.record(current)
        let expected = try XCTUnwrap(store.weeklyProjection(for: current))
        let durable = try Data(contentsOf: scopeURL(url))

        try oldWriterRoundtrip(url)
        store = UsageHistoryStore(url: url)
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(store.weeklyProjection(for: current), expected)
        XCTAssertEqual(try Data(contentsOf: scopeURL(url)), durable)
    }

    func testMissingIdentityCutoffSurvivesOldWriterRoundtrip() throws {
        let url = try temporaryURL()
        var store = UsageHistoryStore(url: url)
        seed(store)
        store.record(snapshot(7, 0, reset: 14, account: nil))
        try oldWriterRoundtrip(url)

        store = UsageHistoryStore(url: url)
        let identified = snapshot(7.1, 1, reset: 14)
        store.record(identified)
        XCTAssertNil(store.weeklyProjection(for: identified))
        let mature = snapshot(8.1, 11, reset: 14)
        store.record(mature)
        XCTAssertEqual(try XCTUnwrap(store.weeklyProjection(for: mature)).longTermPointsPerDay, 10, accuracy: 0.001)
    }

    func testOldWriterAppendedReadingsRequireAnAcceptedFreshBaseline() throws {
        let url = try temporaryURL()
        var store = UsageHistoryStore(url: url)
        seed(store)
        let rollover = snapshot(7, 0, reset: 14)
        store.record(rollover)
        let unscoped = snapshot(7.1, 2, reset: 14)
        try oldWriterRoundtrip(url) { document in
            let previous = document.readings.last!
            document.readings.append(UsageHistoryReading(windowID: previous.windowID,
                timestamp: unscoped.fetchedAt, usedPercent: 2, resetsAt: unscoped.weekly.resetsAt,
                durationMinutes: previous.durationMinutes, cycleStartedAt: previous.cycleStartedAt,
                cycleStartKnown: previous.cycleStartKnown))
        }
        let checkpoint = try Data(contentsOf: scopeURL(url))
        store = UsageHistoryStore(url: url)
        XCTAssertNil(store.weeklyProjection(for: unscoped))
        store.record(unscoped) // A rejected duplicate cannot bind the older writer's data.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        _ = store.windows(for: unscoped.weekly.id, calendar: calendar)
        XCTAssertNil(store.weeklyProjection(for: unscoped))
        XCTAssertEqual(try Data(contentsOf: scopeURL(url)), checkpoint)

        let fresh = snapshot(7.2, 3, reset: 14)
        store.record(fresh)
        XCTAssertNil(store.weeklyProjection(for: fresh))
        let mature = snapshot(8.2, 13, reset: 14)
        store.record(mature)
        XCTAssertEqual(try XCTUnwrap(store.weeklyProjection(for: mature)).longTermPointsPerDay, 10, accuracy: 0.001)
    }

    func testCheckpointDetectsChangedEarlierRowAndAdditionalRowAtSameTimestamp() throws {
        for appendOtherWindow in [false, true] {
            let url = try temporaryURL()
            var store = UsageHistoryStore(url: url)
            seed(store)
            let current = snapshot(7, 0, reset: 14)
            store.record(current)
            try oldWriterRoundtrip(url) { document in
                if appendOtherWindow {
                    let last = document.readings.last!
                    document.readings.append(UsageHistoryReading(windowID: "model.primary",
                        timestamp: last.timestamp, usedPercent: last.usedPercent, resetsAt: last.resetsAt,
                        durationMinutes: last.durationMinutes, cycleStartedAt: last.cycleStartedAt,
                        cycleStartKnown: last.cycleStartKnown))
                } else {
                    let old = document.readings[1]
                    document.readings[1] = UsageHistoryReading(windowID: old.windowID,
                        timestamp: old.timestamp, usedPercent: 21, resetsAt: old.resetsAt,
                        durationMinutes: old.durationMinutes, cycleStartedAt: old.cycleStartedAt,
                        cycleStartKnown: old.cycleStartKnown)
                }
            }
            store = UsageHistoryStore(url: url)
            XCTAssertNil(store.weeklyProjection(for: current))
            store.record(current)
            XCTAssertNil(store.weeklyProjection(for: current))
            let fresh = snapshot(7.1, 1, reset: 14)
            store.record(fresh)
            XCTAssertNil(store.weeklyProjection(for: fresh))
        }
    }

    func testExistingInlineScopeMigratesWithoutRewritingHistory() throws {
        let url = try temporaryURL()
        var store = UsageHistoryStore(url: url)
        seed(store)
        store.record(snapshot(7, 0, reset: 14, account: "account-b"))
        try FileManager.default.removeItem(at: scopeURL(url))
        let original = try Data(contentsOf: url)

        store = UsageHistoryStore(url: url)
        XCTAssertNil(store.persistenceError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scopeURL(url).path))
        XCTAssertEqual(try Data(contentsOf: url), original)
        try oldWriterRoundtrip(url)
        store = UsageHistoryStore(url: url)
        let next = snapshot(7.1, 1, reset: 14, account: "account-b")
        store.record(next)
        XCTAssertNil(store.weeklyProjection(for: next))
    }

    func testGenuinelyUnscopedLegacyHistoryCanStillBeAdopted() throws {
        let url = try temporaryURL()
        var store = UsageHistoryStore(url: url)
        seed(store)
        try oldWriterRoundtrip(url)
        try FileManager.default.removeItem(at: scopeURL(url))

        store = UsageHistoryStore(url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopeURL(url).path))
        let current = snapshot(7, 0, reset: 14)
        store.record(current)
        XCTAssertNotNil(store.weeklyProjection(for: current))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scopeURL(url).path))
    }

    func testClearRemovesDurableScopeAlongWithHistory() throws {
        let url = try temporaryURL()
        var store = UsageHistoryStore(url: url)
        seed(store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scopeURL(url).path))
        store.clear()
        XCTAssertNil(store.persistenceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopeURL(url).path))

        store = UsageHistoryStore(url: url)
        let current = snapshot(7, 0, reset: 14)
        store.record(current)
        XCTAssertNil(store.weeklyProjection(for: current))
    }

    func testUnreadableAndNewerScopePreserveBytesAndFailClosedUntilClear() throws {
        for invalid in [Data("{unreadable".utf8), Data("{\"schemaVersion\":999}".utf8)] {
            let url = try temporaryURL()
            var store = UsageHistoryStore(url: url)
            seed(store)
            let original = try Data(contentsOf: url)
            try invalid.write(to: scopeURL(url))

            store = UsageHistoryStore(url: url)
            XCTAssertNotNil(store.persistenceError)
            let current = snapshot(7, 0, reset: 14)
            store.record(current)
            XCTAssertNil(store.weeklyProjection(for: current))
            XCTAssertNotNil(store.persistenceError)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(try Data(contentsOf: scopeURL(url)), invalid)

            store.clear()
            XCTAssertNil(store.persistenceError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: scopeURL(url).path))
            store.record(snapshot(7.1, 1, reset: 14))
            XCTAssertNil(store.persistenceError)
        }
    }

    func testFailedScopeWriteDoesNotCommitNewAccountHistoryAndCanRetry() throws {
        let url = try temporaryURL()
        var store = UsageHistoryStore(url: url)
        seed(store)
        let original = try Data(contentsOf: url)
        let originalScope = try Data(contentsOf: scopeURL(url))
        try FileManager.default.removeItem(at: scopeURL(url))
        try FileManager.default.createDirectory(at: scopeURL(url), withIntermediateDirectories: false)

        let changed = snapshot(7, 0, reset: 14, account: "account-b")
        store.record(changed)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertNil(store.weeklyProjection(for: changed))
        XCTAssertEqual(try Data(contentsOf: url), original)

        try FileManager.default.removeItem(at: scopeURL(url))
        try originalScope.write(to: scopeURL(url))
        let retry = snapshot(7.1, 1, reset: 14, account: "account-b")
        store.record(retry)
        XCTAssertNil(store.persistenceError)
        XCTAssertNil(store.weeklyProjection(for: retry))
        store = UsageHistoryStore(url: url)
        XCTAssertNil(store.weeklyProjection(for: retry))
        XCTAssertNil(store.persistenceError)
    }

    func testScopeCommittedBeforeHistoryFailureRequiresFreshBaselineAfterReload() throws {
        let url = try temporaryURL()
        var store = UsageHistoryStore(url: url)
        seed(store)
        let originalHistory = try Data(contentsOf: url)
        let originalScope = try Data(contentsOf: scopeURL(url))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let changed = snapshot(7, 0, reset: 14, account: "account-b")
        store.record(changed)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertNotEqual(try Data(contentsOf: scopeURL(url)), originalScope)

        // A crash between the two writes leaves the previous history document.
        try FileManager.default.removeItem(at: url)
        try originalHistory.write(to: url)
        store = UsageHistoryStore(url: url)
        XCTAssertNil(store.weeklyProjection(for: changed))
        let fresh = snapshot(7.1, 1, reset: 14, account: "account-b")
        store.record(fresh)
        XCTAssertNil(store.weeklyProjection(for: fresh))
        let mature = snapshot(8.1, 11, reset: 14, account: "account-b")
        store.record(mature)
        XCTAssertEqual(try XCTUnwrap(store.weeklyProjection(for: mature)).longTermPointsPerDay, 10, accuracy: 0.001)
    }

    func testAbsentCheckpointCannotBeAdvancedByPresentationOrRejectedPoll() throws {
        let url = try temporaryURL()
        var store = UsageHistoryStore(url: url)
        seed(store)
        let current = snapshot(7, 0, reset: 14)
        store.record(current)
        var scope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: scopeURL(url))) as? [String: Any])
        scope.removeValue(forKey: "recordedThrough")
        scope.removeValue(forKey: "readingsHash")
        let checkpoint = try JSONSerialization.data(withJSONObject: scope)
        try checkpoint.write(to: scopeURL(url))

        store = UsageHistoryStore(url: url)
        _ = store.windows(for: current.weekly.id)
        store.record(current)
        XCTAssertNil(store.weeklyProjection(for: current))
        XCTAssertEqual(try Data(contentsOf: scopeURL(url)), checkpoint)
        let fresh = snapshot(7.1, 1, reset: 14)
        store.record(fresh)
        XCTAssertNil(store.weeklyProjection(for: fresh))
        XCTAssertNotEqual(try Data(contentsOf: scopeURL(url)), checkpoint)
    }

    func testQueuedCorrectionRepairCannotBlessOldWriterReadingsBeforeFreshPoll() throws {
        let url = try temporaryURL()
        var store = UsageHistoryStore(url: url)
        [snapshot(0, 0), snapshot(3, 40)].forEach(store.record)
        let splitAt = snapshot(3.01, 39).fetchedAt
        let latest = snapshot(3.02, 42)
        try oldWriterRoundtrip(url) { document in
            let previous = document.readings.last!
            document.readings.append(UsageHistoryReading(windowID: previous.windowID,
                timestamp: splitAt, usedPercent: 39, resetsAt: previous.resetsAt.addingTimeInterval(-1),
                durationMinutes: previous.durationMinutes, cycleStartedAt: splitAt, cycleStartKnown: false))
            document.readings.append(UsageHistoryReading(windowID: previous.windowID,
                timestamp: latest.fetchedAt, usedPercent: 42, resetsAt: previous.resetsAt,
                durationMinutes: previous.durationMinutes, cycleStartedAt: splitAt, cycleStartKnown: false))
        }
        let originalHistory = try Data(contentsOf: url)
        let originalScope = try Data(contentsOf: scopeURL(url))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let oldRows = try decoder.decode(OldDocument.self, from: originalHistory).readings

        store = UsageHistoryStore(url: url)
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(store.windows(for: latest.weekly.id).count, 1)
        XCTAssertNil(store.weeklyProjection(for: latest))
        store.record(latest) // The repair must not turn this rejected duplicate into a bind.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        _ = store.windows(for: latest.weekly.id, calendar: calendar)
        XCTAssertEqual(try Data(contentsOf: url), originalHistory)
        XCTAssertEqual(try Data(contentsOf: scopeURL(url)), originalScope)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.contains("v2-backup") })
        XCTAssertEqual(try Data(contentsOf: backup), originalHistory)

        let fresh = snapshot(3.1, 43)
        store.record(fresh)
        XCTAssertNil(store.weeklyProjection(for: fresh))
        let repaired = try decoder.decode(OldDocument.self, from: Data(contentsOf: url)).readings
        XCTAssertEqual(repaired.count, oldRows.count + 1)
        XCTAssertEqual(Array(repaired.prefix(oldRows.count)).map(\.usedPercent), oldRows.map(\.usedPercent))
        XCTAssertEqual(Array(repaired.prefix(oldRows.count)).map(\.timestamp), oldRows.map(\.timestamp))
        XCTAssertEqual(Array(repaired.prefix(oldRows.count)).map(\.resetsAt), oldRows.map(\.resetsAt))
        XCTAssertTrue(repaired.allSatisfy { $0.cycleStartedAt == start && $0.cycleStartKnown })
        XCTAssertNotEqual(try Data(contentsOf: scopeURL(url)), originalScope)
        let mature = snapshot(4.1, 53)
        store.record(mature)
        XCTAssertEqual(try XCTUnwrap(store.weeklyProjection(for: mature)).longTermPointsPerDay, 10, accuracy: 0.001)
    }

    func testCrossWindowBackwardAccountChangeExcludesAllFutureOldScopeReadings() throws {
        let url = try temporaryURL()
        var store = UsageHistoryStore(url: url)
        [snapshot(0, 10), snapshot(1, 20), snapshot(2, 30)].forEach(store.record)
        let backwards = snapshot(1.5, 0, reset: 8.5, account: "account-b", windowID: "codex.secondary")
        store.record(backwards)
        XCTAssertNil(store.weeklyProjection(for: backwards))
        let scope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: scopeURL(url))) as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(scope["historySince"] as? Double), snapshot(2, 30).fetchedAt.timeIntervalSince1970)
        store = UsageHistoryStore(url: url)
        let firstEligible = snapshot(2.1, 31, account: "account-b")
        store.record(firstEligible)
        let stillYoung = snapshot(3, 40, account: "account-b")
        store.record(stillYoung)
        XCTAssertNil(store.weeklyProjection(for: stillYoung))
        store = UsageHistoryStore(url: url)
        XCTAssertNil(store.weeklyProjection(for: stillYoung))

        let mature = snapshot(3.1, 41, account: "account-b")
        store.record(mature)
        let projection = try XCTUnwrap(store.weeklyProjection(for: mature))
        XCTAssertEqual(projection.longTermPointsPerDay, 10, accuracy: 0.001)
        XCTAssertFalse(projection.isPreliminary)
        XCTAssertEqual(UsageHistoryStore(url: url).weeklyProjection(for: mature), projection)
    }

    func testPendingRebindInAnotherWindowCannotBlessFutureOldWriterReadings() throws {
        let url = try temporaryURL()
        var store = UsageHistoryStore(url: url)
        [snapshot(0, 10), snapshot(1, 20)].forEach(store.record)
        let unscoped = snapshot(2, 30)
        try oldWriterRoundtrip(url) { document in
            let previous = document.readings.last!
            document.readings.append(UsageHistoryReading(windowID: previous.windowID,
                timestamp: unscoped.fetchedAt, usedPercent: 30, resetsAt: unscoped.weekly.resetsAt,
                durationMinutes: previous.durationMinutes, cycleStartedAt: previous.cycleStartedAt,
                cycleStartKnown: previous.cycleStartKnown))
        }
        store = UsageHistoryStore(url: url)
        XCTAssertNil(store.weeklyProjection(for: unscoped))
        let backwards = snapshot(1.5, 0, reset: 8.5, windowID: "codex.secondary")
        store.record(backwards)
        XCTAssertNil(store.weeklyProjection(for: backwards))
        let scope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: scopeURL(url))) as? [String: Any])
        XCTAssertGreaterThan(try XCTUnwrap(scope["historySince"] as? Double), unscoped.fetchedAt.timeIntervalSince1970)
        store = UsageHistoryStore(url: url)

        let firstEligible = snapshot(2.1, 31)
        store.record(firstEligible)
        let stillYoung = snapshot(3, 40)
        store.record(stillYoung)
        XCTAssertNil(store.weeklyProjection(for: stillYoung))
        store = UsageHistoryStore(url: url)
        XCTAssertNil(store.weeklyProjection(for: stillYoung))
        let mature = snapshot(3.1, 41)
        store.record(mature)
        let projection = try XCTUnwrap(store.weeklyProjection(for: mature))
        XCTAssertEqual(projection.longTermPointsPerDay, 10, accuracy: 0.001)
        XCTAssertFalse(projection.isPreliminary)
        XCTAssertEqual(UsageHistoryStore(url: url).weeklyProjection(for: mature), projection)
    }
}

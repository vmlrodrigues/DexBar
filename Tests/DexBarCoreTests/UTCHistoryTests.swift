import XCTest
@testable import DexBarCore

final class UTCHistoryTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func calendar(_ zone: String) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }
    private func snapshot(_ percent: Double, _ at: Date, reset: Date) -> UsageSnapshot {
        UsageSnapshot(weekly: UsageWindow(id: "codex.primary", bucketID: "codex", bucketName: "General",
            usedPercent: percent, durationMinutes: 10_080, resetsAt: reset), supplementary: [],
            planType: "pro", credits: nil, resetCreditsAvailable: 0, fetchedAt: at)
    }
    private func temporaryURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("UTCHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("usage-history.json")
    }

    @MainActor
    func testSydneyUTCSydneyReturnDoesNotDowngradeThursday() throws {
        let url = try temporaryURL()
        let reset = date("2026-09-15T01:46:16Z")
        let sequence: [(String, String, Double)] = [
            ("Australia/Sydney", "2026-09-09T13:57:00Z", 7),
            ("Australia/Sydney", "2026-09-09T14:02:00Z", 7),
            ("Australia/Sydney", "2026-09-10T09:44:00Z", 10),
            ("GMT", "2026-09-10T10:03:00Z", 11),
            ("Australia/Sydney", "2026-09-10T10:07:00Z", 11),
            ("Australia/Sydney", "2026-09-10T13:57:00Z", 18),
            ("Australia/Sydney", "2026-09-10T14:02:00Z", 18),
        ]
        for (zone, at, percent) in sequence {
            UsageHistoryStore(url: url, calendar: calendar(zone)).record(snapshot(percent, date(at), reset: reset))
        }
        let store = UsageHistoryStore(url: url, calendar: calendar("Australia/Sydney"))
        let thursday = try XCTUnwrap(store.windows(for: "codex.primary").first?.days.first { $0.dayStart == date("2026-09-09T14:00:00Z") })
        XCTAssertEqual(thursday.usedPercent, 11)
        XCTAssertEqual(thursday.coverage, .observed)
        let encoded = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(encoded.contains("Australia/Sydney"))
        XCTAssertFalse(encoded.contains("timeZoneIdentifier"))
        XCTAssertFalse(encoded.contains("dayStart"))
        XCTAssertTrue(encoded.contains("unixSecondsUTC"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let readings = try XCTUnwrap(object["readings"] as? [[String: Any]])
        XCTAssertEqual(readings.count, sequence.count)
        XCTAssertEqual(readings[0]["timestamp"] as? Double, date(sequence[0].1).timeIntervalSince1970)
    }

    @MainActor
    func testDateLineAndFractionalOffsetViewsConserveUsage() throws {
        let store = UsageHistoryStore.inMemory()
        let start = date("2026-09-01T00:00:00Z")
        let reset = start.addingTimeInterval(7 * 86_400)
        // Frequent readings make the local boundary attribution precise; no offline gap.
        for step in 0...576 {
            store.record(snapshot(Double(step / 12), start.addingTimeInterval(Double(step) * 300), reset: reset))
        }
        var ids = Set<String>()
        for zone in ["Australia/Sydney", "Pacific/Honolulu", "Pacific/Kiritimati", "Asia/Kathmandu", "America/Los_Angeles", "Europe/London", "Australia/Sydney"] {
            let windows = store.windows(for: "codex.primary", calendar: calendar(zone))
            let window = try XCTUnwrap(windows.first)
            ids.insert(window.id)
            XCTAssertEqual(windows.count, 1)
            XCTAssertEqual(window.days.compactMap(\.usedPercent).reduce(0, +), 48, zone)
            XCTAssertTrue(window.days.allSatisfy { $0.coverage == .observed }, zone)
            XCTAssertEqual(Set(window.days.map(\.dayStart)).count, window.days.count, zone)
        }
        XCTAssertEqual(ids.count, 1)
    }

    @MainActor
    func testDSTUses23And25HourDaysWithoutDoubleCounting() throws {
        for (startText, hours) in [("2026-10-03T14:00:00Z", 23), ("2026-04-04T13:00:00Z", 25)] {
            let start = date(startText)
            let store = UsageHistoryStore.inMemory(calendar: calendar("Australia/Sydney"))
            let reset = start.addingTimeInterval(7 * 86_400)
            for step in 0...(hours * 12) {
                store.record(snapshot(Double(step / 12), start.addingTimeInterval(Double(step) * 300), reset: reset))
            }
            let days = try XCTUnwrap(store.windows(for: "codex.primary").first?.days)
            XCTAssertEqual(days.count, 2)
            XCTAssertEqual(days[1].dayStart.timeIntervalSince(days[0].dayStart), Double(hours) * 3_600)
            XCTAssertEqual(days.compactMap(\.usedPercent).reduce(0, +), Double(hours))
            XCTAssertEqual(Set(days.map(\.dayStart)).count, 2)
        }
    }

    @MainActor
    func testChangingDisplayCalendarNeedsNoNewPollAndDoesNotWrite() throws {
        let url = try temporaryURL()
        let store = UsageHistoryStore(url: url, calendar: calendar("GMT"))
        let reset = date("2026-09-08T00:00:00Z")
        store.record(snapshot(0, date("2026-09-01T00:00:00Z"), reset: reset))
        store.record(snapshot(5, date("2026-09-01T13:58:00Z"), reset: reset))
        store.record(snapshot(7, date("2026-09-01T14:03:00Z"), reset: reset))
        let bytes = try Data(contentsOf: url)
        let utc = store.windows(for: "codex.primary", calendar: calendar("GMT"))
        let sydney = store.windows(for: "codex.primary", calendar: calendar("Australia/Sydney"))
        XCTAssertEqual(utc.first?.days.count, 1)
        XCTAssertEqual(sydney.first?.days.count, 2)
        XCTAssertEqual(utc.first?.days.first?.usedPercent, 7)
        XCTAssertEqual(sydney.first?.days.last?.usedPercent, 2)
        XCTAssertEqual(store.windows(for: "codex.primary", calendar: calendar("GMT")), utc)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    @MainActor
    func testLegacyMigrationRepairsCoverageAndPreservesExactBackup() throws {
        let url = try temporaryURL()
        let reset = date("2026-09-15T01:46:16Z")
        let start = date("2026-09-08T01:22:00Z")
        func day(_ midnight: String, _ first: String, _ last: String, _ from: Double, _ to: Double,
                 zone: String = "Australia/Sydney", coverage: DailyUsageCoverage = .observed) -> DailyUsageRecord {
            DailyUsageRecord(windowID: "codex.primary", windowResetsAt: reset, windowDurationMinutes: 10_080,
                dayStart: date(midnight), timeZoneIdentifier: zone, startingPercent: from, endingPercent: to,
                firstObservedAt: date(first), lastObservedAt: date(last), coverage: coverage, windowStartedAt: start)
        }
        let days = [
            day("2026-09-07T14:00:00Z", "2026-09-08T01:22:00Z", "2026-09-08T08:30:00Z", 0, 0),
            day("2026-09-08T14:00:00Z", "2026-09-09T00:07:00Z", "2026-09-09T13:57:00Z", 0, 7),
            day("2026-09-09T14:00:00Z", "2026-09-09T14:02:00Z", "2026-09-10T13:57:00Z", 7, 18, coverage: .partial),
            day("2026-09-10T00:00:00Z", "2026-09-10T10:03:00Z", "2026-09-10T10:03:00Z", 11, 11, zone: "GMT", coverage: .partial),
            day("2026-09-10T14:00:00Z", "2026-09-10T14:02:00Z", "2026-09-10T14:02:00Z", 18, 18),
        ]
        let encodedDays = try JSONSerialization.jsonObject(with: JSONEncoder().encode(days))
        let legacy = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "days": encodedDays, "latestObservations": []])
        try legacy.write(to: url)
        let samples = [ProjectionSample(windowID: "codex.primary", timestamp: date("2026-09-09T14:58:00Z"), usedPercent: 7, resetsAt: reset)]
        try JSONEncoder().encode(samples).write(to: url.deletingLastPathComponent().appendingPathComponent("projection-history.json"))
        let store = UsageHistoryStore(url: url, calendar: calendar("Australia/Sydney"))
        XCTAssertNil(store.persistenceError)
        let thursday = try XCTUnwrap(store.windows(for: "codex.primary").first?.days.first { $0.dayStart == date("2026-09-09T14:00:00Z") })
        XCTAssertEqual(thursday.usedPercent, 11)
        XCTAssertEqual(thursday.coverage, .observed)
        let wednesday = try XCTUnwrap(store.windows(for: "codex.primary").first?.days.first { $0.dayStart == date("2026-09-08T14:00:00Z") })
        XCTAssertEqual(wednesday.usedPercent, 7)
        XCTAssertEqual(wednesday.coverage, .observed)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("v1-backup") })
        XCTAssertEqual(try Data(contentsOf: backup), legacy)
        let migrated = try Data(contentsOf: url)
        let reloaded = UsageHistoryStore(url: url, calendar: calendar("Australia/Sydney"))
        XCTAssertEqual(reloaded.windows(for: "codex.primary"), store.windows(for: "codex.primary"))
        XCTAssertEqual(try Data(contentsOf: url), migrated)
        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    @MainActor
    func testMigrationDoesNotPretendSummaryBaselineWasAnActualFirstReading() throws {
        let url = try temporaryURL()
        let reset = date("2026-09-08T00:00:00Z")
        let record = DailyUsageRecord(windowID: "codex.primary", windowResetsAt: reset, windowDurationMinutes: 10_080,
            dayStart: date("2026-09-02T00:00:00Z"), timeZoneIdentifier: "GMT", startingPercent: 10,
            endingPercent: 30, firstObservedAt: date("2026-09-02T08:00:00Z"), lastObservedAt: date("2026-09-02T12:00:00Z"),
            coverage: .estimated, windowStartedAt: date("2026-09-01T00:00:00Z"))
        let days = try JSONSerialization.jsonObject(with: JSONEncoder().encode([record]))
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "days": days, "latestObservations": []]).write(to: url)
        let store = UsageHistoryStore(url: url, calendar: calendar("GMT"))
        let day = try XCTUnwrap(store.windows(for: "codex.primary").first?.days.first)
        XCTAssertEqual(day.usedPercent, 20)
        XCTAssertEqual(day.coverage, .estimated)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let readings = try XCTUnwrap(object["readings"] as? [[String: Any]])
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings[0]["timestamp"] as? Double, record.lastObservedAt?.timeIntervalSince1970)
        XCTAssertEqual(readings[0]["usedPercent"] as? Double, 30)
    }

    @MainActor
    func testRetiredFileCannotOverwriteUTCStoreOrResurrectClearedHistory() throws {
        let oldURL = try temporaryURL()
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent("usage-readings.json")
        let legacy = Data("{\"schemaVersion\":1,\"days\":[],\"latestObservations\":[]}".utf8)
        try legacy.write(to: oldURL)
        let store = UsageHistoryStore(url: newURL, legacyURL: oldURL)
        XCTAssertEqual(try Data(contentsOf: oldURL), legacy)
        store.record(snapshot(10, date("2026-09-02T00:00:00Z"), reset: date("2026-09-08T00:00:00Z")))
        let expected = store.windows(for: "codex.primary")
        // An old app can continue writing its own file without touching the new one.
        try Data("old app wrote here".utf8).write(to: oldURL)
        let reloaded = UsageHistoryStore(url: newURL, legacyURL: oldURL)
        XCTAssertEqual(reloaded.windows(for: "codex.primary"), expected)
        reloaded.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(UsageHistoryStore(url: newURL, legacyURL: oldURL).windows(for: "codex.primary").isEmpty)
    }

    @MainActor
    func testUnknownSchemaIsNeverOverwrittenByPolling() throws {
        let url = try temporaryURL()
        let bytes = Data("{\"schemaVersion\":999,\"readings\":[]}".utf8)
        try bytes.write(to: url)
        let store = UsageHistoryStore(url: url)
        store.record(snapshot(10, date("2026-09-02T00:00:00Z"), reset: date("2026-09-08T00:00:00Z")))
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    @MainActor
    func testDuplicateAndOutOfOrderReadingsDoNotCreateResets() throws {
        let url = try temporaryURL()
        let store = UsageHistoryStore(url: url)
        let reset = date("2026-09-08T00:00:00Z")
        let at = date("2026-09-02T00:00:00Z")
        store.record(snapshot(10, at, reset: reset))
        let bytes = try Data(contentsOf: url)
        store.record(snapshot(0, at, reset: reset))
        store.record(snapshot(0, at.addingTimeInterval(-300), reset: reset))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(store.windows(for: "codex.primary").count, 1)
    }
    private func partialLegacyFile(at url: URL) throws {
        let record = DailyUsageRecord(windowID: "codex.primary", windowResetsAt: date("2026-08-28T00:00:00Z"),
            windowDurationMinutes: 10_080, dayStart: date("2026-08-25T00:00:00Z"), timeZoneIdentifier: "GMT",
            startingPercent: 10, endingPercent: 25, firstObservedAt: date("2026-08-25T09:00:00Z"),
            lastObservedAt: date("2026-08-25T17:00:00Z"), coverage: .partial, windowStartedAt: date("2026-08-21T00:00:00Z"))
        let days = try JSONSerialization.jsonObject(with: JSONEncoder().encode([record]))
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "days": days, "latestObservations": []]).write(to: url)
    }

    func testMigrationKeepsPartialTotalWithoutProjectionSamplesAndAcrossReloads() throws {
        let url = try temporaryURL()
        try partialLegacyFile(at: url)
        var store = UsageHistoryStore(url: url, calendar: calendar("GMT"))
        XCTAssertEqual(store.windows(for: "codex.primary").first?.days.first?.usedPercent, 15)
        XCTAssertEqual(store.windows(for: "codex.primary").first?.days.first?.coverage, .partial)
        let bytes = try Data(contentsOf: url)
        // The summary cannot be silently relabelled as a day with different UTC bounds.
        _ = store.windows(for: "codex.primary", calendar: calendar("Australia/Sydney"))
        XCTAssertEqual(store.windows(for: "codex.primary", calendar: calendar("GMT")).first?.days.first?.usedPercent, 15)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        store = UsageHistoryStore(url: url, calendar: calendar("GMT"))
        store.record(snapshot(27, date("2026-08-25T18:00:00Z"), reset: date("2026-08-28T00:00:00Z")))
        XCTAssertEqual(store.windows(for: "codex.primary").first?.days.first?.usedPercent, 17)
        XCTAssertEqual(UsageHistoryStore(url: url, calendar: calendar("GMT")).windows(for: "codex.primary").first?.days.first?.usedPercent, 17)
    }

    func testEarlierUTCDevelopmentDocumentRecoversOmittedSummariesWithoutDroppingNewReadings() throws {
        let legacy = try temporaryURL()
        try partialLegacyFile(at: legacy)
        let url = legacy.deletingLastPathComponent().appendingPathComponent("usage-readings.json")
        let store = UsageHistoryStore(url: url, calendar: calendar("GMT"), legacyURL: legacy)
        store.record(snapshot(27, date("2026-08-25T18:00:00Z"), reset: date("2026-08-28T00:00:00Z")))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "legacyIntervals")
        let earlierBytes = try JSONSerialization.data(withJSONObject: object)
        try earlierBytes.write(to: url)
        let upgraded = UsageHistoryStore(url: url, calendar: calendar("GMT"), legacyURL: legacy)
        XCTAssertNil(upgraded.persistenceError)
        XCTAssertEqual(upgraded.windows(for: "codex.primary").first?.days.first?.usedPercent, 17)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("v2-backup") })
        XCTAssertEqual(try Data(contentsOf: backup), earlierBytes)
        let upgradedBytes = try Data(contentsOf: url)
        _ = UsageHistoryStore(url: url, calendar: calendar("GMT"), legacyURL: legacy)
        XCTAssertEqual(try Data(contentsOf: url), upgradedBytes)
        upgraded.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testEarlyResetUsesSameLocalDayBoundsInsteadOfRequiringAnExactResetTime() throws {
        let url = try temporaryURL()
        let reset = date("2026-09-07T20:40:00Z")
        let store = UsageHistoryStore(url: url, calendar: calendar("GMT"))
        store.record(snapshot(60, date("2026-09-02T09:00:00Z"), reset: reset))
        store.record(snapshot(15, date("2026-09-02T12:00:00Z"), reset: reset))
        for zone in ["GMT", "Australia/Sydney", "America/Los_Angeles"] {
            let windows = UsageHistoryStore(url: url, calendar: calendar(zone)).windows(for: "codex.primary")
            XCTAssertEqual(windows.count, 2)
            XCTAssertEqual(windows.first?.days.first?.usedPercent, 15, zone)
            XCTAssertEqual(windows.first?.days.first?.coverage, .observed, zone)
        }
        let overnight = UsageHistoryStore.inMemory()
        overnight.record(snapshot(60, date("2026-09-02T23:00:00Z"), reset: reset))
        overnight.record(snapshot(15, date("2026-09-03T01:00:00Z"), reset: reset))
        XCTAssertEqual(overnight.windows(for: "codex.primary", calendar: calendar("GMT")).first?.days.first?.coverage, .partial)
        XCTAssertEqual(overnight.windows(for: "codex.primary", calendar: calendar("Australia/Sydney")).first?.days.first?.usedPercent, 15)
        XCTAssertEqual(overnight.windows(for: "codex.primary", calendar: calendar("Australia/Sydney")).first?.days.first?.coverage, .observed)
    }

    func testPresentationCacheMatchesFreshReplayAfterAppendsPruningAndClear() throws {
        let url = try temporaryURL()
        let store = UsageHistoryStore(url: url, calendar: calendar("GMT"), retention: 2 * 86_400)
        let sequence = [("2026-09-01T12:00:00Z", "2026-09-07T20:40:00Z", 10.0),
                        ("2026-09-01T13:00:00Z", "2026-09-07T20:40:00Z", 15.0),
                        ("2026-09-05T12:00:00Z", "2026-09-12T12:00:00Z", 5.0)]
        for (at, reset, percent) in sequence {
            store.record(snapshot(percent, date(at), reset: date(reset)))
            let expected = UsageHistoryStore(url: url, calendar: calendar("GMT")).windows(for: "codex.primary")
            XCTAssertEqual(store.windows(for: "codex.primary"), expected)
            XCTAssertEqual(store.windows(for: "codex.primary"), expected)
        }
        XCTAssertEqual(store.windows(for: "codex.primary").count, 1)
        store.clear()
        XCTAssertTrue(store.windows(for: "codex.primary").isEmpty)
        store.record(snapshot(25, date("2026-09-05T14:00:00Z"), reset: date("2026-09-12T12:00:00Z")))
        XCTAssertEqual(store.windows(for: "codex.primary"), UsageHistoryStore(url: url, calendar: calendar("GMT")).windows(for: "codex.primary"))
    }

    func testWorkerRejectsUpdatesOvertakenByClearAndPreservesNewerUpdates() async throws {
        let url = try temporaryURL()
        let worker = UsageHistoryWorker(store: UsageHistoryStore(url: url))
        let reset = date("2026-09-08T00:00:00Z")
        _ = await worker.update(snapshot(10, date("2026-09-02T09:00:00Z"), reset: reset), projectionSamples: [], calendar: calendar("GMT"), generation: 0)
        _ = await worker.clear(generation: 1)
        let stale = await worker.update(snapshot(15, date("2026-09-02T10:00:00Z"), reset: reset), projectionSamples: [], calendar: calendar("GMT"), generation: 0)
        XCTAssertTrue(stale.windows.isEmpty)
        // Simulate the next refresh reaching the actor before an older queued clear.
        _ = await worker.update(snapshot(20, date("2026-09-02T11:00:00Z"), reset: reset), projectionSamples: [], calendar: calendar("GMT"), generation: 2)
        _ = await worker.clear(generation: 2)
        let kept = await worker.presentation(for: "codex.primary", calendar: calendar("GMT"))
        XCTAssertEqual(kept.first?.lastObservedDay?.endingPercent, 20)
        let cleared = await worker.presentation(for: "codex.primary", calendar: calendar("GMT"), generation: 3)
        XCTAssertTrue(cleared.isEmpty)
        _ = await worker.clear(generation: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

}

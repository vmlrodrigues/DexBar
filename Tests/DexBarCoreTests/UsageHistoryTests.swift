import XCTest
@testable import DexBarCore

final class UsageHistoryTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_AU")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @MainActor
    func testSameDayHistoryTracksUsageSinceFirstObservation() throws {
        let store = UsageHistoryStore.inMemory(calendar: utcCalendar)
        let reset = date("2026-09-07T20:40:00Z")
        store.record(snapshot(percent: 10, at: date("2026-09-01T09:00:00Z"), reset: reset))
        store.record(snapshot(percent: 16, at: date("2026-09-01T12:00:00Z"), reset: reset))

        let day = try XCTUnwrap(store.windows(for: "codex.primary").first?.days.first)
        XCTAssertEqual(day.startingPercent, 10)
        XCTAssertEqual(day.endingPercent, 16)
        XCTAssertEqual(day.usedPercent, 6)
        XCTAssertEqual(day.coverage, .partial)
    }

    @MainActor
    func testShortMidnightGapAttributesDeltaToNewDay() throws {
        let store = UsageHistoryStore.inMemory(calendar: utcCalendar)
        let reset = date("2026-09-07T20:40:00Z")
        store.record(snapshot(percent: 10, at: date("2026-09-01T09:00:00Z"), reset: reset))
        store.record(snapshot(percent: 40, at: date("2026-09-01T23:58:00Z"), reset: reset))
        store.record(snapshot(percent: 42, at: date("2026-09-02T00:03:00Z"), reset: reset))

        let days = try XCTUnwrap(store.windows(for: "codex.primary").first?.days)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[1].startingPercent, 40)
        XCTAssertEqual(days[1].endingPercent, 42)
        XCTAssertEqual(days[1].usedPercent, 2)
        XCTAssertEqual(days[1].coverage, .observed)
    }

    @MainActor
    func testLongMidnightGapIsMarkedEstimated() throws {
        let store = UsageHistoryStore.inMemory(calendar: utcCalendar)
        let reset = date("2026-09-07T20:40:00Z")
        store.record(snapshot(percent: 40, at: date("2026-09-01T23:00:00Z"), reset: reset))
        store.record(snapshot(percent: 50, at: date("2026-09-02T08:00:00Z"), reset: reset))

        let day = try XCTUnwrap(store.windows(for: "codex.primary").first?.days.last)
        XCTAssertEqual(day.usedPercent, 10)
        XCTAssertEqual(day.coverage, .estimated)
    }

    @MainActor
    func testMultiDayGapDoesNotInventDailyAttribution() throws {
        let store = UsageHistoryStore.inMemory(calendar: utcCalendar)
        let reset = date("2026-09-07T20:40:00Z")
        store.record(snapshot(percent: 40, at: date("2026-09-01T20:00:00Z"), reset: reset))
        store.record(snapshot(percent: 55, at: date("2026-09-04T08:00:00Z"), reset: reset))

        let days = try XCTUnwrap(store.windows(for: "codex.primary").first?.days)
        XCTAssertEqual(days.count, 4)
        XCTAssertEqual(days.dropFirst().map(\.coverage), [.unavailable, .unavailable, .unavailable])
        XCTAssertTrue(days.dropFirst().allSatisfy { $0.usedPercent == nil })
    }

    @MainActor
    func testWindowResetCreatesSeparateCycleStartingAtZero() throws {
        let store = UsageHistoryStore.inMemory(calendar: utcCalendar)
        let oldReset = date("2026-09-02T20:40:00Z")
        let newReset = date("2026-09-09T20:40:00Z")
        store.record(snapshot(percent: 90, at: date("2026-09-02T20:35:00Z"), reset: oldReset))
        store.record(snapshot(percent: 3, at: date("2026-09-02T20:45:00Z"), reset: newReset))

        let windows = store.windows(for: "codex.primary")
        XCTAssertEqual(windows.count, 2)
        let newestDay = try XCTUnwrap(windows.first?.days.first)
        XCTAssertEqual(newestDay.startingPercent, 0)
        XCTAssertEqual(newestDay.endingPercent, 3)
        XCTAssertEqual(newestDay.usedPercent, 3)
        XCTAssertEqual(newestDay.coverage, .observed)
    }

    @MainActor
    func testExplicitlyShorterWindowUsesReportedDuration() throws {
        let store = UsageHistoryStore.inMemory(calendar: utcCalendar)
        let reset = date("2026-09-04T20:40:00Z")
        let duration = 3 * 24 * 60
        store.record(snapshot(
            percent: 0,
            at: date("2026-09-01T20:40:00Z"),
            reset: reset,
            durationMinutes: duration
        ))
        store.record(snapshot(
            percent: 24,
            at: date("2026-09-04T20:35:00Z"),
            reset: reset,
            durationMinutes: duration
        ))

        let window = try XCTUnwrap(store.windows(for: "codex.primary").first)
        XCTAssertEqual(window.durationMinutes, duration)
        XCTAssertEqual(window.startsAt, date("2026-09-01T20:40:00Z"))
        XCTAssertEqual(window.days.count, 4)
        XCTAssertEqual(window.days.first?.startingPercent, 0)
        XCTAssertEqual(window.days.last?.endingPercent, 24)
    }

    @MainActor
    func testEarlyRolloverCreatesNewCycleBeforeAdvertisedReset() throws {
        let store = UsageHistoryStore.inMemory(calendar: utcCalendar)
        let originalReset = date("2026-09-07T20:40:00Z")
        let replacementReset = date("2026-09-10T20:40:00Z")
        store.record(snapshot(
            percent: 61,
            at: date("2026-09-03T20:35:00Z"),
            reset: originalReset
        ))
        store.record(snapshot(
            percent: 0,
            at: date("2026-09-03T20:45:00Z"),
            reset: replacementReset
        ))

        let windows = store.windows(for: "codex.primary")
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].resetsAt, replacementReset)
        XCTAssertEqual(windows[0].days.first?.startingPercent, 0)
        XCTAssertEqual(windows[1].resetsAt, originalReset)
        XCTAssertEqual(windows[1].days.last?.endingPercent, 61)
    }

    @MainActor
    func testSlidingZeroResetRemainsOneCycle() throws {
        let store = UsageHistoryStore.inMemory(calendar: utcCalendar)
        let oldReset = date("2026-09-14T00:40:00Z")
        let firstZeroAt = date("2026-09-08T01:21:58Z")
        let firstProvisionalReset = date("2026-09-15T01:22:00Z")
        let latestProvisionalReset = date("2026-09-15T01:44:28Z")

        store.record(snapshot(percent: 7, at: date("2026-09-08T01:20:00Z"), reset: oldReset))
        store.record(snapshot(percent: 0, at: firstZeroAt, reset: firstProvisionalReset))
        store.record(snapshot(
            percent: 0,
            at: date("2026-09-08T01:25:01Z"),
            reset: date("2026-09-15T01:25:03Z")
        ))
        store.record(snapshot(
            percent: 0,
            at: date("2026-09-08T01:44:27Z"),
            reset: latestProvisionalReset
        ))

        let windows = store.windows(for: "codex.primary")
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].startsAt, firstProvisionalReset.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(windows[0].resetsAt, latestProvisionalReset)
        XCTAssertEqual(windows[0].days.first?.endingPercent, 0)
        XCTAssertEqual(windows[1].days.last?.endingPercent, 7)
    }

    @MainActor
    func testLegacySlidingZeroWindowsAreCoalescedOnLoad() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DexBarHistory-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("usage-history.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldReset = date("2026-09-14T00:40:00Z")
        let zeroTimes = [
            date("2026-09-08T01:21:58Z"),
            date("2026-09-08T01:25:01Z"),
            date("2026-09-08T01:30:04Z"),
        ]
        let zeroResets = [
            date("2026-09-15T01:22:00Z"),
            date("2026-09-15T01:25:03Z"),
            date("2026-09-15T01:30:05Z"),
        ]
        func encodedDate(_ date: Date) -> Double { date.timeIntervalSinceReferenceDate }
        func day(
            reset: Date,
            observed: Date,
            starting: Double,
            ending: Double
        ) -> [String: Any] {
            [
                "windowID": "codex.primary",
                "windowResetsAt": encodedDate(reset),
                "windowDurationMinutes": 10_080,
                "dayStart": encodedDate(date("2026-09-08T00:00:00Z")),
                "timeZoneIdentifier": "GMT",
                "startingPercent": starting,
                "endingPercent": ending,
                "firstObservedAt": encodedDate(observed),
                "lastObservedAt": encodedDate(observed),
                "coverage": "observed",
            ]
        }
        var days = [day(
            reset: oldReset,
            observed: date("2026-09-08T01:20:00Z"),
            starting: 0,
            ending: 7
        )]
        for index in zeroTimes.indices {
            days.append(day(
                reset: zeroResets[index],
                observed: zeroTimes[index],
                starting: 0,
                ending: 0
            ))
        }
        let document: [String: Any] = [
            "schemaVersion": 1,
            "days": days,
            "latestObservations": [[
                "windowID": "codex.primary",
                "timestamp": encodedDate(zeroTimes.last!),
                "usedPercent": 0,
                "resetsAt": encodedDate(zeroResets.last!),
                "durationMinutes": 10_080,
                "timeZoneIdentifier": "GMT",
            ]],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: url)

        var store: UsageHistoryStore? = UsageHistoryStore(url: url, calendar: utcCalendar)
        let windows = try XCTUnwrap(store?.windows(for: "codex.primary"))
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].resetsAt, zeroResets.last)
        XCTAssertEqual(windows[0].days.count, 1)
        XCTAssertEqual(windows[1].days.last?.endingPercent, 7)

        store = UsageHistoryStore(url: url, calendar: utcCalendar)
        XCTAssertEqual(store?.windows(for: "codex.primary"), windows)
    }

    @MainActor
    func testZeroUsageDurationChangesSurviveMigrationAndRepeatedReloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DexBarDurationChanges-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstAt = date("2026-09-01T12:00:00Z")
        let replacementAt = date("2026-09-02T12:00:00Z")

        for (oldDays, newDays) in [(7, 3), (3, 7)] {
            for format in ["current", "legacy", "mixed"] {
                let context = "\(oldDays) to \(newDays) days, \(format)"
                let url = directory.appendingPathComponent(UUID().uuidString + ".json")
                var store = UsageHistoryStore(url: url, calendar: utcCalendar)
                store.record(snapshot(
                    percent: 0, at: firstAt,
                    reset: firstAt.addingTimeInterval(Double(oldDays) * 86_400),
                    durationMinutes: oldDays * 1_440
                ))
                let replacementReset = replacementAt.addingTimeInterval(Double(newDays) * 86_400)
                store.record(snapshot(
                    percent: 0, at: replacementAt, reset: replacementReset,
                    durationMinutes: newDays * 1_440
                ))
                let expected = store.windows(for: "codex.primary")
                XCTAssertEqual(expected.count, 2, context)

                if format != "current" {
                    let encodedDays = try JSONEncoder().encode(expected.flatMap(\.days))
                    var days = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedDays) as? [[String: Any]])
                    var document: [String: Any] = [
                        "schemaVersion": 1,
                        "latestObservations": [[
                            "windowID": "codex.primary", "timestamp": replacementAt.timeIntervalSinceReferenceDate,
                            "usedPercent": 0, "resetsAt": replacementReset.timeIntervalSinceReferenceDate,
                            "durationMinutes": newDays * 1_440, "timeZoneIdentifier": "GMT",
                            "cycleStartedAt": replacementAt.timeIntervalSinceReferenceDate,
                        ]],
                    ]
                    for index in days.indices where format == "legacy" || index == 0 {
                        days[index].removeValue(forKey: "windowStartedAt")
                    }
                    document["days"] = days
                    if format == "legacy" {
                        var observations = try XCTUnwrap(document["latestObservations"] as? [[String: Any]])
                        for index in observations.indices {
                            observations[index].removeValue(forKey: "cycleStartedAt")
                        }
                        document["latestObservations"] = observations
                    }
                    try JSONSerialization.data(withJSONObject: document).write(to: url)
                }

                for _ in 0..<2 {
                    store = UsageHistoryStore(url: url, calendar: utcCalendar)
                    XCTAssertEqual(store.windows(for: "codex.primary"), expected, context)
                }
                store.record(snapshot(
                    percent: 5, at: replacementAt.addingTimeInterval(5 * 60),
                    reset: replacementReset, durationMinutes: newDays * 1_440
                ))
                let updated = store.windows(for: "codex.primary")
                XCTAssertEqual(updated.count, 2, context)
                XCTAssertEqual(updated.last, expected.last, context)
                XCTAssertEqual(updated.first?.id, expected.first?.id, context)
                XCTAssertEqual(updated.first?.lastObservedDay?.usedPercent, 5, context)
                store = UsageHistoryStore(url: url, calendar: utcCalendar)
                XCTAssertEqual(store.windows(for: "codex.primary"), updated, context)
            }
        }
    }

    @MainActor
    func testHistoryPersistsInVersionedJSONAndClears() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DexBarHistory-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("usage-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reset = date("2026-09-07T20:40:00Z")

        var store: UsageHistoryStore? = UsageHistoryStore(url: url, calendar: utcCalendar)
        store?.record(snapshot(percent: 20, at: date("2026-09-01T12:00:00Z"), reset: reset))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)

        store = UsageHistoryStore(url: url, calendar: utcCalendar)
        XCTAssertEqual(store?.windows(for: "codex.primary").first?.days.count, 1)
        store?.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store?.windows(for: "codex.primary").isEmpty == true)
    }

    @MainActor
    func testProjectionSamplesSeedAFirstHistoryDocument() throws {
        let store = UsageHistoryStore.inMemory(calendar: utcCalendar)
        let reset = date("2026-09-07T20:40:00Z")
        let window = weeklyWindow(percent: 15, reset: reset)
        let samples = [
            ProjectionSample(
                windowID: window.id,
                timestamp: date("2026-09-01T09:00:00Z"),
                usedPercent: 10,
                resetsAt: reset
            ),
            ProjectionSample(
                windowID: window.id,
                timestamp: date("2026-09-01T12:00:00Z"),
                usedPercent: 15,
                resetsAt: reset
            ),
        ]

        store.backfill(samples: samples, for: window)

        let day = try XCTUnwrap(store.windows(for: window.id).first?.days.first)
        XCTAssertEqual(day.usedPercent, 5)
        XCTAssertEqual(day.coverage, .partial)
    }

    @MainActor
    func testQuietPollIsPersistedForFutureTimeZoneBaselines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DexBarHistory-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("usage-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reset = date("2026-09-07T20:40:00Z")
        let first = date("2026-09-01T09:00:00Z")

        var store: UsageHistoryStore? = UsageHistoryStore(url: url, calendar: utcCalendar)
        store?.record(snapshot(percent: 10, at: first, reset: reset))
        let firstData = try Data(contentsOf: url)
        store?.record(snapshot(percent: 10, at: date("2026-09-01T09:05:00Z"), reset: reset))
        XCTAssertNotEqual(try Data(contentsOf: url), firstData)

        store = UsageHistoryStore(url: url, calendar: utcCalendar)
        XCTAssertEqual(store?.windows(for: "codex.primary").first?.days.first?.lastObservedAt, date("2026-09-01T09:05:00Z"))
    }

    @MainActor
    func testRetentionRemovesOldDailyRecords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DexBarHistory-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("usage-history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageHistoryStore(
            url: url,
            calendar: utcCalendar,
            retention: 2 * 86_400
        )
        store.record(snapshot(
            percent: 20,
            at: date("2026-09-01T12:00:00Z"),
            reset: date("2026-09-02T20:40:00Z")
        ))
        store.record(snapshot(
            percent: 5,
            at: date("2026-09-05T12:00:00Z"),
            reset: date("2026-09-09T20:40:00Z")
        ))

        let windows = store.windows(for: "codex.primary")
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.resetsAt, date("2026-09-09T20:40:00Z"))
    }

    @MainActor
    func testCorruptHistoryRecoversOnNextObservation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DexBarHistory-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("usage-history.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = UsageHistoryStore(url: url, calendar: utcCalendar)
        XCTAssertTrue(store.windows(for: "codex.primary").isEmpty)
        store.record(snapshot(
            percent: 20,
            at: date("2026-09-01T12:00:00Z"),
            reset: date("2026-09-07T20:40:00Z")
        ))

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(store.windows(for: "codex.primary").count, 1)
    }

    @MainActor
    func testDelayedPollPreservesReportedStartWithoutAttributingAllUsageToToday() throws {
        let store = UsageHistoryStore.inMemory(calendar: utcCalendar)
        store.record(snapshot(percent: 60, at: date("2026-09-07T20:30:00Z"), reset: date("2026-09-07T20:40:00Z")))
        let reset = date("2026-09-14T20:40:00Z")
        store.record(snapshot(percent: 30, at: date("2026-09-09T12:00:00Z"), reset: reset))
        store.record(snapshot(percent: 35, at: date("2026-09-09T14:00:00Z"), reset: reset))

        let window = try XCTUnwrap(store.windows(for: "codex.primary").first)
        XCTAssertEqual(window.startsAt, date("2026-09-07T20:40:00Z"))
        XCTAssertEqual(window.days.first?.startingPercent, 30)
        XCTAssertEqual(window.days.first?.usedPercent, 5)
        XCTAssertEqual(window.days.first?.coverage, .partial)
        XCTAssertEqual(window.calendarDays(endingAt: reset, calendar: utcCalendar).first, date("2026-09-07T00:00:00Z"))
    }

    @MainActor
    func testUncertainEarlyResetAfterOvernightGapDoesNotClaimObservedDailyTotal() throws {
        let store = UsageHistoryStore.inMemory(calendar: utcCalendar)
        let reset = date("2026-09-07T20:40:00Z")
        store.record(snapshot(percent: 60, at: date("2026-09-02T20:00:00Z"), reset: reset))
        store.record(snapshot(percent: 15, at: date("2026-09-04T12:00:00Z"), reset: reset))
        let windows = store.windows(for: "codex.primary")
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].days.first?.coverage, .partial)
        XCTAssertEqual(windows[0].days.first?.startingPercent, 15)
        XCTAssertEqual(windows[0].days.first?.usedPercent, 0)
    }

    @MainActor
    func testTimeZoneChangeRecalculatesFromTheSameReadingsAcrossReloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DexBarTravel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let reset = date("2026-09-07T20:40:00Z")
        var store = UsageHistoryStore(url: url, calendar: utcCalendar)
        store.record(snapshot(percent: 10, at: date("2026-09-01T09:00:00Z"), reset: reset))
        let originalID = try XCTUnwrap(store.windows(for: "codex.primary").first?.id)
        var sydney = utcCalendar
        sydney.timeZone = TimeZone(identifier: "Australia/Sydney")!
        store = UsageHistoryStore(url: url, calendar: sydney)
        store.record(snapshot(percent: 15, at: date("2026-09-01T10:00:00Z"), reset: reset))
        store.record(snapshot(percent: 17, at: date("2026-09-01T11:00:00Z"), reset: reset))
        store = UsageHistoryStore(url: url, calendar: sydney)

        let windows = store.windows(for: "codex.primary")
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].id, originalID)
        let local = try XCTUnwrap(windows[0].record(on: sydney.startOfDay(for: date("2026-09-01T11:00:00Z")), timeZone: sydney.timeZone))
        XCTAssertEqual(local.coverage, .observed)
        XCTAssertEqual(local.startingPercent, 0)
        XCTAssertEqual(local.usedPercent, 17)
        // UTC's midnight is later in absolute time, but its observation is older.
        XCTAssertEqual(windows[0].lastObservedDay?.endingPercent, 17)
        XCTAssertEqual(windows[0].completedDescription(resetEarly: false), "Week ended · last seen 17%")
    }

    @MainActor
    func testExtendedZeroCycleIncludesTodayAndResetBeyondFirstEightDays() throws {
        let store = UsageHistoryStore.inMemory(calendar: utcCalendar)
        let first = date("2026-09-01T12:00:00Z")
        for offset in 0..<10 {
            let at = first.addingTimeInterval(Double(offset) * 86_400)
            store.record(snapshot(percent: 0, at: at, reset: at.addingTimeInterval(7 * 86_400)))
        }
        let windows = store.windows(for: "codex.primary")
        XCTAssertEqual(windows.count, 1)
        let window = try XCTUnwrap(windows.first)
        let days = window.calendarDays(endingAt: window.resetsAt, calendar: utcCalendar)
        XCTAssertEqual(days.count, 17)
        XCTAssertTrue(days.contains(date("2026-09-10T00:00:00Z")))
        XCTAssertEqual(days.last, date("2026-09-17T00:00:00Z"))
        XCTAssertEqual(window.days.count, 10)
        let currentPage = window.calendarDayPage(endingAt: window.resetsAt, calendar: utcCalendar)
        XCTAssertEqual(currentPage.count, 8)
        XCTAssertEqual(currentPage.first, date("2026-09-10T00:00:00Z"))
        XCTAssertEqual(currentPage.last, days.last)
        let previousPage = window.calendarDayPage(endingAt: window.resetsAt, calendar: utcCalendar, offsetFromEnd: 8)
        let firstPage = window.calendarDayPage(endingAt: window.resetsAt, calendar: utcCalendar, offsetFromEnd: 16)
        XCTAssertEqual(firstPage.first, days.first)
        XCTAssertEqual(Set(currentPage + previousPage + firstPage), Set(days))
    }

    func testCalendarDaysRespectMidnightResetAndDaylightSaving() {
        var sydney = utcCalendar
        sydney.timeZone = TimeZone(identifier: "Australia/Sydney")!
        let start = date("2026-10-02T14:00:00Z") // Oct 3 midnight, before DST
        let end = date("2026-10-09T13:00:00Z") // Oct 10 midnight, after DST
        let window = UsageHistoryWindow(windowID: "codex.primary", resetsAt: end, durationMinutes: 10_080, days: [], startsAt: start)
        let days = window.calendarDays(endingAt: end, calendar: sydney)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.map { sydney.component(.hour, from: $0) }, Array(repeating: 0, count: 7))
        XCTAssertEqual(days.last, date("2026-10-08T13:00:00Z"))
    }

    @MainActor
    func testCompletedWeekReportsLastObservationInsteadOfAnUnseenFinalTotal() throws {
        let store = UsageHistoryStore.inMemory(calendar: utcCalendar)
        store.record(snapshot(percent: 20, at: date("2026-09-01T12:00:00Z"), reset: date("2026-09-07T20:40:00Z")))
        let window = try XCTUnwrap(store.windows(for: "codex.primary").first)
        XCTAssertEqual(window.completedDescription(resetEarly: false), "Week ended · last seen 20%")
        XCTAssertEqual(window.completedDescription(resetEarly: true), "Week reset early · last seen 20%")
        let empty = UsageHistoryWindow(windowID: window.windowID, resetsAt: window.resetsAt, durationMinutes: window.durationMinutes, days: [])
        XCTAssertEqual(empty.completedDescription(resetEarly: false), "Week ended · total unavailable")
    }

    @MainActor
    func testResetIdentityAcrossUsageLevelsTimeZonesAndReloads() throws {
        let oldReset = date("2026-09-07T20:40:00Z")
        let lastReading = date("2026-09-01T09:00:00Z")
        let nextReading = date("2026-09-03T10:00:00Z")
        let earlyReset = date("2026-09-10T09:00:00Z")
        let cases: [(name: String, before: Double, after: Double, at: Date, reset: Date, cycles: Int)] = [
            ("stable", 10, 15, nextReading, oldReset, 1),
            ("jitter", 10, 15, nextReading, oldReset.addingTimeInterval(30), 1),
            ("schedule revision", 10, 15, nextReading, oldReset.addingTimeInterval(3_600), 1),
            ("early lower", 10, 5, nextReading, earlyReset, 2),
            ("early equal", 10, 10, nextReading, earlyReset, 2),
            ("early higher", 10, 15, nextReading, earlyReset, 2),
            ("sliding zero", 0, 0, nextReading, nextReading.addingTimeInterval(7 * 86_400), 1),
            ("zero anchors", 0, 5, nextReading, earlyReset, 1),
            ("ordinary higher", 10, 15, oldReset.addingTimeInterval(3_600), oldReset.addingTimeInterval(7 * 86_400), 2),
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DexBarResetMatrix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for scenario in cases {
            for zone in ["GMT", "Australia/Sydney", "Pacific/Honolulu"] {
                for restart in [false, true] {
                    let context = "\(scenario.name), \(zone), restart=\(restart)"
                    let url = directory.appendingPathComponent(UUID().uuidString + ".json")
                    var local = utcCalendar
                    local.timeZone = TimeZone(identifier: zone)!
                    var store = UsageHistoryStore(url: url, calendar: restart ? utcCalendar : local)
                    store.record(snapshot(percent: scenario.before, at: lastReading, reset: oldReset))
                    let originalID = try XCTUnwrap(store.windows(for: "codex.primary").first?.id)
                    if restart { store = UsageHistoryStore(url: url, calendar: local) }
                    store.record(snapshot(percent: scenario.after, at: scenario.at, reset: scenario.reset))
                    let windows = store.windows(for: "codex.primary")
                    XCTAssertEqual(windows.count, scenario.cycles, context)
                    if scenario.cycles == 2 {
                        XCTAssertEqual(windows.last?.id, originalID, context)
                        XCTAssertEqual(windows.last?.resetsAt, oldReset, context)
                        XCTAssertEqual(windows.last?.lastObservedDay?.endingPercent, scenario.before, context)
                        XCTAssertEqual(windows.first?.startsAt, scenario.reset.addingTimeInterval(-7 * 86_400), context)
                    } else {
                        XCTAssertEqual(windows.first?.id, originalID, context)
                    }
                    XCTAssertEqual(windows.first?.lastObservedDay?.endingPercent, scenario.after, context)
                    store = UsageHistoryStore(url: url, calendar: local)
                    XCTAssertEqual(store.windows(for: "codex.primary"), windows, context)
                }
            }
        }
    }

    @MainActor
    func testAllReadingsAreRebinnedAfterTravelReturnAndReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DexBarTravelViews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let reset = date("2026-09-07T20:40:00Z")
        let readings: [(String, String, Double)] = [
            ("GMT", "2026-09-01T09:00:00Z", 10),
            ("GMT", "2026-09-02T09:00:00Z", 20),
            ("Australia/Sydney", "2026-09-03T09:00:00Z", 25),
            ("Pacific/Honolulu", "2026-09-03T10:00:00Z", 30),
            ("GMT", "2026-09-04T09:00:00Z", 35),
        ]
        for (identifier, timestamp, percent) in readings {
            var local = utcCalendar
            local.timeZone = TimeZone(identifier: identifier)!
            let store = UsageHistoryStore(url: url, calendar: local)
            store.record(snapshot(percent: percent, at: date(timestamp), reset: reset))
        }
        let data = try Data(contentsOf: url)
        for identifier in ["GMT", "Australia/Sydney", "Pacific/Honolulu", "Pacific/Kiritimati", "GMT"] {
            var local = utcCalendar
            local.timeZone = TimeZone(identifier: identifier)!
            let actual = UsageHistoryStore(url: url, calendar: local).windows(for: "codex.primary")
            let reference = UsageHistoryStore.inMemory(calendar: local)
            for (_, timestamp, percent) in readings {
                reference.record(snapshot(percent: percent, at: date(timestamp), reset: reset))
            }
            XCTAssertEqual(actual, reference.windows(for: "codex.primary"), identifier)
            XCTAssertEqual(actual.first?.lastObservedDay?.endingPercent, 35)
            XCTAssertTrue(actual.flatMap(\.days).allSatisfy { $0.timeZoneIdentifier == identifier })
            XCTAssertEqual(try Data(contentsOf: url), data, "Viewing another zone must not rewrite history")
        }
    }

    @MainActor
    func testEarlyResetAndTravelPreserveBothWindowsAndTheirRecordedDays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DexBarTravelReset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let oldReset = date("2026-09-07T20:40:00Z")
        var store = UsageHistoryStore(url: url, calendar: utcCalendar)
        store.record(snapshot(percent: 10, at: date("2026-09-01T09:00:00Z"), reset: oldReset))
        var sydney = utcCalendar
        sydney.timeZone = TimeZone(identifier: "Australia/Sydney")!
        store = UsageHistoryStore(url: url, calendar: sydney)
        store.record(snapshot(percent: 20, at: date("2026-09-02T09:00:00Z"), reset: oldReset))
        store.record(snapshot(percent: 25, at: date("2026-09-03T10:00:00Z"), reset: date("2026-09-10T09:00:00Z")))
        store = UsageHistoryStore(url: url, calendar: sydney)
        let windows = store.windows(for: "codex.primary")
        XCTAssertEqual(windows.count, 2)
        let old = windows[1]
        let earlyEnd = windows[0].startsAt
        XCTAssertLessThan(earlyEnd, old.resetsAt)
        let visible = old.historyTimeZones().flatMap { zone -> [DailyUsageRecord] in
            var calendar = utcCalendar
            calendar.timeZone = zone
            return old.calendarDays(endingAt: earlyEnd, calendar: calendar)
                .compactMap { old.record(on: $0, timeZone: zone) }
        }
        XCTAssertEqual(Set(visible.map(\.id)), Set(old.days.map(\.id)))
        XCTAssertEqual(old.completedDescription(resetEarly: true), "Week reset early · last seen 20%")
    }

    private func snapshot(
        percent: Double,
        at timestamp: Date,
        reset: Date,
        durationMinutes: Int = 10_080
    ) -> UsageSnapshot {
        UsageSnapshot(
            weekly: weeklyWindow(percent: percent, reset: reset, durationMinutes: durationMinutes),
            supplementary: [],
            planType: "pro",
            credits: nil,
            resetCreditsAvailable: 0,
            fetchedAt: timestamp
        )
    }

    private func weeklyWindow(
        percent: Double,
        reset: Date,
        durationMinutes: Int = 10_080
    ) -> UsageWindow {
        UsageWindow(
            id: "codex.primary",
            bucketID: "codex",
            bucketName: "General",
            usedPercent: percent,
            durationMinutes: durationMinutes,
            resetsAt: reset
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

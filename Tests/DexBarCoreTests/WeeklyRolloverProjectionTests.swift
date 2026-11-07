import XCTest
@testable import DexBarCore

final class WeeklyRolloverProjectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(_ day: Double, _ percent: Double, reset: Double = 7,
                          windowID: String = "codex.primary", duration: Int = 10_080,
                          account: String? = "test-account", plan: String = "pro") -> UsageSnapshot {
        UsageSnapshot(
            weekly: UsageWindow(id: windowID, bucketID: "codex", bucketName: "General",
                                usedPercent: percent, durationMinutes: duration,
                                resetsAt: start.addingTimeInterval(reset * 86_400)),
            supplementary: [], planType: plan, credits: nil, resetCreditsAvailable: 0,
            fetchedAt: start.addingTimeInterval(day * 86_400), accountID: account
        )
    }

    private func seedPreviousWeek(_ store: UsageHistoryStore) {
        [snapshot(0, 10), snapshot(1, 20), snapshot(5, 60), snapshot(6.99, 79.9)].forEach(store.record)
    }

    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeeklyRolloverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("usage-readings.json")
    }

    func testNewWeekImmediatelyBorrowsQualifiedHistoryAtZeroUsage() throws {
        let store = UsageHistoryStore.inMemory()
        seedPreviousWeek(store)
        let current = snapshot(7, 0, reset: 14)
        store.record(current)

        let projection = try XCTUnwrap(store.weeklyProjection(for: current))
        XCTAssertTrue(projection.isPreliminary)
        XCTAssertNotNil(projection.historicalPointsPerDay)
        XCTAssertEqual(projection.pointsPerDay, 10, accuracy: 0.001)
        XCTAssertEqual(projection.projectedPercent, 70)
        XCTAssertEqual(store.windows(for: current.weekly.id).count, 2)
    }

    func testEarlyResetLowerEqualOrHigherFirstReadingDoesNotCountResetAsSpending() throws {
        for firstPercent in [5.0, 40, 50] {
            let store = UsageHistoryStore.inMemory()
            [snapshot(0, 10), snapshot(1, 20), snapshot(3, 40)].forEach(store.record)
            let current = snapshot(4, firstPercent, reset: 11)
            store.record(current)

            let projection = try XCTUnwrap(store.weeklyProjection(for: current))
            XCTAssertTrue(projection.isPreliminary)
            XCTAssertEqual(projection.pointsPerDay, 10, accuracy: 0.001)
            XCTAssertEqual(projection.projectedPercent, Int(firstPercent) + 70)
            XCTAssertEqual(store.windows(for: current.weekly.id).count, 2)
        }
    }

    func testOvernightPauseBeforeFirstUseDilutesHistoricalPace() throws {
        func projection(startDay: Double) throws -> Projection {
            let store = UsageHistoryStore.inMemory()
            seedPreviousWeek(store)
            let current = snapshot(startDay, 0, reset: startDay + 7)
            store.record(current)
            return try XCTUnwrap(store.weeklyProjection(for: current))
        }

        let immediate = try projection(startDay: 7)
        let nextMorning = try projection(startDay: 7.5)
        XCTAssertLessThan(nextMorning.pointsPerDay, immediate.pointsPerDay)
        XCTAssertGreaterThan(nextMorning.pointsPerDay, 0)
        XCTAssertLessThan(nextMorning.projectedPercent, immediate.projectedPercent)
    }

    func testUnknownMultiDayGapIsNotClaimedAsObservedIdle() throws {
        func projection(startDay: Double) throws -> Projection {
            let store = UsageHistoryStore.inMemory()
            seedPreviousWeek(store)
            let current = snapshot(startDay, 0, reset: startDay + 7)
            store.record(current)
            return try XCTUnwrap(store.weeklyProjection(for: current))
        }

        XCTAssertEqual(try projection(startDay: 10).pointsPerDay,
                       try projection(startDay: 7).pointsPerDay, accuracy: 0.001)
    }

    func testDistantLastObservationDoesNotEstablishAnOvernightIdleInterval() throws {
        func projection(startDay: Double) throws -> Projection {
            let store = UsageHistoryStore.inMemory()
            [snapshot(0, 10), snapshot(1, 20), snapshot(6, 70)].forEach(store.record)
            let current = snapshot(startDay, 0, reset: startDay + 7)
            store.record(current)
            return try XCTUnwrap(store.weeklyProjection(for: current))
        }

        XCTAssertEqual(try projection(startDay: 7.5).pointsPerDay,
                       try projection(startDay: 7).pointsPerDay, accuracy: 0.001)
    }

    func testActualZeroBaselineSurvivesProvisionalResetMovement() throws {
        let store = UsageHistoryStore.inMemory()
        seedPreviousWeek(store)
        [snapshot(7, 0, reset: 14), snapshot(7.25, 0, reset: 14.25),
         snapshot(7.5, 5, reset: 14.5)].forEach(store.record)
        let current = snapshot(8, 10, reset: 14.5)
        store.record(current)

        let projection = try XCTUnwrap(store.weeklyProjection(for: current))
        XCTAssertFalse(projection.isPreliminary)
        XCTAssertNil(projection.historicalPointsPerDay)
        XCTAssertEqual(projection.longTermPointsPerDay, 10, accuracy: 0.001)
        XCTAssertEqual(store.windows(for: current.weekly.id).count, 2)
    }

    func testHistoricalWeightHandsOffSmoothlyToMatureCurrentPace() throws {
        let store = UsageHistoryStore.inMemory()
        seedPreviousWeek(store)
        store.record(snapshot(7, 0, reset: 14))
        let shortlyBefore = snapshot(7.999, 19.98, reset: 14)
        store.record(shortlyBefore)
        let preliminary = try XCTUnwrap(store.weeklyProjection(for: shortlyBefore))
        XCTAssertTrue(preliminary.isPreliminary)
        XCTAssertNotNil(preliminary.historicalPointsPerDay)
        XCTAssertGreaterThan(preliminary.pointsPerDay, 19)

        let current = snapshot(8, 20, reset: 14)
        store.record(current)
        let mature = try XCTUnwrap(store.weeklyProjection(for: current))
        XCTAssertFalse(mature.isPreliminary)
        XCTAssertNil(mature.historicalPointsPerDay)
        XCTAssertEqual(mature.pointsPerDay, 20, accuracy: 0.001)
        XCTAssertEqual(mature.pointsPerDay, preliminary.pointsPerDay, accuracy: 0.1)
    }

    func testNonzeroFirstReadingDoesNotInventAZeroBaseline() throws {
        let store = UsageHistoryStore.inMemory()
        seedPreviousWeek(store)
        store.record(snapshot(7.25, 30, reset: 14))
        let current = snapshot(8.25, 40, reset: 14)
        store.record(current)

        let projection = try XCTUnwrap(store.weeklyProjection(for: current))
        XCTAssertFalse(projection.isPreliminary)
        XCTAssertEqual(projection.longTermPointsPerDay, 10, accuracy: 0.001)
    }

    func testColdStartStillWaitsForMeasuredHistory() {
        let store = UsageHistoryStore.inMemory()
        let first = snapshot(1, 20)
        store.record(first)
        XCTAssertNil(store.weeklyProjection(for: first))
        let shortlyAfter = snapshot(1.5, 25)
        store.record(shortlyAfter)
        XCTAssertNil(store.weeklyProjection(for: shortlyAfter))
    }

    func testLessThanOneDayOfPriorHistoryCannotUnlockRolloverForecast() {
        let store = UsageHistoryStore.inMemory()
        [snapshot(6.5, 60), snapshot(6.99, 79.9)].forEach(store.record)
        let current = snapshot(7, 0, reset: 14)
        store.record(current)
        XCTAssertNil(store.weeklyProjection(for: current))
    }

    func testStaleHistoryAndOtherWindowOrDurationDoNotSupplyPrior() {
        let stale = UsageHistoryStore.inMemory()
        seedPreviousWeek(stale)
        let muchLater = snapshot(16, 0, reset: 23)
        stale.record(muchLater)
        XCTAssertNil(stale.weeklyProjection(for: muchLater))

        let differentWindow = UsageHistoryStore.inMemory()
        seedPreviousWeek(differentWindow)
        let other = snapshot(7, 0, reset: 14, windowID: "model.primary")
        differentWindow.record(other)
        XCTAssertNil(differentWindow.weeklyProjection(for: other))

        let differentDuration = UsageHistoryStore.inMemory()
        seedPreviousWeek(differentDuration)
        let longer = snapshot(7, 0, reset: 21, duration: 20_160)
        differentDuration.record(longer)
        XCTAssertNil(differentDuration.weeklyProjection(for: longer))
    }

    func testFlatCurrentDayProducesZeroPaceRatherThanRevivingPrior() throws {
        let store = UsageHistoryStore.inMemory()
        seedPreviousWeek(store)
        store.record(snapshot(7, 0, reset: 14))
        let current = snapshot(8, 0, reset: 14)
        store.record(current)

        let projection = try XCTUnwrap(store.weeklyProjection(for: current))
        XCTAssertFalse(projection.isPreliminary)
        XCTAssertNil(projection.historicalPointsPerDay)
        XCTAssertEqual(projection.pointsPerDay, 0)
        XCTAssertEqual(projection.projectedPercent, 0)
        XCTAssertNil(projection.limitReachedAt)
    }

    func testSmallDipAndRecoveryDoNotDoubleCountHistoricalConsumption() throws {
        let store = UsageHistoryStore.inMemory()
        [snapshot(0, 10), snapshot(1, 20), snapshot(2, 30), snapshot(2.1, 29),
         snapshot(2.2, 30), snapshot(3, 40)].forEach(store.record)
        let previous = try XCTUnwrap(store.weeklyProjection(for: snapshot(3, 40)))
        let current = snapshot(4, 0, reset: 11)
        store.record(current)

        let projection = try XCTUnwrap(store.weeklyProjection(for: current))
        XCTAssertEqual(projection.longTermPointsPerDay, 10, accuracy: 0.001)
        XCTAssertEqual(projection.pointsPerDay, previous.pointsPerDay, accuracy: 0.001)
        XCTAssertEqual(store.windows(for: current.weekly.id).count, 2)
    }

    func testAccountAndPlanChangesBlockBorrowingWithoutDeletingDailyHistory() {
        for (account, plan) in [("different-account", "pro"), ("test-account", "plus")] {
            let store = UsageHistoryStore.inMemory()
            seedPreviousWeek(store)
            let current = snapshot(7, 0, reset: 14, account: account, plan: plan)
            store.record(current)
            XCTAssertNil(store.weeklyProjection(for: current))
            XCTAssertEqual(store.windows(for: current.weekly.id).count, 2)
        }
    }

    func testMissingIdentityBreaksBorrowingEvenWhenOriginalIdentityReturns() {
        let store = UsageHistoryStore.inMemory()
        seedPreviousWeek(store)
        let unidentified = snapshot(7, 0, reset: 14, account: nil)
        store.record(unidentified)
        XCTAssertNil(store.weeklyProjection(for: unidentified))
        let identifiedAgain = snapshot(7.1, 1, reset: 14)
        store.record(identifiedAgain)
        XCTAssertNil(store.weeklyProjection(for: identifiedAgain))
        XCTAssertEqual(store.windows(for: identifiedAgain.weekly.id).count, 2)
    }

    func testDuplicateTimestampCannotExposeAnotherAccountOrPlansMatureProjection() throws {
        let url = try temporaryURL()
        let store = UsageHistoryStore(url: url)
        [snapshot(0, 10), snapshot(1, 20)].forEach(store.record)
        let current = snapshot(1, 20)
        let expected = try XCTUnwrap(store.weeklyProjection(for: current))
        let originalHistory = store.windows(for: current.weekly.id)
        let originalBytes = try Data(contentsOf: url)

        for (account, plan) in [("different-account", "pro"), ("test-account", "plus")] {
            let rejected = snapshot(1, 20, account: account, plan: plan)
            store.record(rejected)
            XCTAssertNil(store.weeklyProjection(for: rejected))
            XCTAssertEqual(store.windows(for: current.weekly.id), originalHistory)
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
            XCTAssertEqual(store.weeklyProjection(for: current), expected)
        }
    }

    func testBackwardPollCannotReplayEarlierForecastAndFreshForwardPollRecovers() throws {
        let url = try temporaryURL()
        let store = UsageHistoryStore(url: url)
        [snapshot(0, 10), snapshot(1, 20), snapshot(2, 30)].forEach(store.record)
        let current = snapshot(2, 30)
        let expected = try XCTUnwrap(store.weeklyProjection(for: current))
        let originalBytes = try Data(contentsOf: url)

        // The first rejected poll exactly matches a real earlier stored reading.
        for rejected in [snapshot(1, 20), snapshot(1.5, 25)] {
            store.record(rejected)
            XCTAssertNil(store.weeklyProjection(for: rejected))
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
            XCTAssertEqual(store.weeklyProjection(for: current), expected)
        }

        let fresh = snapshot(2.1, 31)
        store.record(fresh)
        let recovered = try XCTUnwrap(store.weeklyProjection(for: fresh))
        XCTAssertEqual(recovered.pointsPerDay, 10, accuracy: 0.001)
        XCTAssertFalse(recovered.isPreliminary)
    }

    func testRejectedWorkerGenerationCannotReturnOrResurrectWeeklyProjection() async throws {
        let store = UsageHistoryStore.inMemory()
        seedPreviousWeek(store)
        let worker = UsageHistoryWorker(store: store)
        let calendar = Calendar(identifier: .gregorian)
        let rollover = await worker.update(snapshot(7, 0, reset: 14),
            projectionSamples: [], calendar: calendar, generation: 0)
        XCTAssertNotNil(rollover.weeklyProjection)
        let error = await worker.clear(generation: 1)
        XCTAssertNil(error)

        let afterClear = await worker.update(snapshot(7.1, 1, reset: 14),
            projectionSamples: [], calendar: calendar, generation: 0)
        XCTAssertNil(afterClear.weeklyProjection)
        XCTAssertTrue(afterClear.windows.isEmpty)

        _ = await worker.update(snapshot(10, 10, reset: 17),
            projectionSamples: [], calendar: calendar, generation: 2)
        let freshSnapshot = snapshot(11, 20, reset: 17)
        let fresh = await worker.update(freshSnapshot,
            projectionSamples: [], calendar: calendar, generation: 2)
        XCTAssertNotNil(fresh.weeklyProjection)
        let stale = await worker.update(snapshot(8, 5, reset: 14),
            projectionSamples: [], calendar: calendar, generation: 0)
        XCTAssertNil(stale.weeklyProjection)

        let preserved = await worker.update(freshSnapshot,
            projectionSamples: [], calendar: calendar, generation: 2)
        XCTAssertEqual(preserved.weeklyProjection, fresh.weeklyProjection)
        XCTAssertEqual(preserved.windows, fresh.windows)
    }

    func testRolloverForecastSurvivesReloadAndTimezonePresentationAndClear() throws {
        let url = try temporaryURL()
        var store = UsageHistoryStore(url: url)
        seedPreviousWeek(store)
        let current = snapshot(7.25, 0, reset: 14.25)
        store.record(current)
        let expected = try XCTUnwrap(store.weeklyProjection(for: current))
        let originalBytes = try Data(contentsOf: url)

        store = UsageHistoryStore(url: url)
        XCTAssertEqual(store.weeklyProjection(for: current), expected)
        for zone in ["Australia/Sydney", "America/Los_Angeles", "UTC"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            _ = store.windows(for: current.weekly.id, calendar: calendar)
            XCTAssertEqual(store.weeklyProjection(for: current), expected)
        }
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)

        store.clear()
        XCTAssertNil(store.weeklyProjection(for: current))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store = UsageHistoryStore(url: url)
        XCTAssertNil(store.weeklyProjection(for: current))
    }

    func testLegacyUnscopedReadingsCanBeAdoptedWithoutChangingRecordedUsage() throws {
        let url = try temporaryURL()
        let readings = [snapshot(0, 10), snapshot(1, 20), snapshot(6.99, 79.9)].map { sample in
            ["windowID": sample.weekly.id,
             "timestamp": sample.fetchedAt.timeIntervalSince1970,
             "usedPercent": sample.weekly.usedPercent,
             "resetsAt": sample.weekly.resetsAt.timeIntervalSince1970,
             "durationMinutes": sample.weekly.durationMinutes,
             "cycleStartedAt": start.timeIntervalSince1970,
             "cycleStartKnown": true] as [String: Any]
        }
        let bytes = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2, "timestampEncoding": "unixSecondsUTC",
            "readings": readings, "legacyIntervals": []
        ])
        try bytes.write(to: url)
        let store = UsageHistoryStore(url: url)
        let current = snapshot(7, 0, reset: 14)
        store.record(current)

        XCTAssertNotNil(store.weeklyProjection(for: current))
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let persistedReadings = try XCTUnwrap(persisted["readings"] as? [[String: Any]])
        XCTAssertEqual(persistedReadings.count, 4)
        for (original, saved) in zip(readings, persistedReadings) {
            XCTAssertEqual(original as NSDictionary, saved as NSDictionary)
        }
    }
}

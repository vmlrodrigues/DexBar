import XCTest
@testable import DexBarCore

final class WeeklyProjectionUncertaintyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(_ day: Double, _ percent: Double, reset: Double = 7) -> UsageSnapshot {
        UsageSnapshot(
            weekly: UsageWindow(id: "codex.primary", bucketID: "codex", bucketName: "General",
                                usedPercent: percent, durationMinutes: 10_080,
                                resetsAt: start.addingTimeInterval(reset * 86_400)),
            supplementary: [], planType: "pro", credits: nil, resetCreditsAvailable: 0,
            fetchedAt: start.addingTimeInterval(day * 86_400), accountID: "test-account"
        )
    }

    private func seedPreviousWeek(_ store: UsageHistoryStore) {
        [snapshot(0, 10), snapshot(1, 20), snapshot(5, 60), snapshot(6.99, 80)].forEach(store.record)
    }

    func testBlendedBoundsIncludeWholePointRoundingAtTwoPointFourHours() throws {
        let store = UsageHistoryStore.inMemory()
        seedPreviousWeek(store)
        store.record(snapshot(7, 25, reset: 14))
        let current = snapshot(7.1, 26, reset: 14)
        store.record(current)

        let projection = try XCTUnwrap(store.weeklyProjection(for: current))
        // A true historical pace of 10/day rounds to the recorded history. True
        // current readings of 24.51 -> 26.49 round to 25 -> 26, yet project 102.252%.
        let possibleUpper = 26.49 + (10 * 0.9 + 1.98) * 6.9
        let possibleLower = 25.51 + (10 * 0.9 + 0.02) * 6.9
        XCTAssertGreaterThanOrEqual(projection.upperProjectedPercent, Int(ceil(possibleUpper)))
        XCTAssertLessThanOrEqual(projection.lowerProjectedPercent, Int(floor(possibleLower)))
        XCTAssertEqual(projection.outlook, .mayRunOut)
        // Accounting for rounding changes the evidence band, not the estimate.
        XCTAssertEqual(projection.projectedPercent, 95)
        XCTAssertEqual(projection.pointsPerDay, 10.012875536480687, accuracy: 0.000_001)
    }

    func testTwoMinuteMovementRetainsItsRoundingUncertainty() throws {
        let store = UsageHistoryStore.inMemory()
        seedPreviousWeek(store)
        store.record(snapshot(7, 17, reset: 14))
        let elapsedDays = 2.0 / (24 * 60)
        let current = snapshot(7 + elapsedDays, 18, reset: 14)
        store.record(current)

        let projection = try XCTUnwrap(store.weeklyProjection(for: current))
        // 16.51 -> 18.49 is compatible with these two whole-point observations.
        let possibleUpper = 18.49 + (10 * (1 - elapsedDays) + 1.98) * (7 - elapsedDays)
        XCTAssertGreaterThanOrEqual(projection.upperProjectedPercent, Int(ceil(possibleUpper)))
        XCTAssertEqual(projection.outlook, .mayRunOut)
        XCTAssertEqual(projection.projectedPercent, 95)
        XCTAssertTrue(projection.pointsPerDay.isFinite)
        XCTAssertLessThan(projection.upperProjectedPercent, 200)
    }

    func testFlatCurrentReadingsStillAllowUnreportedFractionalMovement() throws {
        let store = UsageHistoryStore.inMemory()
        seedPreviousWeek(store)
        store.record(snapshot(7, 31, reset: 14))
        let current = snapshot(7.1, 31, reset: 14)
        store.record(current)

        let projection = try XCTUnwrap(store.weeklyProjection(for: current))
        // 30.51 -> 31.49 both round to 31. A flat rounded reading does not prove
        // exact zero consumption during the current cycle's first 2.4 hours.
        let possibleUpper = 31.49 + (10 * 0.9 + 0.98) * 6.9
        XCTAssertGreaterThanOrEqual(projection.upperProjectedPercent, Int(ceil(possibleUpper)))
        XCTAssertEqual(projection.outlook, .mayRunOut)
        XCTAssertEqual(projection.projectedPercent, 93)
    }

    func testFirstRolloverReadingHasFiniteBoundedHistoricalUncertainty() throws {
        let store = UsageHistoryStore.inMemory()
        seedPreviousWeek(store)
        let current = snapshot(7, 0, reset: 14)
        store.record(current)

        let projection = try XCTUnwrap(store.weeklyProjection(for: current))
        XCTAssertTrue(projection.isPreliminary)
        XCTAssertTrue(projection.pointsPerDay.isFinite)
        XCTAssertEqual(projection.projectedPercent, 70)
        XCTAssertLessThanOrEqual(projection.lowerProjectedPercent, projection.projectedPercent)
        XCTAssertGreaterThanOrEqual(projection.upperProjectedPercent, projection.projectedPercent)
        XCTAssertLessThan(projection.upperProjectedPercent - projection.lowerProjectedPercent, 10)
    }

    func testRoundingBoundsHandOffSmoothlyAtOneDayOfCurrentEvidence() throws {
        let store = UsageHistoryStore.inMemory()
        seedPreviousWeek(store)
        store.record(snapshot(7, 0, reset: 14))
        let before = snapshot(7.999, 19.98, reset: 14)
        store.record(before)
        let preliminary = try XCTUnwrap(store.weeklyProjection(for: before))

        let after = snapshot(8, 20, reset: 14)
        store.record(after)
        let mature = try XCTUnwrap(store.weeklyProjection(for: after))

        XCTAssertTrue(preliminary.isPreliminary)
        XCTAssertFalse(mature.isPreliminary)
        XCTAssertNil(mature.historicalPointsPerDay)
        XCTAssertEqual(mature.pointsPerDay, 20, accuracy: 0.000_001)
        XCTAssertEqual(preliminary.pointsPerDay, mature.pointsPerDay, accuracy: 0.02)
        XCTAssertLessThanOrEqual(abs(preliminary.projectedPercent - mature.projectedPercent), 1)
        XCTAssertLessThanOrEqual(abs(preliminary.lowerProjectedPercent - mature.lowerProjectedPercent), 1)
        XCTAssertLessThanOrEqual(abs(preliminary.upperProjectedPercent - mature.upperProjectedPercent), 1)
    }

    func testMatureQuietAllowanceSuppliesZeroPriorInsteadOfOlderActivity() throws {
        try assertQuietAllowanceIsPreserved(firstPercent: 1, lastPercent: 1)
    }

    func testMatureQuietAllowanceWithSmallCorrectionDoesNotReviveOlderActivity() throws {
        try assertQuietAllowanceIsPreserved(firstPercent: 10, lastPercent: 9)
    }

    private func assertQuietAllowanceIsPreserved(firstPercent: Double, lastPercent: Double,
                                                file: StaticString = #filePath, line: UInt = #line) throws {
        let store = UsageHistoryStore.inMemory()
        [snapshot(0, 10), snapshot(1, 20), snapshot(3, 40),
         snapshot(4, firstPercent, reset: 11), snapshot(5, lastPercent, reset: 11)].forEach(store.record)
        let quiet = try XCTUnwrap(store.weeklyProjection(for: snapshot(5, lastPercent, reset: 11)),
                                 file: file, line: line)
        XCTAssertFalse(quiet.isPreliminary, file: file, line: line)
        XCTAssertEqual(quiet.pointsPerDay, 0, file: file, line: line)

        let current = snapshot(6, 0, reset: 13)
        store.record(current)
        let projection = try XCTUnwrap(store.weeklyProjection(for: current), file: file, line: line)
        XCTAssertEqual(store.windows(for: current.weekly.id).count, 3, file: file, line: line)
        XCTAssertTrue(projection.isPreliminary, file: file, line: line)
        XCTAssertEqual(projection.historicalPointsPerDay, 0, file: file, line: line)
        XCTAssertEqual(projection.pointsPerDay, 0, file: file, line: line)
        XCTAssertEqual(projection.projectedPercent, 0, file: file, line: line)
    }
}

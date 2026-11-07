import XCTest
@testable import DexBarCore

final class WeeklyProjectionNotificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_260_400)

    private func snapshot(percent: Double = 10) -> UsageSnapshot {
        UsageSnapshot(
            weekly: UsageWindow(
                id: "codex.primary", bucketID: "codex", bucketName: "General",
                usedPercent: percent, durationMinutes: 10_080,
                resetsAt: now.addingTimeInterval(6 * 86_400)
            ),
            supplementary: [], planType: "pro", credits: nil,
            resetCreditsAvailable: 0, fetchedAt: now, accountID: "test-account"
        )
    }

    private func projection(percent: Int, preliminary: Bool) -> Projection {
        Projection(
            projectedPercent: percent, pointsPerDay: 15, daysRemaining: 6,
            outlook: percent >= 100 ? .mayRunOut : .onTrack, limitReachedAt: nil,
            isPreliminary: preliminary,
            historicalPointsPerDay: preliminary ? 15 : nil
        )
    }

    func testPreliminaryWarningDoesNotConsumeMatureProjectionNotification() throws {
        var ledger = NotificationLedger()
        let usage = snapshot()
        let warning = projection(percent: 110, preliminary: true)
        XCTAssertTrue(ledger.evaluate(snapshot: usage, projection: warning).isEmpty)
        XCTAssertTrue(ledger.evaluate(snapshot: usage, projection: warning).isEmpty)

        // Relaunching during collection must preserve the unconsumed latch.
        let saved = try JSONEncoder().encode(ledger)
        var relaunched = try JSONDecoder().decode(NotificationLedger.self, from: saved)
        XCTAssertEqual(
            relaunched.evaluate(snapshot: usage, projection: projection(percent: 110, preliminary: false)).map(\.identifier),
            ["weekly/projection"]
        )
        XCTAssertTrue(relaunched.evaluate(snapshot: usage, projection: projection(percent: 110, preliminary: false)).isEmpty)
    }

    func testPreliminaryLowEstimateDoesNotRearmConsumedProjectionLatch() {
        var ledger = NotificationLedger()
        let usage = snapshot()
        let matureWarning = projection(percent: 110, preliminary: false)
        XCTAssertEqual(ledger.evaluate(snapshot: usage, projection: matureWarning).map(\.identifier), ["weekly/projection"])

        XCTAssertTrue(ledger.evaluate(snapshot: usage, projection: projection(percent: 90, preliminary: true)).isEmpty)
        XCTAssertTrue(ledger.evaluate(snapshot: usage, projection: matureWarning).isEmpty)

        // A mature estimate below the rearm threshold still permits a later alert.
        XCTAssertTrue(ledger.evaluate(snapshot: usage, projection: projection(percent: 90, preliminary: false)).isEmpty)
        XCTAssertEqual(ledger.evaluate(snapshot: usage, projection: matureWarning).map(\.identifier), ["weekly/projection"])
    }

    func testActualUsageThresholdsStillNotifyDuringPreliminaryForecast() {
        var ledger = NotificationLedger()
        let preliminaryWarning = projection(percent: 120, preliminary: true)
        XCTAssertEqual(
            ledger.evaluate(snapshot: snapshot(percent: 80), projection: preliminaryWarning).map(\.identifier),
            ["codex.primary/80"]
        )
        XCTAssertEqual(
            ledger.evaluate(snapshot: snapshot(percent: 95), projection: preliminaryWarning).map(\.identifier),
            ["codex.primary/95"]
        )
    }
}

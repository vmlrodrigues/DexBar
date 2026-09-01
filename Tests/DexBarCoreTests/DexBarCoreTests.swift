import XCTest
@testable import DexBarCore

final class DexBarCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_180_000)

    func testCurrentAccountShowsOnlyGeneralWeeklyWindow() throws {
        let snapshot = try mappedSnapshot(sparkShort: 0, sparkWeekly: 0)

        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.weekly.id, "codex.primary")
        XCTAssertEqual(snapshot.weekly.durationMinutes, 10_080)
        XCTAssertEqual(snapshot.weekly.roundedPercent, 1)
        XCTAssertTrue(snapshot.supplementary.isEmpty)
        XCTAssertEqual(snapshot.preferredMenuWindow.id, snapshot.weekly.id)
    }

    func testFiveHourWindowAppearsOnlyAfterItBecomesActive() throws {
        let inactive = try mappedSnapshot(sparkShort: 0, sparkWeekly: 0)
        XCTAssertTrue(inactive.supplementary.isEmpty)

        let active = try mappedSnapshot(generalWeekly: 44, sparkShort: 68, sparkWeekly: 12)
        XCTAssertEqual(active.supplementary.map(\.id), ["codex_bengalfox.primary"])
        XCTAssertEqual(active.supplementary.first?.title, "5-hour window")
        XCTAssertEqual(active.preferredMenuWindow.id, "codex_bengalfox.primary")
    }

    func testLowModelSpecificWeeklyWindowStaysHiddenButWarningAppears() throws {
        let quiet = try mappedSnapshot(generalWeekly: 44, sparkShort: 10, sparkWeekly: 12)
        XCTAssertEqual(quiet.supplementary.map(\.id), ["codex_bengalfox.primary"])

        let warning = try mappedSnapshot(generalWeekly: 44, sparkShort: 10, sparkWeekly: 83)
        XCTAssertEqual(
            Set(warning.supplementary.map(\.id)),
            Set(["codex_bengalfox.primary", "codex_bengalfox.secondary"])
        )
        XCTAssertEqual(warning.preferredMenuWindow.id, "codex_bengalfox.secondary")
    }

    func testReachedShortWindowAppearsEvenAtZeroPercent() throws {
        let data = payloadData(
            generalWeekly: 20,
            sparkShort: 0,
            sparkWeekly: 0,
            sparkReachedType: "primary"
        )
        let payload = try JSONDecoder().decode(AppServerRateLimitsPayload.self, from: data)
        let snapshot = try UsageMapper.snapshot(from: payload, now: now)
        XCTAssertEqual(snapshot.supplementary.map(\.id), ["codex_bengalfox.primary"])
    }

    func testLegacyTwoWindowBucketUsesLongestAsWeekly() throws {
        let json: [String: Any] = [
            "rateLimits": bucket(
                id: "codex",
                name: NSNull(),
                primaryPercent: 25,
                primaryMinutes: 300,
                secondaryPercent: 40,
                secondaryMinutes: 10_080,
                plan: "pro"
            ),
            "rateLimitResetCredits": ["availableCount": 0],
        ]
        let payload = try JSONDecoder().decode(
            AppServerRateLimitsPayload.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        let snapshot = try UsageMapper.snapshot(from: payload, now: now)
        XCTAssertEqual(snapshot.weekly.id, "codex.secondary")
        XCTAssertEqual(snapshot.supplementary.map(\.id), ["codex.primary"])
    }

    func testHealthThresholdsAreEightyAndNinetyFive() {
        XCTAssertEqual(UsageHealth.forPercent(79.99), .normal)
        XCTAssertEqual(UsageHealth.forPercent(80), .warning)
        XCTAssertEqual(UsageHealth.forPercent(94.99), .warning)
        XCTAssertEqual(UsageHealth.forPercent(95), .critical)
    }

    func testProjectionWaitsForHistoryAndProjectsFromMeasuredPace() {
        let reset = now.addingTimeInterval(3 * 86_400)
        let window = UsageWindow(
            id: "codex.primary",
            bucketID: "codex",
            bucketName: "General",
            usedPercent: 40,
            durationMinutes: 10_080,
            resetsAt: reset
        )
        let recent = ProjectionSample(
            windowID: window.id,
            timestamp: now.addingTimeInterval(-3_600),
            usedPercent: 35,
            resetsAt: reset
        )
        XCTAssertNil(ProjectionCalculator.calculate(window: window, samples: [recent], now: now))

        let baseline = ProjectionSample(
            windowID: window.id,
            timestamp: now.addingTimeInterval(-2 * 86_400),
            usedPercent: 10,
            resetsAt: reset
        )
        let projection = ProjectionCalculator.calculate(window: window, samples: [baseline], now: now)
        XCTAssertEqual(projection?.projectedPercent, 85)
        XCTAssertEqual(projection?.outlook, .onTrack)
        XCTAssertEqual(projection?.pointsPerDay ?? 0, 15, accuracy: 0.001)
        XCTAssertEqual(projection?.daysRemaining ?? 0, 3, accuracy: 0.001)
    }

    func testShortProjectionWaitsAnHourAndStaysQuietBelowSixtyPercent() {
        let reset = now.addingTimeInterval(2 * 3_600)
        let window = UsageWindow(
            id: "codex.short",
            bucketID: "codex",
            bucketName: "General",
            usedPercent: 40,
            durationMinutes: 300,
            resetsAt: reset
        )
        let tooRecent = ProjectionSample(
            windowID: window.id,
            timestamp: now.addingTimeInterval(-30 * 60),
            usedPercent: 10,
            resetsAt: reset
        )
        XCTAssertNil(ProjectionCalculator.calculate(
            window: window,
            samples: [tooRecent],
            now: now,
            kind: .short
        ))

        let baseline = ProjectionSample(
            windowID: window.id,
            timestamp: now.addingTimeInterval(-2 * 3_600),
            usedPercent: 10,
            resetsAt: reset
        )
        let projection = ProjectionCalculator.calculate(
            window: window,
            samples: [baseline],
            now: now,
            kind: .short
        )
        XCTAssertEqual(projection?.projectedPercent, 70)

        let quietWindow = UsageWindow(
            id: window.id,
            bucketID: window.bucketID,
            bucketName: window.bucketName,
            usedPercent: 20,
            durationMinutes: window.durationMinutes,
            resetsAt: reset
        )
        XCTAssertNil(ProjectionCalculator.calculate(
            window: quietWindow,
            samples: [baseline],
            now: now,
            kind: .short
        ))
    }

    func testDurationFormattingUsesDaysThenHours() {
        XCTAssertEqual(shortDuration(6 * 86_400 + 23 * 3_600), "6d 23h")
        XCTAssertEqual(shortDuration(5_520), "1h 32m")
    }

    private func mappedSnapshot(
        generalWeekly: Double = 1,
        sparkShort: Double,
        sparkWeekly: Double
    ) throws -> UsageSnapshot {
        let payload = try JSONDecoder().decode(
            AppServerRateLimitsPayload.self,
            from: payloadData(
                generalWeekly: generalWeekly,
                sparkShort: sparkShort,
                sparkWeekly: sparkWeekly
            )
        )
        return try UsageMapper.snapshot(from: payload, now: now)
    }

    private func payloadData(
        generalWeekly: Double,
        sparkShort: Double,
        sparkWeekly: Double,
        sparkReachedType: String? = nil
    ) -> Data {
        var codex = bucket(
            id: "codex",
            name: NSNull(),
            primaryPercent: generalWeekly,
            primaryMinutes: 10_080,
            secondaryPercent: nil,
            secondaryMinutes: nil,
            plan: "pro"
        )
        codex["credits"] = ["hasCredits": false, "unlimited": false, "balance": "0"]
        let spark = bucket(
            id: "codex_bengalfox",
            name: "GPT-5.3-Codex-Spark",
            primaryPercent: sparkShort,
            primaryMinutes: 300,
            secondaryPercent: sparkWeekly,
            secondaryMinutes: 10_080,
            plan: nil,
            reachedType: sparkReachedType
        )
        let json: [String: Any] = [
            "rateLimits": codex,
            "rateLimitsByLimitId": [
                "codex": codex,
                "codex_bengalfox": spark,
            ],
            "rateLimitResetCredits": ["availableCount": 0, "credits": []],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func bucket(
        id: String,
        name: Any,
        primaryPercent: Double,
        primaryMinutes: Int,
        secondaryPercent: Double?,
        secondaryMinutes: Int?,
        plan: String?,
        reachedType: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "limitId": id,
            "limitName": name,
            "primary": window(percent: primaryPercent, minutes: primaryMinutes),
            "secondary": NSNull(),
            "rateLimitReachedType": reachedType ?? NSNull(),
            "planType": plan ?? NSNull(),
        ]
        if let secondaryPercent, let secondaryMinutes {
            result["secondary"] = window(percent: secondaryPercent, minutes: secondaryMinutes)
        }
        return result
    }

    private func window(percent: Double, minutes: Int) -> [String: Any] {
        [
            "usedPercent": percent,
            "windowDurationMins": minutes,
            "resetsAt": Int(now.addingTimeInterval(TimeInterval(minutes * 60)).timeIntervalSince1970),
        ]
    }
}

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

    func testBuildChannelEnablesReleaseOnlyBehaviorOnlyForRelease() {
        let release = BuildChannel(plistValue: "release")
        XCTAssertEqual(release, .release)
        XCTAssertTrue(release.automaticUpdatesEnabled)
        XCTAssertTrue(release.loginItemChangesEnabled)

        let mixedCase = BuildChannel(plistValue: "  ReLeAsE\n")
        XCTAssertEqual(mixedCase, .release)
    }

    func testBuildChannelFailsClosedForMissingOrUnknownMetadata() {
        for value: Any? in [nil, "", "development", "nightly", 1] {
            let channel = BuildChannel(plistValue: value)
            XCTAssertEqual(channel, .development)
            XCTAssertFalse(channel.automaticUpdatesEnabled)
            XCTAssertFalse(channel.loginItemChangesEnabled)
        }
    }

    func testDevelopmentStatusSymbolSurvivesUsageAndNonUsageStates() {
        XCTAssertEqual(
            StatusSymbolPolicy.symbolName(channel: .development, isWeekly: nil),
            "hammer.fill"
        )
        XCTAssertEqual(
            StatusSymbolPolicy.symbolName(channel: .development, isWeekly: true),
            "hammer.fill"
        )
        XCTAssertEqual(
            StatusSymbolPolicy.symbolName(channel: .development, isWeekly: false),
            "hammer.fill"
        )
    }

    func testReleaseStatusSymbolsKeepTheirWindowMeaning() {
        XCTAssertNil(StatusSymbolPolicy.symbolName(channel: .release, isWeekly: nil))
        XCTAssertEqual(
            StatusSymbolPolicy.symbolName(channel: .release, isWeekly: true),
            "calendar"
        )
        XCTAssertEqual(
            StatusSymbolPolicy.symbolName(channel: .release, isWeekly: false),
            "clock"
        )
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

    func testWeeklyProjectionBlendsQualifiedRecentPaceWithWindowAverage() {
        let reset = now.addingTimeInterval(3.5 * 86_400)
        let window = UsageWindow(
            id: "codex.primary",
            bucketID: "codex",
            bucketName: "General",
            usedPercent: 8,
            durationMinutes: 10_080,
            resetsAt: reset
        )
        let baseline = ProjectionSample(
            windowID: window.id,
            timestamp: now.addingTimeInterval(-3.5 * 86_400),
            usedPercent: 1,
            resetsAt: reset
        )
        let recent = ProjectionSample(
            windowID: window.id,
            timestamp: now.addingTimeInterval(-12 * 3_600),
            usedPercent: 4,
            resetsAt: reset
        )

        let projection = ProjectionCalculator.calculate(
            window: window,
            samples: [baseline, recent],
            now: now
        )

        XCTAssertEqual(projection?.longTermPointsPerDay ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(projection?.recentPointsPerDay ?? 0, 8, accuracy: 0.001)
        XCTAssertEqual(projection?.pointsPerDay ?? 0, 4.4, accuracy: 0.001)
        XCTAssertEqual(projection?.projectedPercent, 23)
        XCTAssertEqual(projection?.lowerProjectedPercent, 13)
        XCTAssertEqual(projection?.upperProjectedPercent, 38)
    }

    func testRecentPaceRequiresThreePointsOverAtLeastSixHours() {
        let reset = now.addingTimeInterval(3 * 86_400)
        let window = UsageWindow(
            id: "codex.primary",
            bucketID: "codex",
            bucketName: "General",
            usedPercent: 8,
            durationMinutes: 10_080,
            resetsAt: reset
        )
        let baseline = ProjectionSample(
            windowID: window.id,
            timestamp: now.addingTimeInterval(-3 * 86_400),
            usedPercent: 0,
            resetsAt: reset
        )
        let tooLittleMovement = ProjectionSample(
            windowID: window.id,
            timestamp: now.addingTimeInterval(-12 * 3_600),
            usedPercent: 6,
            resetsAt: reset
        )
        let tooRecent = ProjectionSample(
            windowID: window.id,
            timestamp: now.addingTimeInterval(-3 * 3_600),
            usedPercent: 4,
            resetsAt: reset
        )

        let tooSmallProjection = ProjectionCalculator.calculate(
            window: window,
            samples: [baseline, tooLittleMovement],
            now: now
        )
        let tooShortProjection = ProjectionCalculator.calculate(
            window: window,
            samples: [baseline, tooRecent],
            now: now
        )

        XCTAssertNil(tooSmallProjection?.recentPointsPerDay)
        XCTAssertNil(tooShortProjection?.recentPointsPerDay)
        XCTAssertEqual(tooSmallProjection?.pointsPerDay ?? 0, 8.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(tooShortProjection?.pointsPerDay ?? 0, 8.0 / 3.0, accuracy: 0.001)
    }

    func testRecentProjectionMovesSmoothlyAcrossAWholePointUpdate() throws {
        let reset = now.addingTimeInterval(3 * 86_400)
        let windowAtEight = UsageWindow(
            id: "codex.primary",
            bucketID: "codex",
            bucketName: "General",
            usedPercent: 8,
            durationMinutes: 10_080,
            resetsAt: reset
        )
        let samples = [
            ProjectionSample(
                windowID: windowAtEight.id,
                timestamp: now.addingTimeInterval(-3 * 86_400),
                usedPercent: 1,
                resetsAt: reset
            ),
            ProjectionSample(
                windowID: windowAtEight.id,
                timestamp: now.addingTimeInterval(-15 * 3_600),
                usedPercent: 4,
                resetsAt: reset
            ),
            ProjectionSample(
                windowID: windowAtEight.id,
                timestamp: now.addingTimeInterval(-12 * 3_600),
                usedPercent: 5,
                resetsAt: reset
            ),
            ProjectionSample(
                windowID: windowAtEight.id,
                timestamp: now.addingTimeInterval(-9 * 3_600),
                usedPercent: 6,
                resetsAt: reset
            ),
            ProjectionSample(
                windowID: windowAtEight.id,
                timestamp: now.addingTimeInterval(-4 * 3_600),
                usedPercent: 7,
                resetsAt: reset
            ),
            ProjectionSample(
                windowID: windowAtEight.id,
                timestamp: now.addingTimeInterval(-3_600),
                usedPercent: 8,
                resetsAt: reset
            ),
        ]

        let projectionAtEight = ProjectionCalculator.calculate(
            window: windowAtEight,
            samples: samples,
            now: now
        )
        let tenMinutesLater = now.addingTimeInterval(10 * 60)
        let windowAtNine = UsageWindow(
            id: windowAtEight.id,
            bucketID: windowAtEight.bucketID,
            bucketName: windowAtEight.bucketName,
            usedPercent: 9,
            durationMinutes: windowAtEight.durationMinutes,
            resetsAt: reset
        )
        let projectionAtNine = ProjectionCalculator.calculate(
            window: windowAtNine,
            samples: samples + [ProjectionSample(
                windowID: windowAtEight.id,
                timestamp: now,
                usedPercent: 8,
                resetsAt: reset
            )],
            now: tenMinutesLater
        )

        let step = try XCTUnwrap(projectionAtNine?.projectedPercent)
            - (try XCTUnwrap(projectionAtEight?.projectedPercent))
        XCTAssertGreaterThan(step, 0)
        XCTAssertLessThanOrEqual(step, 6)
    }

    func testWholePointUncertaintyPreventsFalseConfidenceNearLimit() {
        let reset = now.addingTimeInterval(2 * 86_400)
        let window = UsageWindow(
            id: "codex.primary",
            bucketID: "codex",
            bucketName: "General",
            usedPercent: 50,
            durationMinutes: 10_080,
            resetsAt: reset
        )
        let baseline = ProjectionSample(
            windowID: window.id,
            timestamp: now.addingTimeInterval(-2 * 86_400),
            usedPercent: 1,
            resetsAt: reset
        )

        let projection = ProjectionCalculator.calculate(window: window, samples: [baseline], now: now)
        XCTAssertEqual(projection?.projectedPercent, 99)
        XCTAssertEqual(projection?.lowerProjectedPercent, 97)
        XCTAssertEqual(projection?.upperProjectedPercent, 101)
        XCTAssertEqual(projection?.outlook, .mayRunOut)
    }

    func testProjectionAcceptsSmallResetTimestampJitter() {
        let reset = now.addingTimeInterval(3 * 86_400)
        let window = UsageWindow(
            id: "codex.primary",
            bucketID: "codex",
            bucketName: "General",
            usedPercent: 40,
            durationMinutes: 10_080,
            resetsAt: reset
        )
        let baseline = ProjectionSample(
            windowID: window.id,
            timestamp: now.addingTimeInterval(-2 * 86_400),
            usedPercent: 10,
            resetsAt: reset.addingTimeInterval(30)
        )

        XCTAssertEqual(
            ProjectionCalculator.calculate(window: window, samples: [baseline], now: now)?.projectedPercent,
            85
        )
    }

    func testServiceTierNormalizesAppServerValues() throws {
        XCTAssertEqual(UsageServiceTier(appServerValue: nil), .standard)
        XCTAssertEqual(UsageServiceTier(appServerValue: "auto"), .standard)
        XCTAssertEqual(UsageServiceTier(appServerValue: "default"), .standard)
        XCTAssertEqual(UsageServiceTier(appServerValue: "fast"), .fast)
        XCTAssertEqual(UsageServiceTier(appServerValue: "priority"), .fast)
        XCTAssertEqual(UsageServiceTier(appServerValue: "ultrafast"), .ultrafast)
        XCTAssertNil(UsageServiceTier(appServerValue: "future-tier"))

        let data = Data(#"{"config":{"service_tier":"priority"}}"#.utf8)
        let payload = try JSONDecoder().decode(AppServerConfigReadPayload.self, from: data)
        XCTAssertEqual(UsageServiceTier(appServerValue: payload.config.serviceTier), .fast)
    }

    @MainActor
    func testProjectionStoreCompactsLegacyTenMinuteHeartbeats() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DexBarProjection-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let reset = now.addingTimeInterval(3 * 86_400)
        var samples = (0...6).map { index in
            ProjectionSample(
                windowID: "codex.primary",
                timestamp: now.addingTimeInterval(TimeInterval(index * 10 * 60)),
                usedPercent: 1,
                resetsAt: reset
            )
        }
        samples.append(ProjectionSample(
            windowID: "codex.primary",
            timestamp: now.addingTimeInterval(70 * 60),
            usedPercent: 2,
            resetsAt: reset
        ))
        samples.append(ProjectionSample(
            windowID: "codex.primary",
            timestamp: now.addingTimeInterval(80 * 60),
            usedPercent: 2,
            resetsAt: reset
        ))
        try JSONEncoder().encode(samples).write(to: url)

        _ = ProjectionStore(url: url)

        let compacted = try JSONDecoder().decode(
            [ProjectionSample].self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(compacted.map(\.usedPercent), [1, 1, 2])
        XCTAssertEqual(compacted.count, 3)
    }

    func testProjectionSampleDecodesLegacyServiceTierField() throws {
        let sample = ProjectionSample(
            windowID: "codex.primary",
            timestamp: now,
            usedPercent: 4,
            resetsAt: now.addingTimeInterval(86_400)
        )
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any]
        )
        object["serviceTier"] = "fast"

        let decoded = try JSONDecoder().decode(
            ProjectionSample.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded, sample)
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

    func testShortProjectionUsesUncertaintyBandNearLimit() {
        let reset = now.addingTimeInterval(2 * 3_600)
        let window = UsageWindow(
            id: "codex.short",
            bucketID: "codex",
            bucketName: "General",
            usedPercent: 50,
            durationMinutes: 300,
            resetsAt: reset
        )
        let baseline = ProjectionSample(
            windowID: window.id,
            timestamp: now.addingTimeInterval(-2 * 3_600),
            usedPercent: 1,
            resetsAt: reset
        )

        let projection = ProjectionCalculator.calculate(
            window: window,
            samples: [baseline],
            now: now,
            kind: .short
        )
        XCTAssertEqual(projection?.projectedPercent, 99)
        XCTAssertEqual(projection?.lowerProjectedPercent, 97)
        XCTAssertEqual(projection?.upperProjectedPercent, 101)
        XCTAssertEqual(projection?.outlook, .mayRunOut)
    }

    func testNotificationLedgerUsesRawPercentAndSurvivesRelaunchAndResetJitter() throws {
        let reset = now.addingTimeInterval(4 * 86_400)
        var ledger = NotificationLedger()

        let roundedButBelowThreshold = snapshot(percent: 79.6, reset: reset)
        XCTAssertTrue(ledger.evaluate(snapshot: roundedButBelowThreshold, projection: nil).isEmpty)

        let warning = snapshot(percent: 80, reset: reset)
        XCTAssertEqual(
            ledger.evaluate(snapshot: warning, projection: nil).map(\.identifier),
            ["codex.primary/80"]
        )

        let persisted = try JSONEncoder().encode(ledger)
        var relaunched = try JSONDecoder().decode(NotificationLedger.self, from: persisted)
        let jittered = snapshot(percent: 81, reset: reset.addingTimeInterval(1))
        XCTAssertTrue(relaunched.evaluate(snapshot: jittered, projection: nil).isEmpty)

        let nextWindow = snapshot(percent: 81, reset: reset.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(
            relaunched.evaluate(snapshot: nextWindow, projection: nil).map(\.identifier),
            ["codex.primary/80"]
        )
    }

    func testNotificationProjectionDoesNotRearmWhenEstimateTemporarilyDisappears() {
        var ledger = NotificationLedger()
        let usage = snapshot(percent: 50, reset: now.addingTimeInterval(3 * 86_400))
        let above = Projection(
            projectedPercent: 105,
            pointsPerDay: 10,
            daysRemaining: 3,
            outlook: .mayRunOut,
            limitReachedAt: nil
        )
        let below = Projection(
            projectedPercent: 90,
            pointsPerDay: 5,
            daysRemaining: 3,
            outlook: .onTrack,
            limitReachedAt: nil
        )

        XCTAssertEqual(
            ledger.evaluate(snapshot: usage, projection: above).map(\.identifier),
            ["weekly/projection"]
        )
        XCTAssertTrue(ledger.evaluate(snapshot: usage, projection: nil).isEmpty)
        XCTAssertTrue(ledger.evaluate(snapshot: usage, projection: above).isEmpty)
        XCTAssertTrue(ledger.evaluate(snapshot: usage, projection: below).isEmpty)
        XCTAssertEqual(
            ledger.evaluate(snapshot: usage, projection: above).map(\.identifier),
            ["weekly/projection"]
        )
    }

    func testClientTimeoutForceKillsAnUnresponsiveProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DexBarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("unresponsive-codex")
        let script = """
        #!/bin/sh
        trap '' TERM
        while :; do
          printf 'diagnostic output that must be drained while waiting\n' >&2
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let started = Date()
        do {
            _ = try await CodexAppServerClient(
                executableURL: executable,
                requestTimeout: 0.1,
                terminationGrace: 0.1
            ).fetch(now: now)
            XCTFail("Expected the unresponsive process to time out")
        } catch CodexClientError.timeout {
            // Expected.
        } catch {
            XCTFail("Expected timeout, received \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testClientReportsFastWhenConfigArrivesBeforeUsage() async throws {
        let fixture = try appServerFixture(responses: [
            #"{"id":2,"result":{"config":{"service_tier":"priority"}}}"#,
            try rateLimitResponseLine(),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let snapshot = try await CodexAppServerClient(
            executableURL: fixture.executable,
            requestTimeout: 1,
            terminationGrace: 0.1
        ).fetch(now: now)

        XCTAssertEqual(snapshot.serviceTier, .fast)
        XCTAssertEqual(snapshot.weekly.id, "codex.primary")
    }

    func testClientReturnsUsageWithoutWaitingForOptionalConfig() async throws {
        let fixture = try appServerFixture(
            responses: [try rateLimitResponseLine()],
            keepAlive: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let started = Date()
        let snapshot = try await CodexAppServerClient(
            executableURL: fixture.executable,
            requestTimeout: 1,
            terminationGrace: 0.1
        ).fetch(now: now)

        XCTAssertNil(snapshot.serviceTier)
        XCTAssertEqual(snapshot.weekly.id, "codex.primary")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9)
    }

    func testClientIgnoresOptionalConfigError() async throws {
        let fixture = try appServerFixture(responses: [
            #"{"id":2,"error":{"message":"optional metadata unavailable"}}"#,
            try rateLimitResponseLine(),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let snapshot = try await CodexAppServerClient(
            executableURL: fixture.executable,
            requestTimeout: 1,
            terminationGrace: 0.1
        ).fetch(now: now)

        XCTAssertNil(snapshot.serviceTier)
        XCTAssertEqual(snapshot.weekly.id, "codex.primary")
    }

    func testDurationFormattingUsesDaysThenHours() {
        XCTAssertEqual(shortDuration(6 * 86_400 + 23 * 3_600), "6d 23h")
        XCTAssertEqual(shortDuration(5_520), "1h 32m")
    }

    private func snapshot(percent: Double, reset: Date) -> UsageSnapshot {
        UsageSnapshot(
            weekly: UsageWindow(
                id: "codex.primary",
                bucketID: "codex",
                bucketName: "General",
                usedPercent: percent,
                durationMinutes: 10_080,
                resetsAt: reset
            ),
            supplementary: [],
            planType: "pro",
            credits: nil,
            resetCreditsAvailable: 0,
            fetchedAt: now
        )
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

    private func rateLimitResponseLine() throws -> String {
        let result = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: payloadData(generalWeekly: 9, sparkShort: 0, sparkWeekly: 0)
            ) as? [String: Any]
        )
        let response: [String: Any] = ["id": 3, "result": result]
        return try XCTUnwrap(
            String(data: JSONSerialization.data(withJSONObject: response), encoding: .utf8)
        )
    }

    private func appServerFixture(
        responses: [String],
        keepAlive: Bool = false
    ) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DexBarFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex-fixture")
        let responseCommands = responses
            .map { "printf '%s\\n' \(shellSingleQuoted($0))" }
            .joined(separator: "\n")
        let keepAliveCommand = keepAlive ? "while :; do sleep 1; done" : ""
        let script = """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r config_request
        IFS= read -r rate_limit_request
        \(responseCommands)
        \(keepAliveCommand)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return (directory, executable)
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

import XCTest
@testable import DexBarCore

final class ProjectionHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_788_260_400)

    private func snapshot(percent: Double, days: Double, resetDays: Double = 7) -> UsageSnapshot {
        UsageSnapshot(
            weekly: UsageWindow(id: "codex.primary", bucketID: "codex", bucketName: "General",
                                usedPercent: percent, durationMinutes: 10_080,
                                resetsAt: start.addingTimeInterval(resetDays * 86_400)),
            supplementary: [], planType: "pro", credits: nil, resetCreditsAvailable: 0,
            fetchedAt: start.addingTimeInterval(days * 86_400)
        )
    }

    @MainActor
    func testQuietObservationsPreserveRecentPaceWarningBeforeAndAfterReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DexBarQuiet-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var store = ProjectionStore(url: url)
        let readings = [snapshot(percent: 0, days: 0), snapshot(percent: 0, days: 4),
                        snapshot(percent: 0, days: 4.5), snapshot(percent: 40, days: 5)]
        readings.forEach { store.record($0) }
        let last = try XCTUnwrap(readings.last)
        let expected = try XCTUnwrap(ProjectionCalculator.calculate(
            window: last.weekly,
            samples: readings.map { ProjectionSample(windowID: $0.weekly.id, timestamp: $0.fetchedAt,
                                                     usedPercent: $0.weekly.usedPercent, resetsAt: $0.weekly.resetsAt) },
            now: last.fetchedAt
        ))
        XCTAssertEqual(expected.outlook, .mayRunOut)
        XCTAssertGreaterThan(expected.projectedPercent, 100)
        XCTAssertEqual(store.projection(for: last.weekly, now: last.fetchedAt), expected)
        store = ProjectionStore(url: url)
        XCTAssertEqual(store.projection(for: last.weekly, now: last.fetchedAt), expected)
    }

    @MainActor
    func testSlidingResetKeepsZeroBaselineForAnchoredWindow() throws {
        let store = ProjectionStore.inMemory()
        store.record(snapshot(percent: 0, days: 0, resetDays: 7))
        store.record(snapshot(percent: 0, days: 1, resetDays: 8))
        let current = snapshot(percent: 10, days: 2, resetDays: 8)
        store.record(current)
        let projection = try XCTUnwrap(store.projection(for: current.weekly, now: current.fetchedAt))
        XCTAssertEqual(projection.projectedPercent, 70)
        XCTAssertEqual(projection.longTermPointsPerDay, 10)
    }

    @MainActor
    func testZeroReadingsRemainHourlyAndExpireAfterEightDays() {
        let store = ProjectionStore.inMemory()
        store.record(snapshot(percent: 0, days: 0))
        store.record(snapshot(percent: 0, days: 5.0 / (24 * 60)))
        store.record(snapshot(percent: 0, days: 1.0 / 24))
        XCTAssertEqual(store.recordedSamples(for: "codex.primary").count, 2)
        let newest = snapshot(percent: 0, days: 9, resetDays: 16)
        store.record(newest)
        XCTAssertEqual(store.recordedSamples(for: "codex.primary").map(\.timestamp), [newest.fetchedAt])
    }
}

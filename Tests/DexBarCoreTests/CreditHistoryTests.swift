import XCTest
@testable import DexBarCore

final class CreditHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func sample(_ hour: Double, _ balance: Decimal) -> CreditSample {
        CreditSample(timestamp: start.addingTimeInterval(hour * 3600), balance: balance)
    }
    private func snapshot(_ hour: Double, _ balance: String?, account: String? = "account-a",
                          plan: String = "plus", unlimited: Bool = false, hasCredits: Bool = true) -> UsageSnapshot {
        UsageSnapshot(weekly: UsageWindow(id: "codex.primary", bucketID: "codex", bucketName: "General",
            usedPercent: 10, durationMinutes: 10080, resetsAt: start.addingTimeInterval(7 * 86400)),
            supplementary: [], planType: plan,
            credits: UsageCredits(hasCredits: hasCredits, unlimited: unlimited, balance: balance),
            resetCreditsAvailable: 0, fetchedAt: start.addingTimeInterval(hour * 3600), accountID: account)
    }
    private func url() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CreditTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("credit-history.json")
    }
    private func estimate(_ state: CreditForecast, file: StaticString = #filePath, line: UInt = #line) throws -> CreditEstimate {
        guard case .estimate(let value) = state else {
            XCTFail("Expected estimate, got \(state)", file: file, line: line)
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }

    func testBalanceFormattingUsesExactlyTwoDecimalsAndValidatesInput() {
        let en = Locale(identifier: "en_US")
        for (input, expected) in [("62500.0000000000", "62,500.00"), ("1234.56789", "1,234.57"),
                                  ("1.005", "1.01"), ("0.00000", "0.00"), ("0.004", "0.00")] {
            XCTAssertEqual(UsageCredits(hasCredits: true, unlimited: false, balance: input).displayBalance(locale: en), expected)
        }
        XCTAssertEqual(CreditBalance.formatted(Decimal(string: "1234.56")!, locale: Locale(identifier: "de_DE")), "1.234,56")
        for bad in ["nan", "Infinity", "-10", "10garbage", "", "1,234.56"] { XCTAssertNil(CreditBalance.parse(bad)) }
        XCTAssertFalse(UsageCredits(hasCredits: false, unlimited: false, balance: "0.000000").isWorthShowing)
        XCTAssertEqual(UsageCredits(hasCredits: true, unlimited: true, balance: nil).displayBalance(), "Unlimited")
        XCTAssertEqual(UsageCredits(hasCredits: true, unlimited: false, balance: nil).displayBalance(), "Available")
    }

    func testSteadySpendingForecastAndMaturity() throws {
        let early = [sample(0, 1000), sample(1, 990)]
        let p = try estimate(CreditForecastCalculator.calculate(samples: early))
        XCTAssertEqual(p.creditsPerDay, 240, accuracy: 0.001)
        XCTAssertEqual(p.secondsRemaining / 3600, 99, accuracy: 0.001)
        XCTAssertTrue(p.preliminary)
        let mature = (0...24).map { sample(Double($0), Decimal(1000 - $0 * 10)) }
        XCTAssertFalse(try estimate(CreditForecastCalculator.calculate(samples: mature)).preliminary)
    }

    func testRequiresOneHourAndObservedSpending() throws {
        XCTAssertEqual(CreditForecastCalculator.calculate(samples: [sample(0, 1000), sample(24, 1000)]), .waitingForSpending)
        XCTAssertEqual(CreditForecastCalculator.calculate(samples: [sample(0, 1000), sample(0.5, 900)]), .collecting(minutes: 30))
        XCTAssertEqual(CreditForecastCalculator.calculate(samples: [sample(0, 1000), sample(3599.0 / 3600, 900)]), .collecting(minutes: 59))
        let p = try estimate(CreditForecastCalculator.calculate(samples: [sample(0, 1000), sample(1, 900)]))
        XCTAssertTrue(p.preliminary)
        XCTAssertEqual(p.secondsRemaining / 3600, 9, accuracy: 0.001)
        // Eligibility is elapsed time, independent of UTC hour bucket boundaries.
        let shifted = try estimate(CreditForecastCalculator.calculate(samples: [sample(0.25, 1000), sample(1.25, 900)]))
        XCTAssertEqual(shifted.creditsPerDay, p.creditsPerDay, accuracy: 0.001)
        // A week on the included allowance cannot mature a newly-started credit rate.
        XCTAssertEqual(CreditForecastCalculator.calculate(samples: [sample(0, 1000), sample(100, 1000), sample(100.25, 990)]), .collecting(minutes: 15))
    }

    func testPreliminaryEstimateRefinesOnNextReadingAndStopsAfterIdleDay() throws {
        let firstHour = [sample(0, 1000), sample(0.5, 995), sample(1, 990)]
        let early = try estimate(CreditForecastCalculator.calculate(samples: firstHour))
        let next = try estimate(CreditForecastCalculator.calculate(samples: firstHour + [sample(2, 960)]))
        XCTAssertTrue(early.preliminary)
        XCTAssertTrue(next.preliminary)
        XCTAssertEqual(early.creditsPerDay, 240, accuracy: 0.001)
        XCTAssertEqual(next.creditsPerDay, 480, accuracy: 0.001)
        XCTAssertLessThan(next.secondsRemaining, early.secondsRemaining)
        XCTAssertEqual(CreditForecastCalculator.calculate(samples: [sample(0, 1000), sample(1, 900), sample(25, 900)]), .waitingForSpending)
    }

    func testFirstHourHistorySurvivesRelaunch() throws {
        let path = try url()
        var store = CreditHistoryStore(url: path)
        store.record(snapshot(0, "1000"))
        store.record(snapshot(0.5, "995"))
        XCTAssertEqual(store.forecast, .collecting(minutes: 30))
        store = CreditHistoryStore(url: path)
        store.record(snapshot(1, "990"))
        let p = try estimate(store.forecast)
        XCTAssertTrue(p.preliminary)
        XCTAssertEqual(p.secondsRemaining / 3600, 99, accuracy: 0.001)
    }

    func testRecentAccelerationAndIdlePeriods() throws {
        let slow = (0...24).map { sample(Double($0), Decimal(10000 - $0 * 10)) }
        let burst = (25...36).map { sample(Double($0), Decimal(9760 - ($0 - 24) * 100)) }
        let p = try estimate(CreditForecastCalculator.calculate(samples: slow + burst))
        let overall = Double(10000 - 8560) / 36 * 24
        XCTAssertGreaterThan(p.creditsPerDay, overall)
        XCTAssertLessThan(p.creditsPerDay, 2400)
        XCTAssertEqual(CreditForecastCalculator.calculate(samples: slow + [sample(48, 9760)]), .waitingForSpending)
    }

    func testStorePersistsExactDecimalsAndRestartsOnTopUpAccountPlanOrMissingBalance() throws {
        let path = try url()
        var store = CreditHistoryStore(url: path)
        for hour in 0...6 { store.record(snapshot(Double(hour), String(1000 - hour * 10) + ".123456789")) }
        _ = try estimate(store.forecast)
        store = CreditHistoryStore(url: path)
        store.record(snapshot(7, "930.123456789"))
        XCTAssertEqual(try estimate(store.forecast).creditsPerDay, 240, accuracy: 0.0001)
        let bytes = try Data(contentsOf: path)
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(json.contains("account-a"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        struct Saved: Decodable { let samples: [CreditSample] }
        XCTAssertEqual(try decoder.decode(Saved.self, from: bytes).samples.last?.balance, Decimal(string: "930.123456789"))
        store.record(snapshot(8, "2000")); XCTAssertEqual(store.forecast, .waitingForSpending)
        store.record(snapshot(9, "1900", account: "account-b")); XCTAssertEqual(store.forecast, .waitingForSpending)
        store.record(snapshot(10, "1800", account: "account-b", plan: "pro")); XCTAssertEqual(store.forecast, .waitingForSpending)
        store.record(snapshot(11, nil, account: "account-b", plan: "pro")); XCTAssertEqual(store.forecast, .unavailable)
        store.record(snapshot(12, "1700", account: "account-b", plan: "pro")); XCTAssertEqual(store.forecast, .waitingForSpending)
        store.record(snapshot(13, "1600", account: "account-b", plan: "pro", unlimited: true)); XCTAssertEqual(store.forecast, .unavailable)
        store.clear(); XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(store.forecast, .unavailable)
    }

    func testOfflineGapAndIdenticalDuplicatePollsDoNotInventSpendingRate() throws {
        let path = try url(); let store = CreditHistoryStore(url: path)
        for hour in 0...6 { store.record(snapshot(Double(hour), String(1000 - hour * 10))) }
        let forecast = store.forecast; let bytes = try Data(contentsOf: path)
        store.record(snapshot(6, "940"))
        XCTAssertEqual(store.forecast, forecast); XCTAssertEqual(try Data(contentsOf: path), bytes)
        store.record(snapshot(40, "100")); XCTAssertEqual(store.forecast, .waitingForSpending)
    }

    func testMissingIdentityCannotCombineAccountsWithinOrAcrossLaunches() throws {
        let path = try url()
        var store = CreditHistoryStore(url: path)
        for hour in 0...24 { store.record(snapshot(Double(hour), String(10000 - hour * 10))) }
        _ = try estimate(store.forecast)
        // Losing identity must break continuity, including if the same account ID returns.
        store.record(snapshot(25, "9750", account: nil))
        XCTAssertEqual(store.forecast, .unavailable)
        store.record(snapshot(26, "100", account: nil))
        XCTAssertEqual(store.forecast, .unavailable)
        for hour in 27...33 {
            store.record(snapshot(Double(hour), String(126 - hour), account: "  "))
            XCTAssertEqual(store.forecast, .unavailable)
        }
        store = CreditHistoryStore(url: path)
        store.record(snapshot(34, "90", account: nil))
        XCTAssertEqual(store.forecast, .unavailable)
        store.record(snapshot(35, "89"))
        XCTAssertEqual(store.forecast, .waitingForSpending)
        for hour in 36...41 { store.record(snapshot(Double(hour), String(124 - hour))) }
        XCTAssertEqual(try estimate(store.forecast).creditsPerDay, 24, accuracy: 0.001)
    }

    func testClockRollbackStartsFreshAndRecoversBeforeOldTimestamp() throws {
        let path = try url()
        var store = CreditHistoryStore(url: path)
        for hour in 0...24 { store.record(snapshot(Double(hour), String(10000 - hour * 10))) }
        _ = try estimate(store.forecast)
        store.record(snapshot(12, "1000"))
        XCTAssertEqual(store.forecast, .waitingForSpending)
        store = CreditHistoryStore(url: path)
        for hour in 13...18 { store.record(snapshot(Double(hour), String(1000 - (hour - 12) * 10))) }
        let p = try estimate(store.forecast)
        XCTAssertTrue(p.preliminary)
        XCTAssertEqual(p.asOf, start.addingTimeInterval(18 * 3600))
        XCTAssertEqual(p.creditsPerDay, 240, accuracy: 0.001)
        XCTAssertEqual(p.secondsRemaining / 3600, 94, accuracy: 0.001)
        // A changed balance at an identical timestamp cannot inherit the old estimate either.
        store.record(snapshot(18, "500"))
        XCTAssertEqual(store.forecast, .waitingForSpending)
    }

    func testAccountAndPlanChangesResetBeforeTimestampChecks() throws {
        for (account, plan, hour) in [("account-b", "plus", 23.5), ("account-a", "pro", 24.0)] {
            let path = try url()
            var store = CreditHistoryStore(url: path)
            for h in 0...24 { store.record(snapshot(Double(h), String(10000 - h * 10))) }
            _ = try estimate(store.forecast)
            store.record(snapshot(hour, "100", account: account, plan: plan))
            XCTAssertEqual(store.forecast, .waitingForSpending)
            store = CreditHistoryStore(url: path)
            for offset in 1...6 {
                store.record(snapshot(hour + Double(offset), String(100 - offset), account: account, plan: plan))
            }
            let p = try estimate(store.forecast)
            XCTAssertTrue(p.preliminary)
            XCTAssertEqual(p.creditsPerDay, 24, accuracy: 0.001)
            XCTAssertEqual(p.secondsRemaining / 86400, 94.0 / 24, accuracy: 0.001)
        }
    }

    func testFrequentPollingAndTimeZoneChangesPreserveSteadyRate() throws {
        let observations = (0...720).map {
            sample(Double($0) / 60, Decimal(1000) - Decimal($0) / 6)
        }
        let p = try estimate(CreditForecastCalculator.calculate(samples: observations))
        XCTAssertEqual(p.creditsPerDay, 240, accuracy: 0.001)
        XCTAssertEqual(p.secondsRemaining / 3600, 88, accuracy: 0.001)
        // UTC timestamps have no dependency on the display calendar or its DST offset.
        let shifted = observations.map { CreditSample(timestamp: $0.timestamp.addingTimeInterval(9 * 3600), balance: $0.balance) }
        XCTAssertEqual(try estimate(CreditForecastCalculator.calculate(samples: shifted)).creditsPerDay,
                       p.creditsPerDay, accuracy: 0.001)
    }

    func testZeroBalanceAndFutureSchema() throws {
        let store = CreditHistoryStore(url: nil)
        store.record(snapshot(0, "0", hasCredits: false)); XCTAssertEqual(store.forecast, .unavailable)
        store.record(snapshot(1, "10")); store.record(snapshot(2, "0", hasCredits: false))
        XCTAssertEqual(store.forecast, .depleted)
        let path = try url()
        let bytes = Data(#"{"schemaVersion":999,"samples":[]}"#.utf8)
        try bytes.write(to: path)
        let future = CreditHistoryStore(url: path)
        future.record(snapshot(0, "100"))
        XCTAssertNotNil(future.persistenceError)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }

    func testRetentionAndWorkerClearGeneration() async throws {
        let path = try url()
        let worker = UsageHistoryWorker(store: .inMemory(), creditStore: CreditHistoryStore(url: path))
        let cal = Calendar(identifier: .gregorian)
        for hour in 0...6 {
            _ = await worker.update(snapshot(Double(hour), String(1000 - hour * 10)), projectionSamples: [], calendar: cal, generation: 0)
        }
        let result = await worker.update(snapshot(7, "930"), projectionSamples: [], calendar: cal, generation: 0)
        _ = try estimate(result.creditForecast)
        let error = await worker.clear(generation: 1); XCTAssertNil(error)
        let rejected = await worker.update(snapshot(8, "920"), projectionSamples: [], calendar: cal, generation: 0)
        XCTAssertEqual(rejected.creditForecast, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let fresh = await worker.update(snapshot(9, "910"), projectionSamples: [], calendar: cal, generation: 2)
        XCTAssertEqual(fresh.creditForecast, .waitingForSpending)
        _ = await worker.clear(generation: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let store = CreditHistoryStore(url: path)
        for hour in 10...210 { store.record(snapshot(Double(hour), String(1000 - hour))) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(samples.count, 193)
        XCTAssertTrue(samples.allSatisfy { ($0["timestamp"] as! Double) >= start.addingTimeInterval(18 * 3600).timeIntervalSince1970 })
    }
}

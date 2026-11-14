import XCTest
import DexBarCore
@testable import DexBar

final class AppModelTests: XCTestCase {
    @MainActor
    func testHistoryReplayBeforeFirstReadingDoesNotHideClearFailure() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DexBarHistoryClear-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        defer { try? FileManager.default.removeItem(at: directory) }

        let historyURL = directory.appendingPathComponent("usage-readings.json")
        let model = AppModel(
            client: CodexAppServerClient(executableURL: nil),
            projectionStore: .inMemory(),
            usageHistoryStore: UsageHistoryStore(url: historyURL)
        )
        var replayedHistory = false
        model.onChange = { [weak model] in
            guard let model else { return }
            model.onChange = nil
            replayedHistory = true
            model.refreshHistoryPresentation()
        }

        let cleared = await model.clearHistory()

        XCTAssertTrue(replayedHistory)
        XCTAssertFalse(cleared)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.isRefreshing)
        guard case .stale(let message) = model.state else {
            return XCTFail("Expected a history clear error, got \(model.state)")
        }
        XCTAssertTrue(message.hasPrefix("Could not clear usage history:"))
    }
}

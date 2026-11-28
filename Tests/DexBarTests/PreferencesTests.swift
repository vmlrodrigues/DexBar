import Foundation
import XCTest
@testable import DexBar

final class PreferencesTests: XCTestCase {
    @MainActor
    func testForecastRangeDefaultsOnAndPersistsBothChoices() async throws {
        let suite = "DexBar.PreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = Preferences(defaults: defaults)
        XCTAssertTrue(settings.showsForecastRange)

        settings.showsForecastRange = false
        let reopened = Preferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(reopened.showsForecastRange)

        reopened.showsForecastRange = true
        let reopenedAgain = Preferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertTrue(reopenedAgain.showsForecastRange)
    }
}

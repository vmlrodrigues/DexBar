import Foundation

/// The behavior a packaged DexBar build is allowed to expose.
///
/// Anything missing or unrecognised fails closed as a development build: it does not
/// contact the update feed or mutate the installed app's login-item registration.
public enum BuildChannel: String, Equatable, Sendable {
    case development
    case release

    public init(plistValue: Any?) {
        guard let raw = plistValue as? String,
              raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(Self.release.rawValue) == .orderedSame else {
            self = .development
            return
        }
        self = .release
    }

    public var automaticUpdatesEnabled: Bool { self == .release }
    public var loginItemChangesEnabled: Bool { self == .release }
}

public enum StatusSymbolPolicy {
    /// `isWeekly == nil` represents loading or failure text without a usage window.
    public static func symbolName(channel: BuildChannel, isWeekly: Bool?) -> String? {
        if channel == .development { return "hammer.fill" }
        guard let isWeekly else { return nil }
        return isWeekly ? "calendar" : "clock"
    }
}

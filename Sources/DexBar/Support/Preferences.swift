import Foundation

enum BarFormat: String, CaseIterable, Identifiable {
    case percentTime
    case timePercent
    case percent
    case time

    var id: String { rawValue }
    var label: String {
        switch self {
        case .percentTime: return "Percent · time"
        case .timePercent: return "Time · percent"
        case .percent: return "Percent only"
        case .time: return "Time only"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var barFormat: BarFormat {
        didSet { defaults.set(barFormat.rawValue, forKey: Keys.barFormat) }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }
    @Published var completedOnboarding: Bool {
        didSet { defaults.set(completedOnboarding, forKey: Keys.completedOnboarding) }
    }
    @Published var popoverHotKeyEnabled: Bool {
        didSet { defaults.set(popoverHotKeyEnabled, forKey: Keys.popoverHotKeyEnabled) }
    }
    @Published var popoverHotKeyCode: Int {
        didSet { defaults.set(popoverHotKeyCode, forKey: Keys.popoverHotKeyCode) }
    }
    @Published var popoverHotKeyModifiers: Int {
        didSet { defaults.set(popoverHotKeyModifiers, forKey: Keys.popoverHotKeyModifiers) }
    }

    private enum Keys {
        static let barFormat = "barFormat"
        static let notificationsEnabled = "notificationsEnabled"
        static let completedOnboarding = "completedOnboarding"
        static let popoverHotKeyEnabled = "popoverHotKeyEnabled"
        static let popoverHotKeyCode = "popoverHotKeyCode"
        static let popoverHotKeyModifiers = "popoverHotKeyModifiers"
    }

    private init() {
        defaults.register(defaults: [
            Keys.barFormat: BarFormat.percentTime.rawValue,
            Keys.notificationsEnabled: true,
            Keys.completedOnboarding: false,
            Keys.popoverHotKeyEnabled: false,
            Keys.popoverHotKeyCode: DefaultHotKey.unsetKeyCode,
            Keys.popoverHotKeyModifiers: DefaultHotKey.unsetModifiers,
        ])
        barFormat = BarFormat(rawValue: defaults.string(forKey: Keys.barFormat) ?? "") ?? .percentTime
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        completedOnboarding = defaults.bool(forKey: Keys.completedOnboarding)
        popoverHotKeyEnabled = defaults.bool(forKey: Keys.popoverHotKeyEnabled)
        popoverHotKeyCode = defaults.integer(forKey: Keys.popoverHotKeyCode)
        popoverHotKeyModifiers = defaults.integer(forKey: Keys.popoverHotKeyModifiers)
    }
}

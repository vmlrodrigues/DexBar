import Foundation
import UserNotifications
import DexBarCore

@MainActor
final class Notifier {
    static let thresholds = [80, 95]
    private static let ledgerKey = "notificationLedger.v1"

    private let defaults: UserDefaults
    private var ledger: NotificationLedger

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.ledgerKey),
           let saved = try? JSONDecoder().decode(NotificationLedger.self, from: data) {
            ledger = saved
        } else {
            ledger = NotificationLedger()
        }
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    func evaluate(snapshot: UsageSnapshot, projection: Projection?) -> [String] {
        guard Preferences.shared.notificationsEnabled else { return [] }
        let events = ledger.evaluate(
            snapshot: snapshot,
            projection: projection,
            thresholds: Self.thresholds
        )
        persistLedger()

        for event in events {
            switch event {
            case .threshold(let window, _):
                let prefix = window.bucketName == "General" ? "" : "\(window.bucketName) "
                post(
                    title: "\(prefix)\(window.title) at \(window.roundedPercent)%",
                    body: "Resets \(clockTime(window.resetsAt)) · in \(shortDuration(window.resetsAt.timeIntervalSinceNow))."
                )
            case .weeklyProjection(let projectedPercent):
                post(
                    title: "Weekly usage may run out",
                    body: "At the current pace, DexBar projects \(projectedPercent)% by reset."
                )
            }
        }
        return events.map(\.identifier)
    }

    private func persistLedger() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: Self.ledgerKey)
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}

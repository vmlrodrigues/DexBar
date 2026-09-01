import Foundation
import UserNotifications
import DexBarCore

@MainActor
final class Notifier {
    static let thresholds = [80, 95]

    private struct WindowState {
        var resetsAt: Date?
        var fired: Set<Int> = []
        var projectionFired = false
    }
    private var states: [String: WindowState] = [:]

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    func evaluate(snapshot: UsageSnapshot, projection: Projection?) -> [String] {
        guard Preferences.shared.notificationsEnabled else { return [] }
        var fired: [String] = []
        for window in [snapshot.weekly] + snapshot.supplementary {
            fired += check(window)
        }

        var weeklyState = states[snapshot.weekly.id] ?? WindowState()
        if weeklyState.resetsAt != snapshot.weekly.resetsAt {
            weeklyState = WindowState(resetsAt: snapshot.weekly.resetsAt)
        }
        if let projection, projection.projectedPercent >= 100, !weeklyState.projectionFired {
            weeklyState.projectionFired = true
            fired.append("weekly/projection")
            post(
                title: "Weekly usage may run out",
                body: "At the current pace, DexBar projects \(projection.projectedPercent)% by reset."
            )
        } else if projection?.projectedPercent ?? 0 < 95 {
            weeklyState.projectionFired = false
        }
        states[snapshot.weekly.id] = weeklyState
        return fired
    }

    private func check(_ window: UsageWindow) -> [String] {
        var state = states[window.id] ?? WindowState()
        if state.resetsAt != window.resetsAt {
            state = WindowState(resetsAt: window.resetsAt)
        }
        var fired: [String] = []
        for threshold in Self.thresholds {
            if window.roundedPercent >= threshold, !state.fired.contains(threshold) {
                state.fired.insert(threshold)
                fired.append("\(window.id)/\(threshold)")
                let prefix = window.bucketName == "General" ? "" : "\(window.bucketName) "
                post(
                    title: "\(prefix)\(window.title) at \(window.roundedPercent)%",
                    body: "Resets \(clockTime(window.resetsAt)) · in \(shortDuration(window.resetsAt.timeIntervalSinceNow))."
                )
            } else if window.roundedPercent < threshold - 5 {
                state.fired.remove(threshold)
            }
        }
        states[window.id] = state
        return fired
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

import Foundation

public enum UsageNotification: Equatable, Sendable {
    case threshold(window: UsageWindow, threshold: Int)
    case weeklyProjection(projectedPercent: Int)

    public var identifier: String {
        switch self {
        case .threshold(let window, let threshold):
            return "\(window.id)/\(threshold)"
        case .weeklyProjection:
            return "weekly/projection"
        }
    }
}

/// Persistent latches for usage notifications.
///
/// Reset timestamps returned by Codex have been observed to move by one second between
/// otherwise identical reads. Treat a small difference as the same window so that jitter
/// cannot clear a latch and repeat an alert.
public struct NotificationLedger: Codable, Equatable, Sendable {
    private struct WindowState: Codable, Equatable, Sendable {
        var resetsAt: Date
        var firedThresholds: Set<Int> = []
        var projectionFired = false
    }

    private var windows: [String: WindowState] = [:]
    private static let resetTolerance: TimeInterval = 5

    public init() {}

    public mutating func evaluate(
        snapshot: UsageSnapshot,
        projection: Projection?,
        thresholds: [Int] = [80, 95]
    ) -> [UsageNotification] {
        var notifications: [UsageNotification] = []

        for window in [snapshot.weekly] + snapshot.supplementary {
            var state = state(for: window)
            for threshold in thresholds {
                if window.usedPercent >= Double(threshold),
                   !state.firedThresholds.contains(threshold) {
                    state.firedThresholds.insert(threshold)
                    notifications.append(.threshold(window: window, threshold: threshold))
                } else if window.usedPercent < Double(threshold - 5) {
                    state.firedThresholds.remove(threshold)
                }
            }
            windows[window.id] = state
        }

        var weeklyState = state(for: snapshot.weekly)
        if let projection {
            if projection.projectedPercent >= 100, !weeklyState.projectionFired {
                weeklyState.projectionFired = true
                notifications.append(.weeklyProjection(projectedPercent: projection.projectedPercent))
            } else if projection.projectedPercent < 95 {
                weeklyState.projectionFired = false
            }
        }
        windows[snapshot.weekly.id] = weeklyState

        return notifications
    }

    private mutating func state(for window: UsageWindow) -> WindowState {
        guard let existing = windows[window.id],
              abs(existing.resetsAt.timeIntervalSince(window.resetsAt)) < Self.resetTolerance else {
            return WindowState(resetsAt: window.resetsAt)
        }
        return existing
    }
}

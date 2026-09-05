import AppKit
import DexBarCore

@MainActor
final class StatusItemController {
    private let model: AppModel
    private let item: NSStatusItem
    private var lastKey: String?
    var onClick: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
    }

    var button: NSStatusBarButton? { item.button }

    @objc private func clicked() { onClick?() }

    func forceRedraw() {
        lastKey = nil
        update()
    }

    func update(now: Date = Date()) {
        guard let button = item.button else { return }
        func developmentTooltip(_ tooltip: String?) -> String? {
            guard CurrentBuild.isDevelopment else { return tooltip }
            let marker = "DexBar Development — automatic updates disabled"
            guard let tooltip, !tooltip.isEmpty else { return marker }
            return "\(tooltip)\n\(marker)"
        }

        func plain(_ text: String, health: UsageHealth, tooltip: String?) {
            let tooltip = developmentTooltip(tooltip)
            let key = "plain|\(text)|\(health.rawValue)|\(tooltip ?? "")|\(CurrentBuild.channel.rawValue)"
            guard key != lastKey else { return }
            lastKey = key
            button.image = nil
            button.attributedTitle = attributedPlainStatus(text, health: health)
            button.toolTip = tooltip
            button.setAccessibilityLabel(
                "DexBar\(CurrentBuild.isDevelopment ? " development" : ""), \(text)"
            )
        }

        switch model.state {
        case .loading where model.snapshot == nil:
            plain("…", health: .normal, tooltip: "Checking Codex usage")
        case .needsAuthentication:
            plain("Sign in", health: .critical, tooltip: "Codex needs you to sign in again")
        case .cliUnavailable:
            plain("No Codex", health: .warning, tooltip: "Codex CLI was not found")
        case .failed(let message) where model.snapshot == nil:
            plain("—", health: .warning, tooltip: message)
        default:
            guard let snapshot = model.snapshot else {
                plain("—", health: .warning, tooltip: nil)
                return
            }
            let window = snapshot.preferredMenuWindow
            var suffix = ""
            var tooltip = "Updated \(shortDuration(now.timeIntervalSince(snapshot.fetchedAt))) ago"
            if case .stale(let message) = model.state {
                suffix = " •"
                tooltip = "Stale: \(message)"
            }
            tooltip = developmentTooltip(tooltip) ?? tooltip
            let formatted = formatWindow(window, format: Preferences.shared.barFormat, now: now)
            let key = "\(window.id)|\(window.roundedPercent)|\(Int(window.resetsAt.timeIntervalSince(now) / 60))|\(Preferences.shared.barFormat.rawValue)|\(suffix)|\(tooltip)|\(CurrentBuild.channel.rawValue)"
            guard key != lastKey else { return }
            lastKey = key
            button.image = nil
            button.attributedTitle = attributedStatus(
                window: window,
                format: Preferences.shared.barFormat,
                now: now,
                suffix: suffix
            )
            button.toolTip = tooltip
            button.setAccessibilityLabel(
                "DexBar\(CurrentBuild.isDevelopment ? " development" : ""), \(formatted)\(suffix)"
            )
        }
    }
}

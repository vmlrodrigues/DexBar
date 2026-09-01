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
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        func plain(_ text: String, color: NSColor, tooltip: String?) {
            let key = "plain|\(text)|\(color.description)"
            guard key != lastKey else { return }
            lastKey = key
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: color]
            )
            button.toolTip = tooltip
        }

        switch model.state {
        case .loading where model.snapshot == nil:
            plain("…", color: .labelColor, tooltip: "Checking Codex usage")
        case .needsAuthentication:
            plain("Sign in", color: .systemRed, tooltip: "Codex needs you to sign in again")
        case .cliUnavailable:
            plain("No Codex", color: .systemOrange, tooltip: "Codex CLI was not found")
        case .failed(let message) where model.snapshot == nil:
            plain("—", color: .systemOrange, tooltip: message)
        default:
            guard let snapshot = model.snapshot else {
                plain("—", color: .systemOrange, tooltip: nil)
                return
            }
            let window = snapshot.preferredMenuWindow
            var suffix = ""
            var tooltip = "Updated \(shortDuration(now.timeIntervalSince(snapshot.fetchedAt))) ago"
            if case .stale(let message) = model.state {
                suffix = " •"
                tooltip = "Stale: \(message)"
            }
            let key = "\(window.id)|\(window.roundedPercent)|\(Int(window.resetsAt.timeIntervalSince(now) / 60))|\(Preferences.shared.barFormat.rawValue)|\(suffix)"
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
        }
    }
}

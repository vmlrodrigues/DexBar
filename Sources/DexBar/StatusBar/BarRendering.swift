import AppKit
import DexBarCore

extension UsageHealth {
    var nsColor: NSColor {
        switch self {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

func formatWindow(_ window: UsageWindow, format: BarFormat, now: Date) -> String {
    let percent = "\(window.roundedPercent)%"
    let time = shortDuration(window.resetsAt.timeIntervalSince(now))
    switch format {
    case .percentTime: return "\(percent) · \(time)"
    case .timePercent: return "\(time) · \(percent)"
    case .percent: return percent
    case .time: return time
    }
}

@MainActor
enum StatusSymbolCache {
    private static var cache: [String: NSImage] = [:]

    static func image(name: String, health: UsageHealth) -> NSImage? {
        let key = "\(name)|\(health.rawValue)"
        if let cached = cache[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            health.nsColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        cache[key] = image
        return image
    }

    static func invalidate() { cache.removeAll() }
}

@MainActor
func attributedStatus(window: UsageWindow, format: BarFormat, now: Date, suffix: String) -> NSAttributedString {
    let output = NSMutableAttributedString()
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let symbol = window.isWeekly ? "calendar" : "clock"
    if let image = StatusSymbolCache.image(name: symbol, health: window.health) {
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
        output.append(NSAttributedString(attachment: attachment))
    }
    output.append(NSAttributedString(
        string: " " + formatWindow(window, format: format, now: now) + suffix,
        attributes: [.font: font, .foregroundColor: window.health.nsColor]
    ))
    return output
}

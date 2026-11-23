import AppKit
import SwiftUI
import DexBarCore

extension UsageHealth {
    var color: Color {
        switch self {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

struct AppMark: View {
    var size: CGFloat = 30

    var body: some View {
        Image(nsImage: applicationIcon)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var applicationIcon: NSImage {
        // A packaged build must always show the icon registered with AppKit. The
        // source-tree fallback keeps the existing headless screenshot renderer useful.
        if Bundle.main.bundleURL.pathExtension == "app" {
            return NSApplication.shared.applicationIconImage
        }
        let sourceIcon = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/AppIcon.icns")
        return NSImage(contentsOf: sourceIcon) ?? NSApplication.shared.applicationIconImage
    }
}

struct UsageWindowRow: View {
    let window: UsageWindow
    var projection: Projection?
    var showContext = false
    var historyHint = false
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showContext {
                Text("\(window.bucketName) · active now")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            HStack(spacing: 6) {
                Image(systemName: window.isWeekly ? "calendar" : "clock")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(window.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(window.roundedPercent)% used")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(window.health.color)
            }
            UsageMeter(window: window, projection: projection)
            HStack(spacing: 4) {
                Text("Resets \(resetDescription(window.resetsAt, relativeTo: now)) · in \(shortDuration(window.resetsAt.timeIntervalSince(now)))")
                    .lineLimit(1)
                Spacer(minLength: 4)
                if historyHint {
                    HStack(spacing: 1) {
                        Text("History")
                        Image(systemName: "chevron.right")
                    }
                    .fixedSize()
                    .transition(.opacity)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }
}

func bundleVersionString() -> String {
    let isHeadlessRender = CommandLine.arguments.contains { $0.hasPrefix("--render-") }
    let environment = ProcessInfo.processInfo.environment
    let version = (isHeadlessRender ? environment["DEXBAR_RENDER_VERSION"] : nil)
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "—"
    let build = (isHeadlessRender ? environment["DEXBAR_RENDER_BUILD"] : nil)
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? "—"
    return "\(version) (\(build))"
}

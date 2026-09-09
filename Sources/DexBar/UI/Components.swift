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

struct UsageMeter: View {
    let window: UsageWindow
    var projection: Projection?

    private static let labelWidth: CGFloat = 84
    private static let barHeight: CGFloat = 10
    private static let chevronGutter: CGFloat = 6
    private static let caretGap: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    if let projection {
                        let reach = geometry.size.width * min(1, Double(projection.projectedPercent) / 100)
                        Capsule()
                            .fill(projectionColor.opacity(0.30))
                            .frame(width: reach)
                        if projection.projectedPercent <= 100 {
                            Capsule()
                                .fill(projectionColor.opacity(0.9))
                                .frame(width: 2)
                                .offset(x: max(0, reach - 2))
                        }
                    }
                    Capsule()
                        .fill(window.health.color)
                        // Keep a non-zero reading circular until its proportional width
                        // is wide enough to form a proper capsule. The percentage label
                        // remains exact; this only prevents tiny values looking like a
                        // clipped vertical tick.
                        .frame(width: window.utilization > 0
                            ? max(Self.barHeight, geometry.size.width * window.utilization)
                            : 0)
                }
                .overlay(alignment: .leading) {
                    if let projection, projection.projectedPercent > 100 {
                        let over = projection.projectedPercent - 100
                        let count = over >= 75 ? 3 : (over >= 25 ? 2 : 1)
                        HStack(spacing: -2) {
                            ForEach(0..<count, id: \.self) { _ in
                                Text("›").font(.system(size: 14, weight: .bold))
                            }
                        }
                        .foregroundStyle(projectionColor)
                        .fixedSize()
                        .offset(x: geometry.size.width + 3)
                    }
                }
            }
            .frame(height: Self.barHeight)
            .padding(.trailing, Self.chevronGutter)

            if let projection, projection.projectedPercent > 100 {
                Text("projected \(projection.projectedPercent)%")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(projectionColor)
                    .padding(.top, 3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(projectionDetail(projection))
            } else if let projection {
                GeometryReader { geometry in
                    let fraction = min(1, Double(projection.projectedPercent) / 100)
                    let x = geometry.size.width * fraction
                    let flip = x + Self.caretGap + Self.labelWidth > geometry.size.width
                    ZStack(alignment: .topLeading) {
                        Text("▲")
                            .font(.system(size: 8))
                            .offset(x: max(0, x - 3))
                        Text("projected \(projection.projectedPercent)%")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .frame(width: Self.labelWidth, alignment: flip ? .trailing : .leading)
                            .offset(x: flip ? x - Self.labelWidth - Self.caretGap : x + Self.caretGap)
                    }
                    .foregroundStyle(projectionColor)
                    .help(projectionDetail(projection))
                }
                .frame(height: 12)
                .padding(.trailing, Self.chevronGutter)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.title)
        .accessibilityValue(accessibilityValue)
    }

    private var projectionColor: Color {
        switch projection?.outlook {
        case .mayRunOut: return .orange
        case .likelyToRunOut: return .red
        default: return .secondary
        }
    }

    private var accessibilityValue: String {
        var value = "\(window.roundedPercent) percent used"
        if let projection { value += ", projected \(projection.projectedPercent) percent" }
        return value
    }

    private func projectionDetail(_ projection: Projection) -> String {
        var lines: [String]
        if let recent = projection.recentPointsPerDay {
            lines = [String(
                format: "Blends a smoothed recent pace (%.1f points/day) with the window average (%.1f points/day).",
                recent,
                projection.longTermPointsPerDay
            )]
            lines.append(
                "Those paces plus whole-point measurement uncertainty project "
                    + "\(projection.lowerProjectedPercent)–\(projection.upperProjectedPercent)%; the marker uses the blend."
            )
        } else {
            lines = [String(
                format: "Projected from the window average of %.1f percentage points per day.",
                projection.longTermPointsPerDay
            )]
            lines.append(
                "Whole-point measurement uncertainty gives a range of "
                    + "\(projection.lowerProjectedPercent)–\(projection.upperProjectedPercent)%."
            )
            if window.isWeekly {
                lines.append("A recent trend needs at least 3 percentage points measured over 6–24 hours.")
            }
        }
        if let reachedAt = projection.limitReachedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = DateFormatter.dateFormat(
                fromTemplate: "EEEdMMMjm",
                options: 0,
                locale: .current
            )
            lines.append("At this rate the limit arrives \(formatter.string(from: reachedAt)).")
        }
        switch projection.outlook {
        case .onTrack: lines.append("On track to finish this window under the limit.")
        case .mayRunOut: lines.append("Close enough to the limit that it could go either way.")
        case .likelyToRunOut: lines.append("Heading over the limit before this window resets.")
        }
        return lines.joined(separator: "\n")
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

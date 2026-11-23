import SwiftUI
import DexBarCore

struct UsageMeter: View {
    let window: UsageWindow
    let projection: Projection?

    @Environment(\.colorScheme) private var colorScheme

    private static let trackHeight: CGFloat = 10
    private static let forecastLabelHeight: CGFloat = 18
    private static let boundLabelsHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let projection {
                GeometryReader { geometry in
                    let layout = ForecastMeterLayout(
                        width: geometry.size.width, projectedPercent: projection.projectedPercent,
                        lowerPercent: projection.lowerProjectedPercent, upperPercent: projection.upperProjectedPercent
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        forecastLabel(projection, layout: layout)
                        track(width: layout.trackWidth, layout: layout)
                        bounds(projection, layout: layout)
                    }
                }
                .frame(height: Self.forecastLabelHeight + Self.trackHeight + Self.boundLabelsHeight)
                if window.isWeekly, projection.historicalPointsPerDay != nil {
                    Text("Based on recent history")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .help(projectionDetail(projection))
                }
            } else {
                GeometryReader { geometry in
                    track(width: max(0, geometry.size.width - ForecastMeterLayout.overflowGutter))
                }
                .frame(height: Self.trackHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.title)
        .accessibilityValue(Self.accessibilityValue(for: window, projection: projection))
    }

    private func forecastLabel(_ projection: Projection, layout: ForecastMeterLayout) -> some View {
        let labelWidth: CGFloat = 94
        let infoWidth: CGFloat = 18
        let left = min(max(0, layout.projectionX - labelWidth / 2),
                       max(0, layout.trackWidth - labelWidth - infoWidth))
        return HStack(spacing: 0) {
            Text("\(projection.projectedPercent)% projected")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: labelWidth)
                .help(projectionDetail(projection))
            Color.clear
                .frame(width: infoWidth, height: 16)
                .anchorPreference(key: ForecastInfoAnchor.self, value: .bounds) { $0 }
        }
        .frame(height: Self.forecastLabelHeight, alignment: .top)
        .offset(x: left)
    }

    private func track(width: CGFloat, layout: ForecastMeterLayout? = nil) -> some View {
        let usedWidth = width * window.utilization
        // A small nonzero reading gets a dot up to the start of the forecast band.
        let minimumUsageWidth = min(Self.trackHeight, layout?.lowerX ?? width)
        let fillWidth = usedWidth > 0 ? min(width, max(usedWidth, minimumUsageWidth)) : 0

        return ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.18))
            if let layout {
                let start = min(layout.lowerX, width)
                let end = min(layout.upperX, width)
                Rectangle()
                    .fill(projectionColor.opacity(0.32))
                    .frame(width: max(0, end - start))
                    .offset(x: start)
            }
            Capsule()
                .fill(window.health.color)
                .frame(width: fillWidth)
        }
        .frame(width: width, height: Self.trackHeight)
        .clipShape(Capsule())
        .overlay(alignment: .leading) {
            if let layout, let projection {
                // Both markers measure their offset from the track's leading edge.
                ZStack(alignment: .leading) {
                    if projection.projectedPercent <= 100 {
                        Capsule()
                            .fill(Color.primary)
                            .frame(width: min(2, width), height: 14)
                            .offset(x: min(max(0, layout.projectionX - 1), max(0, width - 2)))
                    }
                    if projection.upperProjectedPercent > 100 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(leaderColor)
                            .frame(width: ForecastMeterLayout.overflowGutter)
                            .offset(x: width)
                    }
                }
            }
        }
    }

    private func bounds(_ projection: Projection, layout: ForecastMeterLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                let halfSpan = max(0, layout.labelWidth / 2 - 6)
                for (endpoint, labelCenter) in [(layout.lowerX, layout.lowerLabelCenter),
                                                (layout.upperX, layout.upperLabelCenter)] {
                    let labelEdge = min(max(endpoint, labelCenter - halfSpan), labelCenter + halfSpan)
                    path.move(to: CGPoint(x: endpoint, y: 0))
                    path.addLine(to: CGPoint(x: endpoint, y: 5))
                    path.addLine(to: CGPoint(x: labelEdge, y: 5))
                }
            }
            .stroke(leaderColor.opacity(0.68), lineWidth: 1)

            boundLabel(projection.lowerProjectedPercent, at: layout.lowerLabelCenter, width: layout.labelWidth)
            boundLabel(projection.upperProjectedPercent, at: layout.upperLabelCenter, width: layout.labelWidth)
        }
        .frame(height: Self.boundLabelsHeight)
        .font(.system(size: 10, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(secondaryTextColor)
    }

    private func boundLabel(_ percent: Int, at center: CGFloat, width: CGFloat) -> some View {
        Text("\(percent)%")
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: width)
            .offset(x: center - width / 2, y: 7)
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color(white: 0.68) : Color(white: 0.40)
    }

    private var leaderColor: Color {
        switch projection?.outlook {
        case .mayRunOut:
            return colorScheme == .dark ? Color(red: 1, green: 0.69, blue: 0.32)
                : Color(red: 0.59, green: 0.31, blue: 0.02)
        case .likelyToRunOut:
            return colorScheme == .dark ? Color(red: 1, green: 0.45, blue: 0.43)
                : Color(red: 0.69, green: 0.13, blue: 0.11)
        default:
            return secondaryTextColor
        }
    }

    private var projectionColor: Color {
        switch projection?.outlook {
        case .mayRunOut: return .orange
        case .likelyToRunOut: return .red
        default: return .secondary
        }
    }

    static func accessibilityValue(for window: UsageWindow, projection: Projection?) -> String {
        var value = "\(window.roundedPercent) percent used"
        if let projection {
            value += ", projected \(projection.projectedPercent) percent"
            value += ", forecast range \(projection.lowerProjectedPercent) to \(projection.upperProjectedPercent) percent"
            if projection.outlook == .mayRunOut { value += ", may hit limit" }
            if projection.outlook == .likelyToRunOut { value += ", likely to hit limit" }
            if projection.historicalPointsPerDay != nil { value += ", based on recent history" }
            if projection.isPreliminary { value += ", preliminary forecast" }
        }
        return value
    }

    private func projectionDetail(_ projection: Projection) -> String {
        var lines: [String]
        if let historical = projection.historicalPointsPerDay {
            lines = [String(
                format: "Uses a recent previous allowance pace of %.1f percentage points per day, measured over elapsed time including pauses.",
                historical
            )]
            lines.append("This week's measured pace gradually replaces that history during its first 24 hours.")
            lines.append(
                "This preliminary forecast has a range of "
                    + "\(projection.lowerProjectedPercent)–\(projection.upperProjectedPercent)%; early activity may not represent a full day."
            )
        } else if let recent = projection.recentPointsPerDay {
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

// The info button is an overlay sibling of the weekly History button, not a
// button inside its label. The meter provides the exact spot to place it.
private struct ForecastInfoAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    func forecastInfoControl() -> some View {
        overlayPreferenceValue(ForecastInfoAnchor.self) { anchor in
            if let anchor {
                GeometryReader { geometry in
                    let frame = geometry[anchor]
                    ForecastInfoButton()
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
    }
}

private struct ForecastInfoButton: View {
    @State private var isShowingInfo = false

    var body: some View {
        Button {
            isShowingInfo.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About the forecast")
        .focusable(false)
        .focusEffectDisabled()
        .popover(isPresented: $isShowingInfo, arrowEdge: .top) {
            ForecastInfo()
        }
    }
}

struct ForecastInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("About the forecast")
                .font(.system(size: 12, weight: .semibold))
            Text("The percentage above the bar is the main estimate of your usage at reset. For estimates up to 100%, a tick marks the value on the bar.")
            Text("The two percentages below show the low and high estimates, allowing for differences in measured pace and rounding. A chevron means the range extends past your allowance.")
        }
        .font(.system(size: 11))
        .frame(width: 236, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
    }
}

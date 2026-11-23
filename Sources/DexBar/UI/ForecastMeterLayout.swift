import Foundation

struct ForecastMeterLayout {
    static let overflowGutter: CGFloat = 11
    static let boundLabelWidth: CGFloat = 40

    let trackWidth: CGFloat
    let projectionX: CGFloat
    let lowerX: CGFloat
    let upperX: CGFloat
    let labelWidth: CGFloat
    let lowerLabelCenter: CGFloat
    let upperLabelCenter: CGFloat

    init(width: CGFloat, projectedPercent: Int, lowerPercent: Int, upperPercent: Int) {
        let width = max(0, width)
        let trackWidth = max(0, width - Self.overflowGutter)
        self.trackWidth = trackWidth

        func onTrack(_ percent: Int) -> CGFloat {
            trackWidth * CGFloat(min(100, max(0, percent))) / 100
        }

        // Values past the allowance share the chevron in the gutter. Their labels
        // show the actual values while the track retains its 0–100% scale.
        let overflowX = min(width, trackWidth + 6)
        projectionX = projectedPercent > 100 ? overflowX : onTrack(projectedPercent)
        lowerX = lowerPercent > 100 ? overflowX : onTrack(lowerPercent)
        upperX = upperPercent > 100 ? overflowX : onTrack(upperPercent)

        let gap = min(4, width)
        labelWidth = min(Self.boundLabelWidth, (width - gap) / 2)
        let halfLabel = labelWidth / 2
        // Move labels away from each other and inside the view as needed. The
        // leader lines still start at the actual range endpoints.
        upperLabelCenter = min(max(upperX, labelWidth + gap + halfLabel), width - halfLabel)
        lowerLabelCenter = min(max(lowerX, halfLabel), upperLabelCenter - labelWidth - gap)
    }
}

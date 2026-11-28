import AppKit
import SwiftUI
import XCTest
import DexBarCore
@testable import DexBar

final class UsageMeterTests: XCTestCase {
    private let meterWidth: CGFloat = 302
    private let renderScale: CGFloat = 2
    private var trackEnd: Int { Int((meterWidth - ForecastMeterLayout.overflowGutter) * renderScale) }

    @MainActor
    func testNarrowForecastBandIsVisibleBesideLowUsage() async throws {
        let window = UsageWindow(
            id: "codex.primary", bucketID: "codex", bucketName: "General",
            usedPercent: 1, durationMinutes: 10_080,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let projection = Projection(
            projectedPercent: 1, pointsPerDay: 0,
            lowerProjectedPercent: 1, upperProjectedPercent: 3,
            daysRemaining: 0.5, outlook: .onTrack, limitReachedAt: nil
        )
        let bitmap = try renderMeter(window: window, projection: projection)

        // Sample the center of the track at 6pt (within the band, away from
        // the tick) and at 20pt (unused track). The band should be gray and
        // darker than the track. The old 10pt usage dot painted it blue.
        let band = try XCTUnwrap(bitmap.colorAt(x: 12, y: 46)?.usingColorSpace(.sRGB))
        let unused = try XCTUnwrap(bitmap.colorAt(x: 40, y: 46)?.usingColorSpace(.sRGB))
        XCTAssertEqual(band.redComponent, band.blueComponent, accuracy: 0.02)
        XCTAssertGreaterThan(unused.redComponent - band.redComponent, 0.05)
    }

    @MainActor
    func testTickAt100PercentStaysOnTrackBesideOverflowChevron() async throws {
        let window = UsageWindow(
            id: "codex.primary", bucketID: "codex", bucketName: "General",
            usedPercent: 96, durationMinutes: 10_080,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let projection = Projection(
            projectedPercent: 100, pointsPerDay: 2,
            lowerProjectedPercent: 97, upperProjectedPercent: 103,
            daysRemaining: 2, outlook: .mayRunOut, limitReachedAt: nil
        )
        let bitmap = try renderMeter(window: window, projection: projection)

        // Above the bar the only painted mark at the track end is the tick.
        let tick = try XCTUnwrap(bitmap.colorAt(x: trackEnd - 2, y: 34)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(max(tick.redComponent, tick.greenComponent, tick.blueComponent), 0.3,
                          "The 100% tick should be at the end of the track.")

        XCTAssertTrue(hasOverflowChevron(in: bitmap), "The overflow chevron should still appear in the gutter.")
    }

    @MainActor
    func testHidingRangeDrawsNeutralContinuationToCentralEstimate() async throws {
        let window = UsageWindow(
            id: "codex.primary", bucketID: "codex", bucketName: "General",
            usedPercent: 20, durationMinutes: 10_080,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let projection = Projection(
            projectedPercent: 69, pointsPerDay: 8.66,
            lowerProjectedPercent: 52, upperProjectedPercent: 110,
            daysRemaining: 5.684, outlook: .mayRunOut, limitReachedAt: nil
        )
        let range = try renderMeter(window: window, projection: projection)
        let compact = try renderMeter(window: window, projection: projection, showsForecastRange: false)

        // The shaded continuation covers 20–69%, including 40%, so 85% is unused.
        let continuation = try XCTUnwrap(compact.colorAt(x: Int(Double(trackEnd) * 0.40), y: 46)?.usingColorSpace(.sRGB))
        let unused = try XCTUnwrap(compact.colorAt(x: Int(Double(trackEnd) * 0.85), y: 46)?.usingColorSpace(.sRGB))
        XCTAssertEqual(continuation.redComponent, continuation.blueComponent, accuracy: 0.02)
        XCTAssertGreaterThan(unused.redComponent - continuation.redComponent, 0.05)
        let tick = try XCTUnwrap(compact.colorAt(x: Int(Double(trackEnd) * 0.69), y: 34)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(max(tick.redComponent, tick.greenComponent, tick.blueComponent), 0.3)
        XCTAssertFalse(hasOverflowChevron(in: compact))
        XCTAssertEqual(range.pixelsHigh - compact.pixelsHigh, Int(20 * renderScale))
        XCTAssertEqual(UsageMeter.accessibilityValue(for: window, projection: projection, showsForecastRange: false),
                       "20 percent used, projected 69 percent")
    }

    @MainActor
    func testCompactForecastShowsChevronOnlyPastTheLimit() async throws {
        let window = UsageWindow(
            id: "codex.primary", bucketID: "codex", bucketName: "General",
            usedPercent: 74, durationMinutes: 10_080,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        for estimate in [100, 109] {
            let projection = Projection(
                projectedPercent: estimate, pointsPerDay: 5,
                lowerProjectedPercent: 85, upperProjectedPercent: 123,
                daysRemaining: 6.95, outlook: .mayRunOut, limitReachedAt: nil
            )
            let bitmap = try renderMeter(window: window, projection: projection, showsForecastRange: false)
            let continuation = try XCTUnwrap(bitmap.colorAt(x: Int(Double(trackEnd) * 0.90), y: 46)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(continuation.redComponent - continuation.blueComponent, 0.08)
            XCTAssertEqual(hasOverflowChevron(in: bitmap), estimate > 100)

            let tick = try XCTUnwrap(bitmap.colorAt(x: trackEnd - 2, y: 34)?.usingColorSpace(.sRGB))
            let hasTick = max(tick.redComponent, tick.greenComponent, tick.blueComponent) < 0.3
            XCTAssertEqual(hasTick, estimate == 100)
        }
    }

    private func hasOverflowChevron(in bitmap: NSBitmapImageRep) -> Bool {
        // Scan across the gutter at mid-track height for the colored chevron.
        (trackEnd..<bitmap.pixelsWide).contains { x in
            guard let color = bitmap.colorAt(x: x, y: 46)?.usingColorSpace(.sRGB) else { return false }
            return color.redComponent - color.blueComponent > 0.25
        }
    }

    @MainActor
    private func renderMeter(
        window: UsageWindow, projection: Projection, showsForecastRange: Bool = true
    ) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(
            content: UsageMeter(window: window, projection: projection, showsForecastRange: showsForecastRange)
                .frame(width: meterWidth)
                .environment(\.colorScheme, .light)
                .accentColor(.blue)
                .background(.white)
        )
        renderer.scale = renderScale
        let image = try XCTUnwrap(renderer.cgImage)
        return NSBitmapImageRep(cgImage: image)
    }
}

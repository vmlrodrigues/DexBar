import AppKit
import SwiftUI
import XCTest
import DexBarCore
@testable import DexBar

final class UsageMeterTests: XCTestCase {
    private let meterWidth: CGFloat = 302
    private let renderScale: CGFloat = 2

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
        let trackEnd = Int((meterWidth - ForecastMeterLayout.overflowGutter) * renderScale)

        // Above the bar the only painted mark at the track end is the tick.
        let tick = try XCTUnwrap(bitmap.colorAt(x: trackEnd - 2, y: 34)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(max(tick.redComponent, tick.greenComponent, tick.blueComponent), 0.3,
                          "The 100% tick should be at the end of the track.")

        // Scan across the gutter at mid-track height for the orange chevron.
        let chevronIsVisible = (trackEnd..<bitmap.pixelsWide).contains { x in
            guard let color = bitmap.colorAt(x: x, y: 46)?.usingColorSpace(.sRGB) else { return false }
            return color.redComponent - color.blueComponent > 0.25
        }
        XCTAssertTrue(chevronIsVisible, "The overflow chevron should still appear in the gutter.")
    }

    @MainActor
    private func renderMeter(window: UsageWindow, projection: Projection) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(
            content: UsageMeter(window: window, projection: projection)
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

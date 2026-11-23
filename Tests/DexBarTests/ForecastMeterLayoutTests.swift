import Foundation
import XCTest
@testable import DexBar

final class ForecastMeterLayoutTests: XCTestCase {
    func testRangeCrossingLimitKeepsThePercentageScaleAndLabelsInsideTheMeter() {
        let width: CGFloat = 302
        let layout = ForecastMeterLayout(width: width, projectedPercent: 69,
                                         lowerPercent: 52, upperPercent: 110)

        XCTAssertGreaterThan(layout.trackWidth, 0)
        XCTAssertLessThan(layout.trackWidth, width)
        XCTAssertEqual(layout.projectionX, layout.trackWidth * 0.69, accuracy: 0.001)
        XCTAssertEqual(layout.lowerX, layout.trackWidth * 0.52, accuracy: 0.001)
        XCTAssertGreaterThan(layout.upperX, layout.trackWidth)
        XCTAssertLessThanOrEqual(layout.upperX, width)
        XCTAssertEqual(layout.lowerLabelCenter, layout.lowerX, accuracy: 0.001)
        assertBoundLabelsFit(layout, width: width)
    }

    func testCloseBoundsAtEitherTrackEdgeStayReadable() {
        for width in [CGFloat(120), CGFloat(302)] {
            for (projected, lower, upper) in [(1, 0, 1), (99, 98, 100)] {
                let layout = ForecastMeterLayout(width: width, projectedPercent: projected,
                                                 lowerPercent: lower, upperPercent: upper)

                XCTAssertEqual(layout.lowerX, layout.trackWidth * CGFloat(lower) / 100,
                               accuracy: 0.001)
                XCTAssertEqual(layout.upperX, layout.trackWidth * CGFloat(upper) / 100,
                               accuracy: 0.001)
                assertBoundLabelsFit(layout, width: width)
            }
        }
    }

    func testBothBoundsBeyondTheLimitShareAChevronAndKeepSeparateLabels() {
        let width: CGFloat = 302
        let layout = ForecastMeterLayout(width: width, projectedPercent: 125,
                                         lowerPercent: 110, upperPercent: 140)

        XCTAssertGreaterThan(layout.lowerX, layout.trackWidth)
        XCTAssertLessThanOrEqual(layout.lowerX, width)
        XCTAssertEqual(layout.upperX, layout.lowerX, accuracy: 0.001)
        XCTAssertEqual(layout.projectionX, layout.upperX, accuracy: 0.001)
        assertBoundLabelsFit(layout, width: width)
    }

    private func assertBoundLabelsFit(_ layout: ForecastMeterLayout, width: CGFloat,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let halfLabelWidth = ForecastMeterLayout.boundLabelWidth / 2
        XCTAssertGreaterThanOrEqual(layout.lowerLabelCenter - halfLabelWidth, 0,
                                   file: file, line: line)
        XCTAssertLessThanOrEqual(layout.lowerLabelCenter + halfLabelWidth, width,
                                file: file, line: line)
        XCTAssertGreaterThanOrEqual(layout.upperLabelCenter - halfLabelWidth, 0,
                                   file: file, line: line)
        XCTAssertLessThanOrEqual(layout.upperLabelCenter + halfLabelWidth, width,
                                file: file, line: line)
        XCTAssertGreaterThan(layout.upperLabelCenter - layout.lowerLabelCenter,
                             ForecastMeterLayout.boundLabelWidth, file: file, line: line)
    }
}

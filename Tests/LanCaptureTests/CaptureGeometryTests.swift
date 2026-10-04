import CoreGraphics
import XCTest

@testable import LanCapture

final class CaptureGeometryTests: XCTestCase {
    func testNarrowDisplayIsCroppedVerticallyForSixteenByNine() {
        let result = CaptureGeometry.centeredCrop(
            sourceWidth: 1440,
            sourceHeight: 900,
            targetWidth: 1920,
            targetHeight: 1080
        )

        XCTAssertEqual(result, CGRect(x: 0, y: 45, width: 1440, height: 810))
    }

    func testWideDisplayIsCroppedHorizontallyForSixteenByNine() {
        let result = CaptureGeometry.centeredCrop(
            sourceWidth: 3440,
            sourceHeight: 1440,
            targetWidth: 1920,
            targetHeight: 1080
        )

        XCTAssertEqual(result, CGRect(x: 440, y: 0, width: 2560, height: 1440))
    }

    func testMatchingAspectRatioUsesTheWholeDisplay() {
        let result = CaptureGeometry.centeredCrop(
            sourceWidth: 1920,
            sourceHeight: 1080,
            targetWidth: 1920,
            targetHeight: 1080
        )

        XCTAssertEqual(result, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testAspectFitPlacesSixteenByTenInsideSixteenByNine() {
        let result = CaptureGeometry.aspectFit(
            sourceWidth: 1440,
            sourceHeight: 900,
            targetWidth: 1920,
            targetHeight: 1080
        )

        XCTAssertEqual(result, CGRect(x: 96, y: 0, width: 1728, height: 1080))
    }
}

import CoreVideo
import XCTest

@testable import LanCapture

final class BlurredBackgroundCompositorTests: XCTestCase {
    func testBlurredBackgroundReplacesBlackSideBars() throws {
        let width = 320
        let height = 180
        var inputBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &inputBuffer
            ),
            kCVReturnSuccess
        )
        let input = try XCTUnwrap(inputBuffer)

        CVPixelBufferLockBaseAddress(input, [])
        let bytes = CVPixelBufferGetBaseAddress(input)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(input)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let isContent = (16..<304).contains(x)
                bytes[offset] = isContent ? 20 : 0
                bytes[offset + 1] = isContent ? 80 : 0
                bytes[offset + 2] = isContent ? 220 : 0
                bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(input, [])

        let compositor = try BlurredBackgroundCompositor(
            sourceWidth: 1600,
            sourceHeight: 1000,
            outputWidth: width,
            outputHeight: height
        )
        let output = try XCTUnwrap(compositor.render(input))

        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let outputBytes = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        let outputBytesPerRow = CVPixelBufferGetBytesPerRow(output)
        let cornerOffset = 5 * outputBytesPerRow + 5 * 4

        XCTAssertGreaterThan(outputBytes[cornerOffset + 2], 100)
    }
}

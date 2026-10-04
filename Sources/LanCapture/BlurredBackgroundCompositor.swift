import CoreImage
import CoreMedia
import CoreVideo
import Foundation

final class BlurredBackgroundCompositor {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let outputBounds: CGRect
    private let foregroundRect: CGRect
    private let pixelBufferPool: CVPixelBufferPool
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        outputWidth: Int,
        outputHeight: Int
    ) throws {
        outputBounds = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        foregroundRect = CaptureGeometry.aspectFit(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: CGFloat(outputWidth),
            targetHeight: CGFloat(outputHeight)
        )

        let poolAttributes =
            [
                kCVPixelBufferPoolMinimumBufferCountKey: 3
            ] as CFDictionary
        let pixelAttributes =
            [
                kCVPixelBufferWidthKey: outputWidth,
                kCVPixelBufferHeightKey: outputHeight,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ] as CFDictionary

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes,
            pixelAttributes,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw CompositorError.couldNotCreatePixelBufferPool(status)
        }
        pixelBufferPool = pool
    }

    func render(_ inputBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        var outputBuffer: CVPixelBuffer?
        guard
            CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pixelBufferPool,
                &outputBuffer
            ) == kCVReturnSuccess, let outputBuffer
        else { return nil }

        let inputImage = CIImage(cvPixelBuffer: inputBuffer)
        let contentImage =
            inputImage
            .cropped(to: foregroundRect)
            .transformed(
                by: CGAffineTransform(
                    translationX: -foregroundRect.minX,
                    y: -foregroundRect.minY
                ))

        let backgroundScale = max(
            outputBounds.width / contentImage.extent.width,
            outputBounds.height / contentImage.extent.height
        )
        let scaledBackground = contentImage.transformed(
            by: CGAffineTransform(scaleX: backgroundScale, y: backgroundScale)
        )
        let background =
            scaledBackground
            .transformed(
                by: CGAffineTransform(
                    translationX: (outputBounds.width - scaledBackground.extent.width) / 2,
                    y: (outputBounds.height - scaledBackground.extent.height) / 2
                )
            )
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 32.0])
            .cropped(to: outputBounds)

        let foregroundScale = min(
            outputBounds.width / contentImage.extent.width,
            outputBounds.height / contentImage.extent.height
        )
        let scaledForeground = contentImage.transformed(
            by: CGAffineTransform(scaleX: foregroundScale, y: foregroundScale)
        )
        let foreground = scaledForeground.transformed(
            by: CGAffineTransform(
                translationX: (outputBounds.width - scaledForeground.extent.width) / 2,
                y: (outputBounds.height - scaledForeground.extent.height) / 2
            ))

        context.render(
            foreground.composited(over: background),
            to: outputBuffer,
            bounds: outputBounds,
            colorSpace: colorSpace
        )
        return outputBuffer
    }
}

enum CompositorError: LocalizedError {
    case couldNotCreatePixelBufferPool(CVReturn)

    var errorDescription: String? {
        switch self {
        case .couldNotCreatePixelBufferPool(let status):
            "Could not allocate video compositor buffers (CVReturn \(status))."
        }
    }
}

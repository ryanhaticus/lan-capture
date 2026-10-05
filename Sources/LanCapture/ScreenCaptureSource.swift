import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

final class ScreenCaptureSource: NSObject, SCStreamOutput {
    private let configuration: StreamConfiguration
    private let encoder: H264Encoder
    private let captureQueue = DispatchQueue(label: "LanCapture.ScreenCapture")
    private var stream: SCStream?
    private var blurredBackgroundCompositor: BlurredBackgroundCompositor?

    init(configuration: StreamConfiguration, encoder: H264Encoder) {
        self.configuration = configuration
        self.encoder = encoder
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: !configuration.hideNotifications
        )
        guard let display = chooseDisplay(from: content.displays) else {
            throw CaptureError.displayNotFound(configuration.displayID)
        }

        let filter: SCContentFilter
        if configuration.hideNotifications {
            // Exclude the application so banners created after capture starts are hidden too.
            let notificationApps = content.applications.filter {
                $0.bundleIdentifier == "com.apple.notificationcenterui"
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: notificationApps,
                exceptingWindows: []
            )
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = configuration.width
        streamConfiguration.height = configuration.height
        if configuration.blurredBackground {
            blurredBackgroundCompositor = try BlurredBackgroundCompositor(
                sourceWidth: CGFloat(display.width),
                sourceHeight: CGFloat(display.height),
                outputWidth: configuration.width,
                outputHeight: configuration.height
            )
        } else {
            streamConfiguration.sourceRect = CaptureGeometry.centeredCrop(
                sourceWidth: CGFloat(display.width),
                sourceHeight: CGFloat(display.height),
                targetWidth: CGFloat(configuration.width),
                targetHeight: CGFloat(configuration.height)
            )
        }
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.fps)
        )
        streamConfiguration.queueDepth = 3
        streamConfiguration.showsCursor = !configuration.hideCursor
        streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let compositor = blurredBackgroundCompositor else {
            encoder.encode(sampleBuffer)
            return
        }
        guard let input = CMSampleBufferGetImageBuffer(sampleBuffer),
            let output = compositor.render(input)
        else { return }
        encoder.encode(
            output,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer)
        )
    }

    private func chooseDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        if let requestedID = configuration.displayID {
            return displays.first { $0.displayID == requestedID }
        }

        let mainDisplayID =
            (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber)?.uint32Value
        return displays.first { $0.displayID == mainDisplayID } ?? displays.first
    }
}

struct CaptureGeometry {
    static func centeredCrop(
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        targetWidth: CGFloat,
        targetHeight: CGFloat
    ) -> CGRect {
        guard sourceWidth > 0, sourceHeight > 0, targetWidth > 0, targetHeight > 0 else {
            return .zero
        }

        let sourceAspectRatio = sourceWidth / sourceHeight
        let targetAspectRatio = targetWidth / targetHeight

        if sourceAspectRatio > targetAspectRatio {
            let croppedWidth = sourceHeight * targetAspectRatio
            return CGRect(
                x: (sourceWidth - croppedWidth) / 2,
                y: 0,
                width: croppedWidth,
                height: sourceHeight
            )
        }

        if sourceAspectRatio < targetAspectRatio {
            let croppedHeight = sourceWidth / targetAspectRatio
            return CGRect(
                x: 0,
                y: (sourceHeight - croppedHeight) / 2,
                width: sourceWidth,
                height: croppedHeight
            )
        }

        return CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
    }

    static func aspectFit(
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        targetWidth: CGFloat,
        targetHeight: CGFloat
    ) -> CGRect {
        guard sourceWidth > 0, sourceHeight > 0, targetWidth > 0, targetHeight > 0 else {
            return .zero
        }
        let scale = min(targetWidth / sourceWidth, targetHeight / sourceHeight)
        let width = sourceWidth * scale
        let height = sourceHeight * scale
        return CGRect(
            x: (targetWidth - width) / 2,
            y: (targetHeight - height) / 2,
            width: width,
            height: height
        )
    }
}

enum CaptureError: LocalizedError {
    case displayNotFound(UInt32?)

    var errorDescription: String? {
        switch self {
        case .displayNotFound(let id?):
            return "Display \(id) was not found."
        case .displayNotFound(nil):
            return "No capturable display was found."
        }
    }
}

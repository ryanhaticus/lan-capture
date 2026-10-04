import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class H264Encoder {
    typealias OutputHandler = (Data) -> Void

    private var session: VTCompressionSession?
    private let outputHandler: OutputHandler

    init(configuration: StreamConfiguration, outputHandler: @escaping OutputHandler) throws {
        self.outputHandler = outputHandler

        var compressionSession: VTCompressionSession?
        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
            guard status == noErr,
                let refcon,
                let sampleBuffer
            else { return }
            let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
            encoder.handle(sampleBuffer)
        }

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &compressionSession
        )
        guard status == noErr, let compressionSession else {
            throw EncoderError.couldNotCreate(status)
        }
        session = compressionSession

        try set(kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        try set(kVTCompressionPropertyKey_AverageBitRate, value: configuration.bitrate as CFNumber)
        try set(
            kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: max(configuration.fps / 2, 1) as CFNumber
        )
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, value: configuration.fps as CFNumber)
        try set(
            kVTCompressionPropertyKey_DataRateLimits,
            value: [configuration.bitrate / 8, 1] as CFArray
        )

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(compressionSession)
        guard prepareStatus == noErr else {
            throw EncoderError.couldNotPrepare(prepareStatus)
        }
    }

    deinit {
        stop()
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        encode(
            imageBuffer,
            presentationTimeStamp: timestamp,
            duration: duration
        )
    }

    func encode(
        _ imageBuffer: CVImageBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime
    ) {
        guard let session else { return }
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration.isValid ? duration : .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            fputs("VideoToolbox rejected a frame (OSStatus \(status)).\n", stderr)
        }
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private func set(_ key: CFString, value: CFTypeRef) throws {
        guard let session else { return }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            throw EncoderError.couldNotSetProperty(key as String, status)
        }
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return }

        let attachments =
            CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[CFString: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil

        var output = Data()
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            appendParameterSets(from: format, to: &output)
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return }

        let bytes = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= totalLength {
            let nalLength =
                Int(bytes[offset]) << 24
                | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            offset += 4
            guard nalLength > 0, offset + nalLength <= totalLength else { return }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(bytes + offset, count: nalLength)
            offset += nalLength
        }

        if !output.isEmpty {
            outputHandler(output)
        }
    }

    private func appendParameterSets(
        from format: CMFormatDescription,
        to output: inout Data
    ) {
        var parameterSetCount = 0
        var nalHeaderLength: Int32 = 0
        let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )
        guard countStatus == noErr else { return }

        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer else { continue }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(pointer, count: size)
        }
    }
}

enum EncoderError: LocalizedError {
    case couldNotCreate(OSStatus)
    case couldNotPrepare(OSStatus)
    case couldNotSetProperty(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .couldNotCreate(let status):
            return "Could not create the H.264 encoder (OSStatus \(status))."
        case .couldNotPrepare(let status):
            return "Could not prepare the H.264 encoder (OSStatus \(status))."
        case .couldNotSetProperty(let property, let status):
            return "Could not set encoder property \(property) (OSStatus \(status))."
        }
    }
}

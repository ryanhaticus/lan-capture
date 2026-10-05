import CoreMedia
import Foundation

/// A streaming Matroska feed preserves the shared ScreenCaptureKit clock through FFmpeg.
/// Each complete sample gets its own cluster, so there is no frame-count-based video clock.
final class CaptureMuxer {
    private let configuration: StreamConfiguration
    private let output: (Data, Bool) -> Void
    private let lock = NSLock()
    private let audioConverter = AudioPCMConverter()
    private var origin: CMTime?

    init(configuration: StreamConfiguration, output: @escaping (Data, Bool) -> Void) {
        self.configuration = configuration
        self.output = output
    }

    func writeVideo(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard CMSampleBufferDataIsReady(sample),
            let format = CMSampleBufferGetFormatDescription(sample),
            let buffer = CMSampleBufferGetDataBuffer(sample)
        else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard timestamp.isNumeric else { return }
        let attachments =
            CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: false
            ) as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        if origin == nil {
            guard keyframe,
                let atoms = CMFormatDescriptionGetExtension(
                    format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
                ) as? [String: Any],
                let avcConfiguration = atoms["avcC"] as? Data
            else { return }
            origin = timestamp
            output(MatroskaWriter.header(configuration: configuration, avcConfiguration: avcConfiguration), true)
        }
        guard let ticks = relativeTimestamp(timestamp) else { return }
        let length = CMBlockBufferGetDataLength(buffer)
        guard length > 0 else { return }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                buffer, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!
            )
        }
        guard status == noErr else { return }
        output(MatroskaWriter.cluster(track: 1, timestamp: ticks, keyframe: keyframe, payload: data), false)
    }

    func writeAudio(_ sample: CMSampleBuffer) {
        guard configuration.systemAudio else { return }
        lock.lock()
        defer { lock.unlock() }
        // Audio before the first video keyframe cannot yet be described by the container header.
        guard let ticks = relativeTimestamp(CMSampleBufferGetPresentationTimeStamp(sample)),
            let data = audioConverter.convert(sample)
        else { return }
        output(MatroskaWriter.cluster(track: 2, timestamp: ticks, keyframe: true, payload: data), false)
    }

    private func relativeTimestamp(_ timestamp: CMTime) -> UInt64? {
        guard let origin, timestamp.isNumeric else { return nil }
        let relative = CMTimeSubtract(timestamp, origin)
        guard relative >= .zero else { return nil }
        return UInt64(CMTimeConvertScale(relative, timescale: 1_000, method: .roundHalfAwayFromZero).value)
    }
}

/// Minimal EBML elements for an unseekable Matroska segment (no cues or duration).
enum MatroskaWriter {
    static func header(configuration: StreamConfiguration, avcConfiguration: Data) -> Data {
        let ebml = element(
            0x1A45_DFA3,
            uint(0x4286, 1) + uint(0x42F7, 1) + uint(0x42F2, 4) + uint(0x42F3, 8)
                + string(0x4282, "matroska") + uint(0x4287, 4) + uint(0x4285, 2))
        let info = element(
            0x1549_A966,
            uint(0x2AD7B1, 1_000_000) + string(0x4D80, "LAN Capture") + string(0x5741, "LAN Capture"))
        let video = element(
            0xAE,
            uint(0xD7, 1) + uint(0x73C5, 1) + uint(0x83, 1) + uint(0x9C, 0)
                + string(0x86, "V_MPEG4/ISO/AVC") + element(0x63A2, avcConfiguration)
                + uint(0x23E383, UInt64(1_000_000_000 / configuration.fps))
                + element(0xE0, uint(0xB0, UInt64(configuration.width)) + uint(0xBA, UInt64(configuration.height))))
        var tracks = video
        if configuration.systemAudio {
            tracks += element(
                0xAE,
                uint(0xD7, 2) + uint(0x73C5, 2) + uint(0x83, 2) + uint(0x9C, 0)
                    + string(0x86, "A_PCM/INT/LIT")
                    + element(
                        0xE1,
                        element(0xB5, bytes(Double(AudioPCMConverter.sampleRate).bitPattern, count: 8))
                            + uint(0x9F, UInt64(AudioPCMConverter.channelCount)) + uint(0x6264, 16)))
        }
        // Eight-byte unknown size keeps the segment open until the input pipe closes.
        return ebml + bytes(0x1853_8067, count: 4) + Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
            + info + element(0x1654_AE6B, tracks)
    }

    static func cluster(track: UInt8, timestamp: UInt64, keyframe: Bool, payload: Data) -> Data {
        let block = Data([0x80 | track, 0, 0, keyframe ? 0x80 : 0]) + payload
        return element(0x1F43_B675, uint(0xE7, timestamp) + element(0xA3, block))
    }

    private static func string(_ id: UInt64, _ value: String) -> Data {
        element(id, Data(value.utf8))
    }

    private static func uint(_ id: UInt64, _ value: UInt64) -> Data {
        element(id, bytes(value, count: byteCount(value)))
    }

    private static func element(_ id: UInt64, _ payload: Data) -> Data {
        var sizeBytes = 1
        while UInt64(payload.count) >= (UInt64(1) << (7 * sizeBytes)) - 1 {
            sizeBytes += 1
        }
        let size = UInt64(payload.count) | (UInt64(1) << (7 * sizeBytes))
        return bytes(id, count: byteCount(id)) + bytes(size, count: sizeBytes) + payload
    }

    private static func byteCount(_ value: UInt64) -> Int {
        max(1, (64 - value.leadingZeroBitCount + 7) / 8)
    }

    private static func bytes(_ value: UInt64, count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
}

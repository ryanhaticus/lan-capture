import AVFAudio
import CoreMedia
import Foundation

/// ScreenCaptureKit supplies PCM. Normalize its layout for the Matroska audio track.
final class AudioPCMConverter {
    static let sampleRate = 48_000
    static let channelCount = 2

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(sampleRate),
        channels: AVAudioChannelCount(channelCount),
        interleaved: true
    )!
    private var converter: AVAudioConverter?

    func convert(_ sample: CMSampleBuffer) -> Data? {
        guard CMSampleBufferDataIsReady(sample),
            let description = CMSampleBufferGetFormatDescription(sample),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            let inputFormat = AVAudioFormat(streamDescription: asbd),
            inputFormat.sampleRate == outputFormat.sampleRate,
            inputFormat.channelCount == outputFormat.channelCount
        else { return nil }

        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0,
            let input = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)
            ),
            let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames)
            )
        else { return nil }
        input.frameLength = AVAudioFrameCount(frames)
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames),
                into: input.mutableAudioBufferList
            ) == noErr
        else { return nil }

        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
        do {
            try converter?.convert(to: output, from: input)
        } catch {
            fputs("Could not convert captured audio: \(error)\n", stderr)
            return nil
        }
        let buffer = output.audioBufferList.pointee.mBuffers
        guard output.frameLength > 0, let bytes = buffer.mData else { return nil }
        return Data(bytes: bytes, count: Int(buffer.mDataByteSize))
    }
}

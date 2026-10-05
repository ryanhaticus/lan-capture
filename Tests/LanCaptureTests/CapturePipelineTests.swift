import AVFAudio
import CoreMedia
import CoreVideo
import Darwin
import XCTest

@testable import LanCapture

final class CapturePipelineTests: XCTestCase {
    private let frameNumbers = [0, 1, 4, 8, 9, 14, 20, 27, 28, 36, 44, 59]

    func testPlanarAudioConvertsToInterleavedStereoPCM() throws {
        let sample = try audioSample(index: 0, constant: true)
        let data = try XCTUnwrap(AudioPCMConverter().convert(sample))
        XCTAssertEqual(data.count, 480 * 2 * 2)
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(Int(values[0]), 8_192, accuracy: 1)
        XCTAssertEqual(Int(values[1]), -16_384, accuracy: 1)
        XCTAssertEqual(values[0], values[2])
        XCTAssertEqual(values[1], values[3])
    }

    func testTimestampedFeedDecodesAndMuxesSystemAudio() throws {
        try verifyFeed(systemAudio: true)
    }

    func testVideoOnlyFeedKeepsCaptureTiming() throws {
        try verifyFeed(systemAudio: false)
    }

    func testListenerStopsWhileWaitingForReceiverWithFullBuffer() throws {
        let configuration = try StreamConfiguration.parse(
            url: "srt://127.0.0.1:\(try unusedUDPPort())?mode=listener&systemAudio=true&width=64&height=64"
        )
        let bridge = FFmpegBridge(configuration: configuration)
        do {
            try bridge.start()
        } catch {
            throw XCTSkip("FFmpeg with SRT support is required for the transport integration test.")
        }
        defer { bridge.stop() }
        let chunks = try makeFeed(configuration: configuration)
        for (data, header) in chunks { bridge.write(data, isHeader: header) }
        // Saturate the pipe while FFmpeg waits inside the SRT listener.
        let start = Date()
        for _ in 0..<100 {
            for (data, header) in chunks where !header { bridge.write(data) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        bridge.stop()
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testSystemAudioAndVideoCrossAnSRTConnection() throws {
        let ffmpeg: URL
        do {
            ffmpeg = try FFmpegLocator.find()
        } catch {
            throw XCTSkip("FFmpeg with SRT support is required for the transport integration test.")
        }
        let port = try unusedUDPPort()
        let configuration = try StreamConfiguration.parse(
            url: "srt://127.0.0.1:\(port)?mode=listener&latency=20000&systemAudio=true&width=64&height=64"
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("received.ts")
        let bridge = FFmpegBridge(configuration: configuration)
        try bridge.start()
        defer { bridge.stop() }
        for (data, header) in try makeFeed(configuration: configuration) {
            bridge.write(data, isHeader: header)
        }
        let receiver = Process()
        receiver.executableURL = ffmpeg
        receiver.arguments = [
            "-v", "error", "-analyzeduration", "100000", "-probesize", "32768", "-f", "mpegts",
            "-i", "srt://127.0.0.1:\(port)?mode=caller&latency=20000&connect_timeout=5000&timeout=5000000",
            "-t", "0.5", "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", output.path,
        ]
        receiver.standardOutput = FileHandle.nullDevice
        receiver.standardError = FileHandle.standardError
        let finished = expectation(description: "SRT receiver receives both tracks")
        receiver.terminationHandler = { _ in finished.fulfill() }
        try receiver.run()
        defer {
            if receiver.isRunning { receiver.terminate() }
        }
        wait(for: [finished], timeout: 15)
        guard !receiver.isRunning else { return }
        XCTAssertEqual(receiver.terminationStatus, 0)
        let probe = try run(
            ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe"),
            [
                "-v", "error", "-show_streams", "-of", "json", output.path,
            ])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: probe) as? [String: Any])
        let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
        XCTAssertEqual(streams.compactMap { $0["codec_name"] as? String }, ["h264", "aac"])
        _ = try run(ffmpeg, ["-v", "error", "-xerror", "-i", output.path, "-f", "null", "-"])
    }

    private func unusedUDPPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard Darwin.bind(descriptor, socketAddress, length) == 0,
                    getsockname(descriptor, socketAddress, &length) == 0
                else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    private func verifyFeed(systemAudio: Bool) throws {
        let ffmpeg: URL
        do {
            ffmpeg = try FFmpegLocator.find()
        } catch {
            throw XCTSkip("FFmpeg with SRT support is required for the pipeline integration test.")
        }
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path) else {
            throw XCTSkip("ffprobe is required for the pipeline integration test.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("capture.mkv")
        let output = directory.appendingPathComponent("stream.ts")
        let configuration = try StreamConfiguration.parse(
            url: "srt://localhost:9000?width=64&height=64&systemAudio=\(systemAudio)"
        )
        let feed = try makeFeed(configuration: configuration).reduce(into: Data()) { $0.append($1.0) }
        try feed.write(to: input)

        var arguments = FFmpegBridge.arguments(configuration: configuration)
        arguments[try XCTUnwrap(arguments.firstIndex(of: "pipe:0"))] = input.path
        arguments[arguments.count - 1] = output.path
        _ = try run(ffmpeg, arguments)
        let probe = try run(
            ffprobe,
            [
                "-v", "error", "-show_streams", "-show_packets", "-of", "json", output.path,
            ])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: probe) as? [String: Any])
        let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
        XCTAssertEqual(streams.count, systemAudio ? 2 : 1)
        XCTAssertEqual(streams[0]["codec_name"] as? String, "h264")
        if systemAudio {
            XCTAssertEqual(streams[1]["codec_name"] as? String, "aac")
            XCTAssertEqual(streams[1]["sample_rate"] as? String, "48000")
            XCTAssertEqual(streams[1]["channels"] as? Int, 2)
        }
        let packets = try XCTUnwrap(json["packets"] as? [[String: Any]])
        let videoTimes = packets.filter { $0["codec_type"] as? String == "video" }.compactMap {
            ($0["pts_time"] as? String).flatMap(Double.init)
        }
        XCTAssertEqual(videoTimes.count, frameNumbers.count)
        for index in 1..<min(videoTimes.count, frameNumbers.count) {
            let expected = Double(frameNumbers[index] - frameNumbers[0]) / 60
            XCTAssertEqual(videoTimes[index] - videoTimes[0], expected, accuracy: 0.0011)
        }
        // Decode both tracks: a valid header alone does not prove the packet layout is correct.
        _ = try run(ffmpeg, ["-v", "error", "-xerror", "-i", output.path, "-f", "null", "-"])
        if systemAudio {
            let pcm = try run(
                ffmpeg,
                [
                    "-v", "error", "-i", output.path, "-map", "0:a:0", "-f", "f32le", "pipe:1",
                ])
            let values = pcm.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            XCTAssertGreaterThan(values.count, 90_000)
            let peak = values.map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.1, "The AAC track must contain the captured audio.")
            let audioTimes = packets.filter { $0["codec_type"] as? String == "audio" }.compactMap {
                ($0["pts_time"] as? String).flatMap(Double.init)
            }
            XCTAssertLessThan(abs(try XCTUnwrap(audioTimes.first) - videoTimes[0]), 0.025)
        }
    }

    private func makeFeed(configuration: StreamConfiguration) throws -> [(Data, Bool)] {
        var chunks: [(Data, Bool)] = []
        let muxer = CaptureMuxer(configuration: configuration) { data, isHeader in chunks.append((data, isHeader)) }
        let samples = try videoSamples(configuration: configuration)
        // Audio arriving before the first video keyframe is safely ignored.
        muxer.writeAudio(try audioSample(index: 0))
        var nextVideo = 0
        for audioIndex in 0..<100 {
            let audioTime = Double(audioIndex) / 100
            while nextVideo < samples.count,
                Double(frameNumbers[nextVideo]) / 60 <= audioTime
            {
                muxer.writeVideo(samples[nextVideo])
                nextVideo += 1
            }
            muxer.writeAudio(try audioSample(index: audioIndex))
        }
        XCTAssertEqual(nextVideo, frameNumbers.count)
        XCTAssertFalse(chunks.isEmpty, "The VideoToolbox avcC configuration must create a Matroska header.")
        return chunks
    }

    private func videoSamples(configuration: StreamConfiguration) throws -> [CMSampleBuffer] {
        var samples: [CMSampleBuffer] = []
        let lock = NSLock()
        let encoder = try H264Encoder(configuration: configuration) { sample in
            lock.lock()
            samples.append(sample)
            lock.unlock()
        }
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer
            ), kCVReturnSuccess)
        let image = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 128, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        for frame in frameNumbers {
            encoder.encode(
                image, presentationTimeStamp: CMTime(value: Int64(6_000 + frame), timescale: 60),
                duration: CMTime(value: 1, timescale: 60))
        }
        encoder.stop()
        XCTAssertEqual(samples.count, frameNumbers.count)
        return samples
    }

    private func audioSample(index: Int, constant: Bool = false) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        pcm.frameLength = 480
        let channels = try XCTUnwrap(pcm.floatChannelData)
        for frame in 0..<480 {
            let value = Float(sin(Double(index * 480 + frame) * 2 * .pi * 440 / 48_000)) * 0.25
            channels[0][frame] = constant ? 0.25 : value
            channels[1][frame] = constant ? -0.5 : -value
        }
        var description: CMAudioFormatDescription?
        XCTAssertEqual(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0,
                layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: Int64(10_000 + index), timescale: 100),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
                sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        XCTAssertEqual(
            CMSampleBufferSetDataBufferFromAudioBufferList(
                result, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        return result
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, error)
        return data
    }
}

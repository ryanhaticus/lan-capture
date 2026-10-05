import Darwin
import Foundation

final class FFmpegBridge {
    private struct Chunk {
        let data: Data
        let isHeader: Bool
        var offset = 0
    }

    private let process = Process()
    private let inputPipe = Pipe()
    private let configuration: StreamConfiguration
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "LanCapture.FFmpegInput")
    private var writeSource: DispatchSourceWrite?
    private var sourceSuspended = false
    private var pending: [Chunk] = []
    private var pendingBytes = 0
    private var stopped = false
    private static let maximumPendingBytes = 2 * 1_024 * 1_024

    init(configuration: StreamConfiguration) {
        self.configuration = configuration
    }

    static func arguments(configuration: StreamConfiguration) -> [String] {
        var arguments = [
            "-hide_banner",
            "-loglevel", "warning",
            "-flags", "low_delay",
            "-analyzeduration", "0",
            "-probesize", "32",
            "-f", "matroska",
            "-i", "pipe:0",
            "-map", "0:v:0",
            "-c:v", "copy",
        ]
        if configuration.systemAudio {
            arguments += [
                "-map", "0:a:0",
                "-c:a", "aac",
                "-b:a", "192k",
                "-af", "aresample=async=1:first_pts=0",
            ]
        } else {
            arguments += ["-an"]
        }
        arguments += [
            // AAC priming starts before the first video sample. Shift both tracks together
            // so MPEG-TS never wraps a negative timestamp around its 33-bit clock.
            // This changes timestamp values, not buffering or playback latency.
            "-output_ts_offset", "0.1",
            "-max_interleave_delta", "100000",
            "-max_delay", "0",
            "-muxdelay", "0",
            "-muxpreload", "0",
            "-flush_packets", "1",
            "-mpegts_flags", "+resend_headers",
            "-f", "mpegts",
            configuration.transportURL.absoluteString,
        ]
        return arguments
    }

    func start() throws {
        process.executableURL = try FFmpegLocator.find()
        process.arguments = Self.arguments(configuration: configuration)
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()

        let handle = inputPipe.fileHandleForWriting
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        // Report a broken pipe as an error rather than terminating the application.
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: writeQueue)
        source.setEventHandler { [weak self] in self?.flush() }
        source.setCancelHandler { try? handle.close() }
        lock.lock()
        writeSource = source
        sourceSuspended = true
        lock.unlock()
        // A dispatch source starts suspended; the first packet resumes it.
    }

    func write(_ data: Data, isHeader: Bool = false) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let writeSource else { return }
        pending.append(Chunk(data: data, isHeader: isHeader))
        pendingBytes += data.count
        // A listener can wait indefinitely for a receiver. Keep capture callbacks responsive
        // and bound memory by discarding whole, unsent clusters. Never truncate a cluster.
        while pendingBytes > Self.maximumPendingBytes,
            let index = pending.firstIndex(where: { !$0.isHeader && $0.offset == 0 })
        {
            pendingBytes -= pending.remove(at: index).data.count
        }
        if sourceSuspended {
            sourceSuspended = false
            writeSource.resume()
        }
    }

    private func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let writeSource else { return }
        while let chunk = pending.first {
            let written = chunk.data.withUnsafeBytes { bytes in
                Darwin.write(
                    inputPipe.fileHandleForWriting.fileDescriptor,
                    bytes.baseAddress!.advanced(by: chunk.offset), bytes.count - chunk.offset
                )
            }
            if written < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    fputs("Could not write captured media to FFmpeg (errno \(errno)).\n", stderr)
                    pending.removeAll()
                    pendingBytes = 0
                    writeSource.suspend()
                    sourceSuspended = true
                }
                return
            }
            guard written > 0 else { return }
            pendingBytes -= written
            pending[0].offset += written
            if pending[0].offset == chunk.data.count {
                pending.removeFirst()
            }
        }
        writeSource.suspend()
        sourceSuspended = true
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        pending.removeAll()
        pendingBytes = 0
        if let source = writeSource {
            if sourceSuspended { source.resume() }
            source.cancel()
            writeSource = nil
        } else {
            try? inputPipe.fileHandleForWriting.close()
        }
        lock.unlock()

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}

struct FFmpegLocator {
    static let overrideEnvironmentKey = "LANCAPTURE_FFMPEG_PATH"

    static func find(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shell: ((String) -> String?)? = nil
    ) throws -> URL {
        let shell = shell ?? runInLoginShell
        var candidates: [String] = []

        if let override = environment[overrideEnvironmentKey], !override.isEmpty {
            candidates.append(override)
        }

        if let path = environment["PATH"] {
            candidates.append(
                contentsOf:
                    path
                    .split(separator: ":")
                    .map { String($0) + "/ffmpeg" })
        }

        if let shellPath = shell("command -v ffmpeg") {
            candidates.append(shellPath)
        }

        for formula in ["ffmpeg-full", "ffmpeg"] {
            if let prefix = shell("brew --prefix \(formula)") {
                candidates.append(prefix + "/bin/ffmpeg")
            }
        }

        var visited = Set<String>()
        for path in candidates where visited.insert(path).inserted {
            if FileManager.default.isExecutableFile(atPath: path), supportsSRT(at: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw FFmpegError.notInstalled
    }

    static func supportsSRT(at path: String) -> Bool {
        let probe = Process()
        let output = Pipe()
        probe.executableURL = URL(fileURLWithPath: path)
        probe.arguments = ["-hide_banner", "-protocols"]
        probe.standardOutput = output
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let protocols = String(data: data, encoding: .utf8) else { return false }
            return protocols.split(whereSeparator: \.isWhitespace).contains("srt")
        } catch {
            return false
        }
    }

    private static func runInLoginShell(_ command: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)
        } catch {
            return nil
        }
    }
}

enum FFmpegError: LocalizedError {
    case notInstalled

    var errorDescription: String? {
        "FFmpeg with SRT support was not found. Install ffmpeg-full as described in the README, or set LANCAPTURE_FFMPEG_PATH."
    }
}

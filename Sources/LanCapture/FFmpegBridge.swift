import Foundation

final class FFmpegBridge {
    private let process = Process()
    private let inputPipe = Pipe()
    private let configuration: StreamConfiguration
    private let lock = NSLock()
    private var stopped = false

    init(configuration: StreamConfiguration) {
        self.configuration = configuration
    }

    func start() throws {
        process.executableURL = try FFmpegLocator.find()
        process.arguments = [
            "-hide_banner",
            "-loglevel", "warning",
            "-fflags", "nobuffer",
            "-flags", "low_delay",
            "-analyzeduration", "0",
            "-probesize", "32",
            "-f", "h264",
            "-framerate", String(configuration.fps),
            "-i", "pipe:0",
            "-an",
            "-c:v", "copy",
            "-max_delay", "0",
            "-muxdelay", "0",
            "-muxpreload", "0",
            "-flush_packets", "1",
            "-mpegts_flags", "+resend_headers",
            "-f", "mpegts",
            configuration.transportURL.absoluteString,
        ]
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
    }

    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            fputs("Could not write encoded video to FFmpeg: \(error)\n", stderr)
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        try? inputPipe.fileHandleForWriting.close()
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

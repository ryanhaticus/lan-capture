import Foundation
import XCTest

@testable import LanCapture

final class FFmpegLocatorTests: XCTestCase {
    func testExplicitOverrideFindsAnSRTCapableExecutable() throws {
        let executable = try makeFakeFFmpeg(protocols: ["srt", "tcp", "udp"])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let result = try FFmpegLocator.find(
            environment: [FFmpegLocator.overrideEnvironmentKey: executable.path],
            shell: { _ in nil }
        )

        XCTAssertEqual(result.path, executable.path)
    }

    func testExecutableWithoutSRTIsRejected() throws {
        let executable = try makeFakeFFmpeg(protocols: ["tcp", "udp"])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        XCTAssertThrowsError(
            try FFmpegLocator.find(
                environment: [FFmpegLocator.overrideEnvironmentKey: executable.path],
                shell: { _ in nil }
            )
        )
    }

    private func makeFakeFFmpeg(protocols: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("ffmpeg")
        let output = protocols.map { "  \($0)" }.joined(separator: "\n")
        let script = "#!/bin/sh\nprintf '\(output)\n'\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }
}

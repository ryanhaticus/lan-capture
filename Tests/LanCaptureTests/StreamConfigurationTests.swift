import XCTest

@testable import LanCapture

final class StreamConfigurationTests: XCTestCase {
    func testCustomVideoOptionsAreRemovedFromTransportURL() throws {
        let configuration = try StreamConfiguration.parse(
            url:
                "srt://192.168.1.20:9000?mode=caller&latency=40000&width=2560&height=1440&fps=60&bitrate=30000000&blurBackground=true&hideCursor=true&hideNotifications=true&systemAudio=true",
        )

        XCTAssertEqual(configuration.width, 2560)
        XCTAssertEqual(configuration.height, 1440)
        XCTAssertEqual(configuration.fps, 60)
        XCTAssertEqual(configuration.bitrate, 30_000_000)
        XCTAssertTrue(configuration.blurredBackground)
        XCTAssertTrue(configuration.hideCursor)
        XCTAssertTrue(configuration.hideNotifications)
        XCTAssertTrue(configuration.systemAudio)
        XCTAssertEqual(
            configuration.transportURL.absoluteString,
            "srt://192.168.1.20:9000?mode=caller&latency=40000"
        )
    }

    func testDefaults() throws {
        let configuration = try StreamConfiguration.parse(url: "srt://localhost:9000")

        XCTAssertEqual(configuration.width, 1920)
        XCTAssertEqual(configuration.height, 1080)
        XCTAssertEqual(configuration.fps, 60)
        XCTAssertEqual(configuration.bitrate, 20_000_000)
        XCTAssertFalse(configuration.blurredBackground)
        XCTAssertFalse(configuration.hideCursor)
        XCTAssertFalse(configuration.hideNotifications)
        XCTAssertFalse(configuration.systemAudio)
    }

    func testSystemAudioBooleanValidation() throws {
        for value in ["true", "1", "yes", "on"] {
            XCTAssertTrue(try StreamConfiguration.parse(url: "srt://localhost:9000?systemAudio=\(value)").systemAudio)
        }
        for value in ["false", "0", "no", "off"] {
            XCTAssertFalse(try StreamConfiguration.parse(url: "srt://localhost:9000?systemAudio=\(value)").systemAudio)
        }
        XCTAssertThrowsError(try StreamConfiguration.parse(url: "srt://localhost:9000?systemAudio=maybe"))
    }

    func testDimensionsMustBeEven() {
        XCTAssertThrowsError(
            try StreamConfiguration.parse(url: "srt://localhost:9000?width=1919")
        )
    }
}

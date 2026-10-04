import AppKit
import Foundation
import SwiftUI

@MainActor
final class StreamController: ObservableObject {
    enum State {
        case stopped
        case starting
        case streaming
        case stopping
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var localAddress = LocalNetworkAddress.current()
    @Published var errorMessage: String?

    @Published var listenPort: Int {
        didSet { defaults.set(listenPort, forKey: Keys.listenPort) }
    }
    @Published var width: Int {
        didSet { defaults.set(width, forKey: Keys.width) }
    }
    @Published var height: Int {
        didSet { defaults.set(height, forKey: Keys.height) }
    }
    @Published var fps: Int {
        didSet { defaults.set(fps, forKey: Keys.fps) }
    }
    @Published var bitrateMbps: Int {
        didSet { defaults.set(bitrateMbps, forKey: Keys.bitrateMbps) }
    }
    @Published var blurredBackground: Bool {
        didSet { defaults.set(blurredBackground, forKey: Keys.blurredBackground) }
    }

    private let defaults: UserDefaults
    private var ffmpeg: FFmpegBridge?
    private var encoder: H264Encoder?
    private var capture: ScreenCaptureSource?
    private var networkTimer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        listenPort = defaults.object(forKey: Keys.listenPort) as? Int ?? 9000
        width = defaults.object(forKey: Keys.width) as? Int ?? StreamConfiguration.defaultWidth
        height = defaults.object(forKey: Keys.height) as? Int ?? StreamConfiguration.defaultHeight
        fps = defaults.object(forKey: Keys.fps) as? Int ?? StreamConfiguration.defaultFPS
        bitrateMbps = defaults.object(forKey: Keys.bitrateMbps) as? Int ?? 20
        blurredBackground = defaults.object(forKey: Keys.blurredBackground) as? Bool ?? false

        networkTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLocalIPAddress()
            }
        }
    }

    var isActive: Bool { state != .stopped }
    var canEditSettings: Bool { state == .stopped }

    var statusText: String {
        switch state {
        case .stopped: "Stopped"
        case .starting: "Opening network stream…"
        case .streaming: "Ready for OBS on port \(listenPort)"
        case .stopping: "Stopping…"
        }
    }

    var obsInputURL: String {
        "srt://\(localAddress.address):\(listenPort)?latency=20000"
    }

    var statusColor: Color {
        switch state {
        case .stopped: .secondary
        case .starting, .stopping: .orange
        case .streaming: .green
        }
    }

    func start() {
        guard state == .stopped else { return }
        errorMessage = nil

        do {
            let configuration = try makeConfiguration()
            state = .starting

            let ffmpeg = FFmpegBridge(configuration: configuration)
            let encoder = try H264Encoder(configuration: configuration) { [weak ffmpeg] data in
                ffmpeg?.write(data)
            }
            let capture = ScreenCaptureSource(configuration: configuration, encoder: encoder)
            self.ffmpeg = ffmpeg
            self.encoder = encoder
            self.capture = capture

            Task {
                do {
                    try ffmpeg.start()
                    try await capture.start()
                    guard state == .starting else {
                        await stopResources()
                        return
                    }
                    state = .streaming
                } catch {
                    await stopResources()
                    errorMessage = friendlyMessage(for: error)
                    state = .stopped
                }
            }
        } catch {
            errorMessage = friendlyMessage(for: error)
            state = .stopped
        }
    }

    func stop() {
        guard state != .stopped, state != .stopping else { return }
        state = .stopping
        Task {
            await stopResources()
            state = .stopped
        }
    }

    func quit() {
        Task {
            if state != .stopped {
                state = .stopping
                await stopResources()
            }
            NSApplication.shared.terminate(nil)
        }
    }

    func refreshLocalIPAddress() {
        localAddress = LocalNetworkAddress.current()
    }

    func copyLocalIPAddress() {
        guard localAddress.address != "Unavailable" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(localAddress.address, forType: .string)
    }

    func copyOBSInputURL() {
        guard localAddress.address != "Unavailable" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(obsInputURL, forType: .string)
    }

    private func makeConfiguration() throws -> StreamConfiguration {
        guard (1...65_535).contains(listenPort) else {
            throw MenuBarConfigurationError.invalidPort
        }
        guard (1...1_000).contains(bitrateMbps) else {
            throw MenuBarConfigurationError.invalidBitrate
        }

        var components = URLComponents()
        components.scheme = "srt"
        components.host = "0.0.0.0"
        components.port = listenPort
        components.queryItems = [
            URLQueryItem(name: "mode", value: "listener"),
            URLQueryItem(name: "latency", value: "20000"),
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "fps", value: String(fps)),
            URLQueryItem(name: "bitrate", value: String(bitrateMbps * 1_000_000)),
            URLQueryItem(name: "blurBackground", value: blurredBackground ? "true" : "false"),
        ]
        guard let url = components.url else {
            throw MenuBarConfigurationError.invalidListenerAddress
        }
        return try StreamConfiguration.parse(url: url.absoluteString)
    }

    private func stopResources() async {
        await capture?.stop()
        capture = nil
        encoder?.stop()
        encoder = nil
        ffmpeg?.stop()
        ffmpeg = nil
    }

    private func friendlyMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("TCC")
            || message.localizedCaseInsensitiveContains("declined")
        {
            return
                "Allow LAN Capture in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        }
        return message
    }

    private enum Keys {
        // Keep the original storage key so existing installations retain their port.
        static let listenPort = "destinationPort"
        static let width = "width"
        static let height = "height"
        static let fps = "fps"
        static let bitrateMbps = "bitrateMbps"
        static let blurredBackground = "blurredBackground"
    }
}

enum MenuBarConfigurationError: LocalizedError {
    case invalidListenerAddress
    case invalidPort
    case invalidBitrate

    var errorDescription: String? {
        switch self {
        case .invalidListenerAddress:
            "The SRT listener address is not valid."
        case .invalidPort:
            "The port must be between 1 and 65535."
        case .invalidBitrate:
            "The bitrate must be between 1 and 1000 Mbps."
        }
    }
}

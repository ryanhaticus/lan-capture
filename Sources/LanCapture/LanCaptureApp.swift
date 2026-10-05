import AppKit
import SwiftUI

@main
struct LanCaptureApp: App {
    @NSApplicationDelegateAdaptor(LanCaptureAppDelegate.self) private var appDelegate
    @StateObject private var controller = StreamController()

    var body: some Scene {
        MenuBarExtra(
            "LAN Capture",
            systemImage: "rectangle.on.rectangle"
        ) {
            MenuBarView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }
}

final class LanCaptureAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}

private struct MenuBarView: View {
    @EnvironmentObject private var controller: StreamController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            networkSection
            Divider()
            obsSection
            videoSection
            audioSection

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            controls
        }
        .padding(16)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("LAN Capture")
                    .font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(controller.statusColor)
                        .frame(width: 7, height: 7)
                    Text(controller.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("THIS MAC")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.localAddress.address)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text(controller.localAddress.interfaceDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    controller.copyLocalIPAddress()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy IP address")
                .disabled(controller.localAddress.address == "Unavailable")

                Button {
                    controller.refreshLocalIPAddress()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh IP address")
            }
        }
    }

    private var obsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("OBS MEDIA SOURCE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                Text(controller.obsInputURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    controller.copyOBSInputURL()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy OBS input URL")
                .disabled(controller.localAddress.address == "Unavailable")
            }
            HStack {
                Text("Listen port")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Port", value: $controller.listenPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                    .disabled(!controller.canEditSettings)
            }
            Text("Input Format: mpegts  •  Network Buffering: 0 MB")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("VIDEO")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                numericField("Width", value: $controller.width)
                Text("×").foregroundStyle(.secondary)
                numericField("Height", value: $controller.height)
                Text("at").foregroundStyle(.secondary)
                numericField("FPS", value: $controller.fps, width: 58)
            }
            HStack {
                Text("Bitrate")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Mbps", value: $controller.bitrateMbps, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 68)
                Text("Mbps")
                    .foregroundStyle(.secondary)
            }
            Toggle("Blur background instead of cropping", isOn: $controller.blurredBackground)
                .toggleStyle(.checkbox)
            Toggle("Hide mouse cursor in stream", isOn: $controller.hideCursor)
                .toggleStyle(.checkbox)
            Toggle("Hide notifications in stream", isOn: $controller.hideNotifications)
                .toggleStyle(.checkbox)
                .help("Hide macOS notification banners and Notification Center from the stream.")
        }
        .disabled(!controller.canEditSettings)
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("AUDIO")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle("Stream system audio", isOn: $controller.systemAudio)
                .toggleStyle(.checkbox)
                .help("Send audio from Mac apps with the video. Microphone audio is excluded.")
        }
        .disabled(!controller.canEditSettings)
    }

    private func numericField(
        _ title: String,
        value: Binding<Int>,
        width: CGFloat = 76
    ) -> some View {
        TextField(title, value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
    }

    private var controls: some View {
        HStack {
            Button("Quit") {
                controller.quit()
            }
            .keyboardShortcut("q")

            Spacer()

            if controller.isActive {
                Button("Stop Stream", role: .destructive) {
                    controller.stop()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Start Stream") {
                    controller.start()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

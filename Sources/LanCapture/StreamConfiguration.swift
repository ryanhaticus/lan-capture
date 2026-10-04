import Foundation

struct StreamConfiguration: Equatable {
    static let defaultWidth = 1920
    static let defaultHeight = 1080
    static let defaultFPS = 60
    static let defaultBitrate = 20_000_000

    let transportURL: URL
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    let displayID: UInt32?
    let blurredBackground: Bool

    static func parse(url rawURL: String) throws -> StreamConfiguration {
        guard var components = URLComponents(string: rawURL),
            components.scheme == "srt",
            components.host != nil,
            components.port != nil
        else {
            throw ConfigurationError.invalidURL(rawURL)
        }

        var appOptions: [String: String] = [:]
        let appOptionNames = Set([
            "width", "height", "fps", "bitrate", "display", "blurbackground",
        ])
        components.queryItems = components.queryItems?.filter { item in
            if appOptionNames.contains(item.name.lowercased()) {
                appOptions[item.name.lowercased()] = item.value
                return false
            }
            return true
        }

        guard let transportURL = components.url else {
            throw ConfigurationError.invalidURL(rawURL)
        }

        let width = try positiveInteger(appOptions["width"], named: "width", default: defaultWidth)
        let height = try positiveInteger(appOptions["height"], named: "height", default: defaultHeight)
        let fps = try positiveInteger(appOptions["fps"], named: "fps", default: defaultFPS)
        let bitrate = try positiveInteger(appOptions["bitrate"], named: "bitrate", default: defaultBitrate)
        let blurredBackground = try boolean(
            appOptions["blurbackground"],
            named: "blurBackground",
            default: false
        )

        guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw ConfigurationError.invalidValue("width and height must both be even")
        }
        guard (1...240).contains(fps) else {
            throw ConfigurationError.invalidValue("fps must be between 1 and 240")
        }

        let displayID: UInt32?
        if let rawDisplay = appOptions["display"] {
            guard let parsed = UInt32(rawDisplay) else {
                throw ConfigurationError.invalidValue("display must be a numeric display ID")
            }
            displayID = parsed
        } else {
            displayID = nil
        }

        return StreamConfiguration(
            transportURL: transportURL,
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate,
            displayID: displayID,
            blurredBackground: blurredBackground
        )
    }

    private static func positiveInteger(
        _ rawValue: String?,
        named name: String,
        default defaultValue: Int
    ) throws -> Int {
        guard let rawValue else { return defaultValue }
        guard let value = Int(rawValue), value > 0 else {
            throw ConfigurationError.invalidValue("\(name) must be a positive integer")
        }
        return value
    }

    private static func boolean(
        _ rawValue: String?,
        named name: String,
        default defaultValue: Bool
    ) throws -> Bool {
        guard let rawValue else { return defaultValue }
        switch rawValue.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            throw ConfigurationError.invalidValue("\(name) must be true or false")
        }
    }
}

enum ConfigurationError: LocalizedError, Equatable {
    case invalidURL(String)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "Invalid SRT URL: \(value)"
        case .invalidValue(let message):
            return "Invalid stream option: \(message)."
        }
    }
}

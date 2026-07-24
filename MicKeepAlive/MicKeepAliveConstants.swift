import Foundation

enum MicKeepAliveConstants {
    static let bundleIdentifier = "com.example.MicKeepAlive"

    // Darwin notify center 命令名（跨进程通知，比 DistributedNotificationCenter 更可靠）
    static let commandStartName = "\(bundleIdentifier).command.start"
    static let commandStopName = "\(bundleIdentifier).command.stop"
    static let commandToggleName = "\(bundleIdentifier).command.toggle"

    static let stateFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MicKeepAlive/state.json")
}

enum MicKeepAliveCommand: String {
    case start
    case stop
    case toggle
}

struct MicKeepAliveState: Codable {
    var keepingAlive: Bool
    var defaultInputDeviceID: UInt32?
    var defaultInputDeviceName: String?
    var timestamp: Date
}

import Foundation

final class StateStore {
    static let shared = StateStore()

    private var url: URL { MicKeepAliveConstants.stateFileURL }

    func save(keepingAlive: Bool) {
        let defaultID = AudioDeviceUtils.defaultInputDevice()
        let state = MicKeepAliveState(
            keepingAlive: keepingAlive,
            defaultInputDeviceID: defaultID,
            defaultInputDeviceName: defaultID.flatMap { AudioDeviceUtils.deviceName(deviceID: $0) },
            timestamp: Date()
        )
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url)
        } catch {
            // 静默忽略，状态文件不是关键路径
        }
    }

    func load() -> MicKeepAliveState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MicKeepAliveState.self, from: data)
    }
}

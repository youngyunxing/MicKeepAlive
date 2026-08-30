import Foundation
import CoreAudio
import CoreFoundation
import AVFoundation

enum CLIError: Error, LocalizedError {
    case unknownCommand
    case missingArgument(String)
    case deviceNotFound(String)
    case invalidLaunchAtLoginValue(String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand: return "未知命令"
        case .missingArgument(let arg): return "缺少参数: \(arg)"
        case .deviceNotFound(let name): return "未找到设备: \(name)"
        case .invalidLaunchAtLoginValue(let value): return "无效值: \(value)，请用 on 或 off"
        }
    }
}

struct CLICommands {
    func run(arguments: [String]) throws {
        let args = Array(arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }

        switch command {
        case "status": try status()
        case "list": try list()
        case "start": try start()
        case "stop": try stop()
        case "toggle": try toggle()
        case "probe": try probe()
        case "set-device": try setDevice(args: Array(args.dropFirst()))
        case "launch-at-login": try launchAtLogin(args: Array(args.dropFirst()))
        case "help", "-h", "--help": printUsage()
        default: throw CLIError.unknownCommand
        }
    }

    func printUsage() {
        print("""
        mkctl — MicKeepAlive 命令行工具

        用法:
          mkctl status              查看运行状态与当前默认麦克风
          mkctl list                列出可用输入麦克风
          mkctl probe               采集 2 秒默认麦克风声音并输出电平（供 App 探针验证）
          mkctl start               启动/恢复保活
          mkctl stop                停止保活
          mkctl toggle              切换保活状态
          mkctl set-device <名称或ID>  设置默认输入麦克风
          mkctl launch-at-login on  开启开机自启
          mkctl launch-at-login off 关闭开机自启
          mkctl help                显示此帮助
        """)
    }

    func status() throws {
        let isRunning = isAppRunning()
        let defaultID = AudioDeviceUtils.defaultInputDevice()
        let defaultName = defaultID.flatMap { AudioDeviceUtils.deviceName(deviceID: $0) } ?? "unknown"

        var keepingAlive: Bool? = nil
        if let data = try? Data(contentsOf: MicKeepAliveConstants.stateFileURL),
           let state = try? JSONDecoder().decode(MicKeepAliveState.self, from: data) {
            keepingAlive = state.keepingAlive
        }

        print("app_running: \(isRunning)")
        if let keepingAlive = keepingAlive {
            print("keeping_alive: \(keepingAlive)")
        }
        print("default_input_device: \(defaultName)")
        if let id = defaultID {
            print("default_input_device_id: \(id)")
        }
    }

    func list() throws {
        let devices = AudioDeviceUtils.availableInputDevices()
        for device in devices {
            let marker = device.id == AudioDeviceUtils.defaultInputDevice() ? " *" : ""
            print("\(device.id)\t\(device.name)\(marker)")
        }
    }

    func start() throws {
        ensureAppRunning()
        sendCommand(.start)
    }

    func stop() throws {
        sendCommand(.stop)
    }

    func toggle() throws {
        sendCommand(.toggle)
    }

    /// 探针：全新进程采集 2 秒默认输入设备声音，输出归一化电平（0~1）。
    /// 供 App 在设备事件后验证重建是否真的恢复（新进程 = 新 CoreAudio 连接，能看到真实设备）。
    func probe() throws {
        let level = AudioProbe.captureLevel(duration: 2.0)
        print("level=\(String(format: "%.3f", level))")
    }

    func setDevice(args: [String]) throws {
        guard let name = args.first else { throw CLIError.missingArgument("device name or id") }
        let devices = AudioDeviceUtils.availableInputDevices()

        if let id = UInt32(name), let device = devices.first(where: { $0.id == id }) {
            AudioDeviceUtils.setDefaultInputDevice(device.id)
            print("已设置默认输入设备为: \(device.name)")
        } else if let device = devices.first(where: { $0.name == name }) {
            AudioDeviceUtils.setDefaultInputDevice(device.id)
            print("已设置默认输入设备为: \(device.name)")
        } else {
            throw CLIError.deviceNotFound(name)
        }
    }

    func launchAtLogin(args: [String]) throws {
        guard let value = args.first else { throw CLIError.missingArgument("on/off") }
        switch value.lowercased() {
        case "on", "true", "1":
            let result = writeLaunchAgent(enabled: true)
            print(result ? "开机自启已开启" : "开启失败")
        case "off", "false", "0":
            let result = writeLaunchAgent(enabled: false)
            print(result ? "开机自启已关闭" : "关闭失败")
        default:
            throw CLIError.invalidLaunchAtLoginValue(value)
        }
    }

    // MARK: - Helpers

    private func sendCommand(_ command: MicKeepAliveCommand) {
        let name: String
        switch command {
        case .start:
            name = MicKeepAliveConstants.commandStartName
        case .stop:
            name = MicKeepAliveConstants.commandStopName
        case .toggle:
            name = MicKeepAliveConstants.commandToggleName
        }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }

    private func isAppRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "MicKeepAlive"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func ensureAppRunning() {
        guard !isAppRunning() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["/Applications/MicKeepAlive.app"]
        try? process.run()
    }

    private func writeLaunchAgent(enabled: Bool) -> Bool {
        let label = MicKeepAliveConstants.bundleIdentifier
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let executablePath = "/Applications/MicKeepAlive.app/Contents/MacOS/MicKeepAlive"

        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executablePath],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: plistURL)
            } catch {
                return false
            }
            return runLaunchctl(["load", plistURL.path])
        } else {
            _ = runLaunchctl(["unload", plistURL.path])
            try? FileManager.default.removeItem(at: plistURL)
            return true
        }
    }

    private func runLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - 探针采集

/// 用 AVCaptureSession 采集默认输入设备声音并计算电平。
/// 与 App 的保活会话同机制（多客户端共享，不独占麦克风），电平算法与 App 共用 AudioLevel。
private enum AudioProbe {
    static func captureLevel(duration: TimeInterval) -> Float {
        // 未授权时不弹窗、直接返回 0（App 侧会按"无法验证"处理）
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return 0 }

        let session = AVCaptureSession()
        session.sessionPreset = .low
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return 0
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        let collector = SampleCollector()
        output.setSampleBufferDelegate(collector, queue: DispatchQueue(label: "com.example.MicKeepAlive.probe"))
        guard session.canAddOutput(output) else { return 0 }
        session.addOutput(output)

        session.startRunning()
        Thread.sleep(forTimeInterval: duration)
        session.stopRunning()
        return collector.level
    }
}

private final class SampleCollector: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var sum: Float = 0
    private var count = 0

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return 0 }
        return sum / Float(count)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let l = AudioLevel.calculate(from: sampleBuffer)
        lock.lock()
        sum += l
        count += 1
        lock.unlock()
    }
}

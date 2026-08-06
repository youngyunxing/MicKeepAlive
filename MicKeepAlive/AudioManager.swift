import Foundation
import AVFoundation
import CoreAudio
import os.log

enum AudioManagerState {
    case running
    case paused
    case denied
    case error(String)
}

protocol AudioManagerDelegate: AnyObject {
    func audioManager(_ manager: AudioManager, didUpdateLevel level: Float)
    func audioManager(_ manager: AudioManager, didChangeState state: AudioManagerState)
}

final class AudioManager {
    static let levelBars = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    weak var delegate: AudioManagerDelegate?
    private var engine: AVAudioEngine?
    private var configChangeObserver: NSObjectProtocol?
    private var configChangeWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?
    private var healthCheckTimer: Timer?
    private var lastLevelUpdateTime = Date()
    private var lastUIUpdateTime = Date.distantPast
    private var lastStatusLogTime = Date.distantPast
    private var lastLoggedDefaultDeviceID: AudioDeviceID?
    private var lastNoDeviceLogTime = Date.distantPast
    private var consecutiveStartFailures = 0
    private(set) var isPaused = false
    private(set) var isRunning = false

    private let logger = Logger(subsystem: "com.example.MicKeepAlive", category: "Audio")

    /// 限制状态栏图标刷新频率，避免主线程被 tap 回调淹没（50ms≈20fps，兼顾流畅与性能）
    private let uiUpdateInterval: TimeInterval = 0.05
    /// 状态采样日志间隔（记录电平/设备，用于事后定位突变）。事件日志另在发生时即时记录。
    private let statusLogInterval: TimeInterval = 30
    /// 健康检查间隔：不要太频繁，避免不必要的重建
    private let healthCheckInterval: TimeInterval = 60
    /// 如果超过这么长时间没有收到音频电平更新，认为引擎可能已经僵死
    private let levelUpdateTimeout: TimeInterval = 10
    /// 连续启动失败次数上限，失败太多次后不再自动重试，避免无限循环
    private let maxConsecutiveFailures = 5

    init(delegate: AudioManagerDelegate?) {
        self.delegate = delegate
    }

    var isKeepingAlive: Bool {
        isRunning && !isPaused
    }

    // MARK: - 权限与启动

    func requestPermissionAndStart() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    self.start()
                } else {
                    self.record("麦克风权限被拒绝", isError: true)
                    self.delegate?.audioManager(self, didChangeState: .denied)
                }
            }
        }
    }

    func start() {
        guard !isKeepingAlive else { return }
        isPaused = false
        consecutiveStartFailures = 0
        lastLevelUpdateTime = Date()
        lastUIUpdateTime = Date.distantPast
        rebuildAndStartEngine(reason: "start")
        startHealthCheckTimer()
    }

    func stop() {
        guard isRunning else { return }
        isPaused = true
        engine?.stop()
        isRunning = false
        stopHealthCheckTimer()
        StateStore.shared.save(keepingAlive: false)
        record("停止保活")
        delegate?.audioManager(self, didChangeState: .paused)
    }

    func toggle() {
        if isKeepingAlive {
            stop()
        } else {
            start()
        }
    }

    // MARK: - 音频引擎

    private func rebuildAndStartEngine(reason: String) {
        // 防护：默认输入设备消失/不存在时（蓝牙瞬断、设备切换瞬间），
        // 此时 installTap 会因格式不匹配抛 NSException 导致崩溃（SIGABRT）。
        // 遇到这种情况先不重建，等设备恢复（新的配置变更通知）或定时兜底重试。
        if let deviceID = AudioDeviceUtils.defaultInputDevice(), deviceID != 0 {
            // 正常路径，继续
        } else {
            // 设备消失：跳过重建避免崩溃，但持续重试；日志做冷却避免刷屏
            let now = Date()
            if now.timeIntervalSince(lastNoDeviceLogTime) >= 10 {
                lastNoDeviceLogTime = now
                record("没有默认输入设备，跳过重建（reason=\(reason)），继续重试", isError: true)
            }
            scheduleRetryRebuild()
            return
        }

        // 清理旧的 observer，避免重复注册导致配置变更时多次重建
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil

        let newEngine = AVAudioEngine()
        engine = newEngine

        let inputNode = newEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // 记录重建时的设备与 format，用于定位“format 错位”假设
        let deviceID = AudioDeviceUtils.defaultInputDevice() ?? 0
        let deviceName = deviceID != 0 ? (AudioDeviceUtils.deviceName(deviceID: deviceID) ?? "?") : "none"
        record("重建引擎[reason=\(reason)] device=\(deviceName)(\(deviceID)) nodeFormat=\(Self.describe(format))")

        // 用 nil 格式安装 tap，让 AVAudioEngine 自动适配硬件格式。
        // 显式传 format 在设备格式切换时会导致 InstallTapOnNode 抛 NSException 崩溃。
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self = self, !self.isPaused else { return }

            let level = Self.calculateLevel(from: buffer)
            DispatchQueue.main.async {
                let now = Date()
                // 记录最后一次收到音频数据的时间（主线程操作，避免竞争）
                self.lastLevelUpdateTime = now

                // 定期采样：电平 + 默认设备，并检测默认设备是否被切换
                if now.timeIntervalSince(self.lastStatusLogTime) >= self.statusLogInterval {
                    self.lastStatusLogTime = now
                    self.logStatus(level: level)
                }

                // 限制 UI 刷新频率，避免主线程过载导致菜单/输入法卡死
                guard now.timeIntervalSince(self.lastUIUpdateTime) >= self.uiUpdateInterval else { return }
                self.lastUIUpdateTime = now
                self.delegate?.audioManager(self, didUpdateLevel: level)
            }
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: newEngine,
            queue: .main
        ) { [weak self] _ in
            self?.audioConfigurationChanged()
        }

        newEngine.prepare()

        do {
            try newEngine.start()
            isRunning = true
            isPaused = false
            consecutiveStartFailures = 0
            lastLevelUpdateTime = Date()

            // 启动后读取实际硬件格式，若无效（0 声道/0 采样率）说明输入节点仍不可用
            let hwFormat = inputNode.outputFormat(forBus: 0)
            if hwFormat.channelCount == 0 || hwFormat.sampleRate == 0 {
                record("引擎启动成功但输入格式无效：\(Self.describe(hwFormat))", isError: true)
            } else {
                record("引擎启动成功 hwFormat=\(Self.describe(hwFormat))")
            }

            StateStore.shared.save(keepingAlive: true)
            delegate?.audioManager(self, didChangeState: .running)
        } catch {
            isRunning = false
            consecutiveStartFailures += 1
            record("引擎启动失败[\(self.consecutiveStartFailures)]: \(error.localizedDescription)", isError: true)
            StateStore.shared.save(keepingAlive: false)
            delegate?.audioManager(self, didChangeState: .error(error.localizedDescription))
        }
    }

    private func scheduleRetryRebuild() {
        retryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isPaused else { return }
            self.rebuildAndStartEngine(reason: "retry")
        }
        retryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    private func audioConfigurationChanged() {
        // 路由/配置变更是重点嫌疑事件，记录此刻的硬件 format
        let hwFormat = engine?.inputNode.outputFormat(forBus: 0)
        let deviceID = AudioDeviceUtils.defaultInputDevice() ?? 0
        let deviceName = deviceID != 0 ? (AudioDeviceUtils.deviceName(deviceID: deviceID) ?? "?") : "none"
        record("收到 AVAudioEngineConfigurationChange！device=\(deviceName)(\(deviceID)) currentFormat=\(hwFormat.map { Self.describe($0) } ?? "nil")")

        // 防抖：配置变更可能在短时间内连续发生，取消上一次的重建计划，重新等待稳定
        configChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isPaused else { return }
            self.rebuildAndStartEngine(reason: "configChange")
        }
        configChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    // MARK: - 状态采样

    private func logStatus(level: Float) {
        let currentDeviceID = AudioDeviceUtils.defaultInputDevice() ?? 0
        if let last = lastLoggedDefaultDeviceID, last != currentDeviceID {
            let name = AudioDeviceUtils.deviceName(deviceID: currentDeviceID) ?? "?"
            record("默认输入设备发生切换！\(last) -> \(currentDeviceID)(\(name))", isError: true)
        }
        lastLoggedDefaultDeviceID = currentDeviceID
        let msg = "status level=\(String(format: "%.3f", level)) engineRunning=\(engine?.isRunning ?? false) device=\(currentDeviceID)"
        logger.debug("\(msg, privacy: .public)")
        writeToFile(msg)
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz/\(format.channelCount)ch/common=\(format.commonFormat.rawValue)"
    }

    // MARK: - 日志（os.log 供实时监视，文件供事后取证；文件封顶轮转）

    private func record(_ message: String, isError: Bool = false) {
        if isError {
            logger.error("\(message, privacy: .public)")
            writeToFile("ERROR: " + message)
        } else {
            logger.notice("\(message, privacy: .public)")
            writeToFile(message)
        }
    }

    private static let diagnosticLogURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MicKeepAlive/diagnostic.log")

    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private func writeToFile(_ message: String) {
        let fm = FileManager.default
        let url = Self.diagnosticLogURL
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 简单轮转：超过 1MB 就把当前日志挪到 .old（覆盖上一个），总量封顶约 2MB
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64, size > 1_000_000 {
            let oldURL = url.appendingPathExtension("old")
            try? fm.removeItem(at: oldURL)
            try? fm.moveItem(at: url, to: oldURL)
        }

        let line = "\(Self.logDateFormatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - 健康检查

    private func startHealthCheckTimer() {
        stopHealthCheckTimer()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            self?.performHealthCheck()
        }
    }

    private func stopHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func performHealthCheck() {
        guard !isPaused else { return }

        // 如果引擎应该运行但实际上没在跑，或者长时间没有电平更新，说明引擎可能已经僵死
        let engineIsActuallyRunning = engine?.isRunning ?? false
        let levelIsStale = Date().timeIntervalSince(lastLevelUpdateTime) > levelUpdateTimeout

        if !engineIsActuallyRunning || levelIsStale {
            record("健康检查发现引擎异常：isRunning=\(engineIsActuallyRunning) levelStale=\(levelIsStale)，尝试重建", isError: true)
            guard consecutiveStartFailures < maxConsecutiveFailures else {
                // 连续失败太多次，不再自动重试，避免死循环
                delegate?.audioManager(self, didChangeState: .error("麦克风引擎多次重启失败，请手动暂停后再开启"))
                return
            }
            rebuildAndStartEngine(reason: "healthCheck")
        }
    }

    // MARK: - 电平计算

    static func calculateLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))

        let db = 20 * log10(max(rms, 0.00001))
        let normalized = (db + 60) / 60
        return max(0, min(1, normalized))
    }
}

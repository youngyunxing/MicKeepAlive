import Foundation
import AVFoundation

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
    private var healthCheckTimer: Timer?
    private var lastLevelUpdateTime = Date()
    private var lastUIUpdateTime = Date.distantPast
    private var consecutiveStartFailures = 0
    private(set) var isPaused = false
    private(set) var isRunning = false

    /// 限制状态栏图标刷新频率，避免主线程被 tap 回调淹没
    private let uiUpdateInterval: TimeInterval = 0.1
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
        rebuildAndStartEngine()
        startHealthCheckTimer()
    }

    func stop() {
        guard isRunning else { return }
        isPaused = true
        engine?.stop()
        isRunning = false
        stopHealthCheckTimer()
        StateStore.shared.save(keepingAlive: false)
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

    private func rebuildAndStartEngine() {
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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, !self.isPaused else { return }

            let level = Self.calculateLevel(from: buffer)
            DispatchQueue.main.async {
                let now = Date()
                // 记录最后一次收到音频数据的时间（主线程操作，避免竞争）
                self.lastLevelUpdateTime = now

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
            StateStore.shared.save(keepingAlive: true)
            delegate?.audioManager(self, didChangeState: .running)
        } catch {
            isRunning = false
            consecutiveStartFailures += 1
            StateStore.shared.save(keepingAlive: false)
            delegate?.audioManager(self, didChangeState: .error(error.localizedDescription))
        }
    }

    private func audioConfigurationChanged() {
        // 防抖：配置变更可能在短时间内连续发生，取消上一次的重建计划，重新等待稳定
        configChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isPaused else { return }
            self.rebuildAndStartEngine()
        }
        configChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
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
            guard consecutiveStartFailures < maxConsecutiveFailures else {
                // 连续失败太多次，不再自动重试，避免死循环
                delegate?.audioManager(self, didChangeState: .error("麦克风引擎多次重启失败，请手动暂停后再开启"))
                return
            }
            rebuildAndStartEngine()
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

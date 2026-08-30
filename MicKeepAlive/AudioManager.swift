import Foundation
import AVFoundation
import CoreMedia
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

final class AudioManager: NSObject {
    static let levelBars = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    weak var delegate: AudioManagerDelegate?
    private var captureSession: AVCaptureSession?

    private var runtimeErrorObserver: NSObjectProtocol?
    private var deviceConnectedObserver: NSObjectProtocol?
    private var deviceDisconnectedObserver: NSObjectProtocol?

    private var retryWorkItem: DispatchWorkItem?
    private var healthCheckTimer: Timer?
    private var lastLevelUpdateTime = Date()
    private var lastUIUpdateTime = Date.distantPast
    private var lastStatusLogTime = Date.distantPast
    private var lastLoggedDefaultDeviceID: AudioDeviceID?
    private var lastNoDeviceLogTime = Date.distantPast
    private var consecutiveStartFailures = 0
    /// 当前会话启动时间与累计重建次数，用于长期稳定性观察（无重建=健康）
    private var sessionStartTime: Date?
    private var rebuildCount = 0
    /// 最近一次音频格式（采样率/声道），用于检测蓝牙重协商导致的格式漂移
    private var lastSampleRate: Double?
    private var lastChannelCount: UInt32?
    private(set) var isPaused = false
    private(set) var isRunning = false
    /// 最近一次计算的电平（探针验证对比用，主线程更新）
    private var lastLevel: Float = 0
    /// 最近一次设备事件（断开/连接）时间，用于探针验证窗口
    private var lastDeviceEventTime: Date?
    /// 探针验证窗口定时器（设备事件后每 30 秒验证一次）
    private var probeTimer: Timer?
    /// 连续探针确认失败次数（安全阀）
    private var consecutiveProbeFailures = 0
    /// 探针验证暂停（连续失败后，等设备事件或手动操作）
    private var probePaused = false

    /// 音频数据回调队列（避免阻塞主线程）
    private let sampleBufferQueue = DispatchQueue(label: "com.example.MicKeepAlive.audioOutput")
    private let logger = Logger(subsystem: "com.example.MicKeepAlive", category: "Audio")

    /// 限制状态栏图标刷新频率，避免主线程被回调淹没（50ms≈20fps，兼顾流畅与性能）
    private let uiUpdateInterval: TimeInterval = 0.05
    /// 状态采样日志间隔（记录电平/设备，用于事后定位突变）。事件日志另在发生时即时记录。
    private let statusLogInterval: TimeInterval = 30
    /// 健康检查间隔：不要太频繁，避免不必要的重建
    private let healthCheckInterval: TimeInterval = 60
    /// 如果超过这么长时间没有收到音频电平更新，认为会话可能已经僵死
    private let levelUpdateTimeout: TimeInterval = 10
    /// 连续启动失败次数上限，失败太多次后不再自动重试，避免无限循环
    private let maxConsecutiveFailures = 5
    /// 探针验证窗口时长：设备事件后 HAL 需要时间稳定，窗口内持续重试
    private let probeWindowDuration: TimeInterval = 5 * 60
    /// 探针验证间隔
    private let probeInterval: TimeInterval = 30
    /// 判定"有声音"的电平阈值（0~1 归一化，约 -57dB）。
    /// 高于麦克风底噪（安静房间约 0.02~0.04），低于人声（约 0.1+），
    /// 避免把底噪误判为"有声音"导致误触发重建
    private let soundThreshold: Float = 0.05
    /// 连续探针确认失败上限，超过后暂停自动恢复
    private let maxProbeFailures = 3
    /// 探针子进程超时（秒）
    private static let probeTimeout: TimeInterval = 10

    init(delegate: AudioManagerDelegate?) {
        self.delegate = delegate
        super.init()
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
        rebuildAndStartSession(reason: "start")
        startHealthCheckTimer()
    }

    func stop() {
        guard isRunning else { return }
        isPaused = true
        stopCaptureSession()
        isRunning = false
        stopHealthCheckTimer()
        stopProbeTimer()
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

    // MARK: - 保活会话（AVCaptureSession 可共享，不独占输入）

    private func rebuildAndStartSession(reason: String) {
        // 防护：默认输入设备消失/不存在时（蓝牙瞬断、设备切换瞬间），
        // 此时创建 AVCaptureDeviceInput 会抛错。遇到这种情况先不重建，
        // 等设备恢复（新的连接通知）或定时兜底重试。
        guard let currentDevice = AudioDeviceUtils.defaultInputDevice(), currentDevice != 0 else {
            let now = Date()
            if now.timeIntervalSince(lastNoDeviceLogTime) >= 10 {
                lastNoDeviceLogTime = now
                record("没有默认输入设备，跳过重建（reason=\(reason)），继续重试", isError: true)
            }
            scheduleRetryRebuild()
            return
        }

        rebuildCount += 1
        stopCaptureSession()

        let session = AVCaptureSession()
        session.sessionPreset = .low

        guard let device = AVCaptureDevice.default(for: .audio) else {
            record("无法获取默认输入设备（reason=\(reason)）", isError: true)
            scheduleRetryRebuild()
            return
        }

        let deviceID = currentDevice
        let deviceName = AudioDeviceUtils.deviceName(deviceID: deviceID) ?? device.localizedName
        record("重建保活会话[reason=\(reason)] device=\(deviceName)(\(deviceID))")

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                record("无法添加输入设备到会话（reason=\(reason)）", isError: true)
                failStart("无法添加输入设备")
                return
            }
            session.addInput(input)
        } catch {
            record("创建输入设备失败[reason=\(reason)]: \(error.localizedDescription)", isError: true)
            failStart(error.localizedDescription)
            return
        }

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleBufferQueue)
        guard session.canAddOutput(output) else {
            record("无法添加音频输出到会话（reason=\(reason)）", isError: true)
            failStart("无法添加音频输出")
            return
        }
        session.addOutput(output)

        captureSession = session
        registerObservers(for: session)

        // startRunning 可能短暂阻塞，放到后台队列执行，避免卡主线程（历史上有菜单/输入法卡死的前科）
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak session] in
            guard let session = session else { return }
            session.startRunning()
            let running = session.isRunning
            DispatchQueue.main.async {
                guard let self = self else { return }
                if running {
                    self.isRunning = true
                    self.isPaused = false
                    self.consecutiveStartFailures = 0
                    self.sessionStartTime = Date()
                    self.lastLevelUpdateTime = Date()
                    self.record("保活会话启动成功 device=\(deviceName)(\(deviceID)) rebuilds=\(self.rebuildCount)")
                    StateStore.shared.save(keepingAlive: true)
                    self.delegate?.audioManager(self, didChangeState: .running)
                } else {
                    // startRunning 同步失败（罕见），等待 RuntimeError 通知或兜底重试
                    self.failStart("会话未能启动")
                }
            }
        }
    }

    private func failStart(_ message: String) {
        isRunning = false
        consecutiveStartFailures += 1
        // 彻底清理：停掉可能已启动的会话并移除 observer，避免残留
        stopCaptureSession()
        record("启动失败[\(consecutiveStartFailures)]: \(message)", isError: true)
        StateStore.shared.save(keepingAlive: false)
        delegate?.audioManager(self, didChangeState: .error(message))
    }

    private func stopCaptureSession() {
        removeObservers()
        captureSession?.stopRunning()
        captureSession = nil
    }

    deinit {
        // 清理与对象绑定的外部资源（observer / 定时器 / 运行中的会话），
        // 避免它们对象释放后仍残留。当前 AudioManager 随 App 生命周期不释放，
        // 但保留此清理以便将来复用或重建时无副作用。
        stopCaptureSession()
        stopHealthCheckTimer()
        stopProbeTimer()
    }

    private func scheduleRetryRebuild() {
        retryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isPaused else { return }
            self.rebuildAndStartSession(reason: "retry")
        }
        retryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    // MARK: - 通知观察（设备连接/断开、会话运行时错误）

    private func registerObservers(for session: AVCaptureSession) {
        let nc = NotificationCenter.default
        runtimeErrorObserver = nc.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self.record("保活会话运行时错误: \(error.map { $0.localizedDescription } ?? "unknown")", isError: true)
            self.scheduleRetryRebuild()
            self.startProbeVerificationWindow()
        }
        deviceConnectedObserver = nc.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRetryRebuild()
            self?.startProbeVerificationWindow()
        }
        deviceDisconnectedObserver = nc.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let device = note.object as? AVCaptureDevice {
                self.record("输入设备断开: \(device.localizedName)", isError: true)
            }
            self.scheduleRetryRebuild()
            self.startProbeVerificationWindow()
        }
    }

    private func removeObservers() {
        let nc = NotificationCenter.default
        if let o = runtimeErrorObserver { nc.removeObserver(o); runtimeErrorObserver = nil }
        if let o = deviceConnectedObserver { nc.removeObserver(o); deviceConnectedObserver = nil }
        if let o = deviceDisconnectedObserver { nc.removeObserver(o); deviceDisconnectedObserver = nil }
    }

    // MARK: - 状态采样

    private func logStatus(level: Float) {
        let currentDeviceID = AudioDeviceUtils.defaultInputDevice() ?? 0
        if let last = lastLoggedDefaultDeviceID, last != currentDeviceID {
            let name = AudioDeviceUtils.deviceName(deviceID: currentDeviceID) ?? "?"
            record("默认输入设备发生切换！\(last) -> \(currentDeviceID)(\(name))", isError: true)
        }
        lastLoggedDefaultDeviceID = currentDeviceID
        let uptime = sessionStartTime.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
        let msg = "status level=\(String(format: "%.3f", level)) sessionRunning=\(captureSession?.isRunning ?? false) device=\(currentDeviceID) uptime=\(uptime)m rebuilds=\(rebuildCount)"
        logger.debug("\(msg, privacy: .public)")
        writeToFile(msg)
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

    /// 所有文件日志统一走这条串行队列：DateFormatter 非线程安全，
    /// 而日志可能从主线程（状态采样）和音频回调线程（格式漂移）同时写入，必须串行化。
    private static let logQueue = DispatchQueue(label: "com.example.MicKeepAlive.log")

    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private func writeToFile(_ message: String) {
        // 异步入队：不阻塞调用方（音频回调线程尤其不能阻塞），串行队列保证顺序与线程安全
        Self.logQueue.async {
            Self.appendLineToFile(message)
        }
    }

    private static func appendLineToFile(_ message: String) {
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

        // 如果会话应该运行但实际上没在跑，或者长时间没有电平更新，说明保活可能已僵死
        let sessionRunning = captureSession?.isRunning ?? false
        let levelIsStale = Date().timeIntervalSince(lastLevelUpdateTime) > levelUpdateTimeout

        if !sessionRunning || levelIsStale {
            record("健康检查发现异常：sessionRunning=\(sessionRunning) levelStale=\(levelIsStale)，尝试重建", isError: true)
            guard consecutiveStartFailures < maxConsecutiveFailures else {
                // 连续失败太多次，不再自动重试，避免死循环
                delegate?.audioManager(self, didChangeState: .error("麦克风会话多次重启失败，请手动暂停后再开启"))
                return
            }
            rebuildAndStartSession(reason: "healthCheck")
        }
    }

    // MARK: - 探针验证（设备事件后确认重建是否真的恢复）

    /// 设备事件后启动探针验证窗口：每 30 秒用全新进程采集 2 秒声音，
    /// 与自身电平对比，确认重建是否真的恢复。
    /// 背景：蓝牙麦重连后 HAL 需要时间稳定，第一次重建可能拿到静音 IOProc
    /// （会话自认为运行中但听不到声音），此时只有"新进程能听到、本应用听不到"
    /// 才能确诊失明；房间安静时无法验证，则按窗口有界重试兜底。
    private func startProbeVerificationWindow() {
        guard !isPaused else { return }
        let windowStart = Date()
        lastDeviceEventTime = windowStart
        consecutiveProbeFailures = 0
        probePaused = false
        stopProbeTimer()
        probeTimer = Timer.scheduledTimer(withTimeInterval: probeInterval, repeats: true) { [weak self] _ in
            self?.performProbeCheck()
        }
        // 窗口到期自动停止（仅当窗口仍是当前窗口时，避免新窗口被旧回调误停）
        DispatchQueue.main.asyncAfter(deadline: .now() + probeWindowDuration) { [weak self] in
            guard let self = self, self.lastDeviceEventTime == windowStart else { return }
            self.stopProbeTimer()
            self.record("探针验证窗口结束（5 分钟），未确认恢复")
        }
    }

    private func stopProbeTimer() {
        probeTimer?.invalidate()
        probeTimer = nil
    }

    private func performProbeCheck() {
        guard !isPaused, !probePaused else { return }
        let probePath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mkctl").path
        // 探针采集约 2 秒，放后台队列避免阻塞主线程
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let probeLevel = Self.runProbe(executablePath: probePath)
            DispatchQueue.main.async {
                self?.handleProbeResult(probeLevel)
            }
        }
    }

    /// 运行 mkctl probe：全新进程（新 CoreAudio 连接）采集 2 秒默认输入设备声音，
    /// 返回归一化电平（0~1）；失败返回 nil。
    private static func runProbe(executablePath: String) -> Float? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["probe"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if semaphore.wait(timeout: .now() + probeTimeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
              let line = output.split(separator: "\n").first(where: { $0.hasPrefix("level=") }),
              let value = Float(line.dropFirst("level=".count)) else {
            return nil
        }
        return value
    }

    private func handleProbeResult(_ probeLevel: Float?) {
        guard !isPaused, !probePaused else { return }
        guard let probeLevel = probeLevel else {
            record("探针执行失败，跳过本轮验证", isError: true)
            return
        }
        let appHears = lastLevel > soundThreshold
        let probeHears = probeLevel > soundThreshold

        if probeHears {
            if appHears {
                // 探针和 app 都听到声音：重建确认成功
                record("探针验证成功：probe=\(String(format: "%.3f", probeLevel)) app=\(String(format: "%.3f", lastLevel))，停止重试")
                stopProbeTimer()
            } else {
                // 探针听到声音但 app 静音：确诊失明，重建
                consecutiveProbeFailures += 1
                record("探针确诊失明：probe=\(String(format: "%.3f", probeLevel)) app=\(String(format: "%.3f", lastLevel))，重建[\(consecutiveProbeFailures)]", isError: true)
                if consecutiveProbeFailures >= maxProbeFailures {
                    probePaused = true
                    stopProbeTimer()
                    record("连续 \(maxProbeFailures) 次探针重建未恢复，暂停自动恢复，等待设备事件或手动操作", isError: true)
                    delegate?.audioManager(self, didChangeState: .error("麦克风多次重建未恢复，请手动重启保活"))
                    return
                }
                rebuildAndStartSession(reason: "probeRetry")
            }
        }
        // 探针静音：房间安静无法验证，继续窗口（有界重试兜底）
    }

    /// 检测蓝牙重协商导致的采样率/声道漂移（常是"突然不能用"的前兆）。首次仅记录基线不刷屏。
    private func detectFormatChange(in sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        let rate = asbd.pointee.mSampleRate
        let channels = asbd.pointee.mChannelsPerFrame
        guard lastSampleRate != rate || lastChannelCount != channels else { return }

        let baseline = lastSampleRate == nil
        lastSampleRate = rate
        lastChannelCount = channels
        if !baseline {
            record("音频格式漂移！rate=\(Int(rate))Hz ch=\(channels) rebuilds=\(rebuildCount)", isError: true)
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AudioManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isPaused else { return }

        detectFormatChange(in: sampleBuffer)
        let level = AudioLevel.calculate(from: sampleBuffer)
        DispatchQueue.main.async {
            let now = Date()
            // 记录最后一次收到音频数据的时间（主线程操作，避免竞争）
            self.lastLevelUpdateTime = now
            // 记录最近一次电平（探针验证对比用）
            self.lastLevel = level

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
}
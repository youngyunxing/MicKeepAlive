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
    private(set) var isPaused = false
    private(set) var isRunning = false

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
        rebuildAndStartEngine()
    }

    func stop() {
        guard isRunning else { return }
        isPaused = true
        engine?.stop()
        isRunning = false
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
                self.delegate?.audioManager(self, didUpdateLevel: level)
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioConfigurationChanged(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: newEngine
        )

        newEngine.prepare()

        do {
            try newEngine.start()
            isRunning = true
            isPaused = false
            StateStore.shared.save(keepingAlive: true)
            delegate?.audioManager(self, didChangeState: .running)
        } catch {
            isRunning = false
            StateStore.shared.save(keepingAlive: false)
            delegate?.audioManager(self, didChangeState: .error(error.localizedDescription))
        }
    }

    @objc private func audioConfigurationChanged(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self, !self.isPaused else { return }
            self.rebuildAndStartEngine()
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

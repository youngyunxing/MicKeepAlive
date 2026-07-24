import Foundation
import AVFoundation
import CoreAudio

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
        // 清理旧引擎
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
            delegate?.audioManager(self, didChangeState: .running)
        } catch {
            isRunning = false
            delegate?.audioManager(self, didChangeState: .error(error.localizedDescription))
        }
    }

    @objc private func audioConfigurationChanged(_ notification: Notification) {
        // 默认输入设备改变后，延迟一小会儿重建引擎
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

        // 映射到 0~1：-60dB 为静音，0dB 为最大
        let db = 20 * log10(max(rms, 0.00001))
        let normalized = (db + 60) / 60
        return max(0, min(1, normalized))
    }

    // MARK: - 设备枚举与选择

    static func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }

        return ids.compactMap { id in
            guard deviceHasInputStreams(deviceID: id), let name = deviceName(deviceID: id) else { return nil }
            // 过滤掉系统虚拟聚集设备（AVAudioEngine 激活后 CoreAudio 会创建的 wrapper）
            let lowercased = name.lowercased()
            guard !lowercased.contains("cadefaultdeviceaggregate") else { return nil }
            return (id: id, name: name)
        }
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }
        return deviceID
    }

    @discardableResult
    static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        return status == noErr
    }

    private static func deviceHasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: 0
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return false
        }

        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        return abl.contains { $0.mNumberChannels > 0 }
    }

    private static func deviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // 使用 Unmanaged 避免直接对 CFString 取地址的 ARC 问题
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr else { return nil }
        guard let cfName = name?.takeRetainedValue() else { return nil }
        return cfName as String
    }
}

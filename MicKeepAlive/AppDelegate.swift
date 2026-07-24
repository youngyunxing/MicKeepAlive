import Cocoa
import CoreFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    private var audioManager: AudioManager!
    private lazy var menuBuilder = MenuBuilder(audioManager: audioManager)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()

        audioManager = AudioManager(delegate: self)
        audioManager.requestPermissionAndStart()

        // 监听来自 mkctl 的远程命令
        registerRemoteCommandObservers()

        // 首次启动默认启用开机自启，之后由用户通过菜单控制
        if !UserDefaults.standard.bool(forKey: "hasConfiguredLaunchAtLogin") {
            _ = LaunchAgentManager.shared.enable()
            UserDefaults.standard.set(true, forKey: "hasConfiguredLaunchAtLogin")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            button.title = L10n.pick("🎤▁", "🎤▁")
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusBarButtonClicked(_ sender: Any?) {
        statusItem.menu = menuBuilder.buildMenu()
    }

    private func registerRemoteCommandObservers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let names = [
            MicKeepAliveConstants.commandStartName,
            MicKeepAliveConstants.commandStopName,
            MicKeepAliveConstants.commandToggleName
        ]
        let observerPointer = Unmanaged.passUnretained(self).toOpaque()

        for name in names {
            CFNotificationCenterAddObserver(
                center,
                observerPointer,
                remoteCommandCallback,
                name as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    fileprivate func handleRemoteCommand(named name: String) {
        switch name {
        case MicKeepAliveConstants.commandStartName:
            audioManager.start()
        case MicKeepAliveConstants.commandStopName:
            audioManager.stop()
        case MicKeepAliveConstants.commandToggleName:
            audioManager.toggle()
        default:
            break
        }
    }
}

private func remoteCommandCallback(center: CFNotificationCenter?, observer: UnsafeMutableRawPointer?, name: CFNotificationName?, object: UnsafeRawPointer?, userInfo: CFDictionary?) {
    guard let observer = observer, let name = name else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
    let commandName = name.rawValue as String
    DispatchQueue.main.async {
        delegate.handleRemoteCommand(named: commandName)
    }
}

extension AppDelegate: AudioManagerDelegate {
    func audioManager(_ manager: AudioManager, didUpdateLevel level: Float) {
        let bars = AudioManager.levelBars
        let index = min(Int(level * Float(bars.count - 1)), bars.count - 1)
        statusItem.button?.title = "🎤\(bars[index])"
    }

    func audioManager(_ manager: AudioManager, didChangeState state: AudioManagerState) {
        switch state {
        case .running:
            statusItem.button?.title = L10n.pick("🎤▁", "🎤▁")
            StateStore.shared.save(keepingAlive: true)
        case .paused:
            statusItem.button?.title = L10n.pick("🎤⏸", "🎤⏸")
            StateStore.shared.save(keepingAlive: false)
        case .denied:
            statusItem.button?.title = L10n.pick("🎤🚫", "🎤🚫")
            StateStore.shared.save(keepingAlive: false)
        case .error:
            statusItem.button?.title = L10n.pick("🎤❌", "🎤❌")
            StateStore.shared.save(keepingAlive: false)
        }
    }
}

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    private var audioManager: AudioManager!
    private lazy var menuBuilder = MenuBuilder(audioManager: audioManager)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()

        audioManager = AudioManager(delegate: self)
        audioManager.requestPermissionAndStart()

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
        case .paused:
            statusItem.button?.title = L10n.pick("🎤⏸", "🎤⏸")
        case .denied:
            statusItem.button?.title = L10n.pick("🎤🚫", "🎤🚫")
        case .error:
            statusItem.button?.title = L10n.pick("🎤❌", "🎤❌")
        }
    }
}

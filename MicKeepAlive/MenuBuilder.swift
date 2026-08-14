import Cocoa
import CoreAudio

final class MenuBuilder {
    private let audioManager: AudioManager

    init(audioManager: AudioManager) {
        self.audioManager = audioManager
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // 标题与版本
        let titleItem = NSMenuItem(title: "MicKeepAlive", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        // 停止 / 开启。用 isPaused 判断（isRunning 在停止后仍为 true，
        // 因为它指"会话实例是否挂在 capture 上"，不代表用户想保活）
        let toggleTitle = audioManager.isPaused
            ? L10n.pick("开启保活", "Start Keep-Alive")
            : L10n.pick("停止保活", "Stop Keep-Alive")
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleKeepAlive(_:)), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        // 麦克风选择
        let deviceHeader = NSMenuItem(title: L10n.pick("选择麦克风", "Select Microphone"), action: nil, keyEquivalent: "")
        deviceHeader.isEnabled = false
        menu.addItem(deviceHeader)

        let devices = AudioDeviceUtils.availableInputDevices()
        let currentDeviceID = AudioDeviceUtils.defaultInputDevice()

        if devices.isEmpty {
            let noneItem = NSMenuItem(title: L10n.pick("未检测到麦克风", "No Microphone Found"), action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            menu.addItem(noneItem)
        } else {
            for device in devices {
                let item = NSMenuItem(title: device.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.id
                item.state = (device.id == currentDeviceID) ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // 打开声音设置
        let soundSettingsItem = NSMenuItem(
            title: L10n.pick("打开声音设置…", "Open Sound Settings…"),
            action: #selector(openSoundSettings(_:)),
            keyEquivalent: ""
        )
        soundSettingsItem.target = self
        menu.addItem(soundSettingsItem)

        menu.addItem(NSMenuItem.separator())

        // 开机自启
        let launchItem = NSMenuItem(
            title: L10n.pick("开机自启", "Launch at Login"),
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = LaunchAgentManager.shared.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        // 退出
        let quitItem = NSMenuItem(
            title: L10n.pick("退出", "Quit"),
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Actions

    @objc private func toggleKeepAlive(_ sender: NSMenuItem) {
        audioManager.toggle()
        // 点完后立即刷新菜单项文案，避免菜单还开着时显示旧文字
        sender.title = audioManager.isPaused
            ? L10n.pick("开启保活", "Start Keep-Alive")
            : L10n.pick("停止保活", "Stop Keep-Alive")
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let deviceID = sender.representedObject as? AudioDeviceID else { return }
        if !AudioDeviceUtils.setDefaultInputDevice(deviceID) {
            // 设置失败时引导用户到系统设置手动切换
            openSoundSettings(sender)
        }
    }

    @objc private func openSoundSettings(_ sender: NSMenuItem) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound?input")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if LaunchAgentManager.shared.isEnabled {
            _ = LaunchAgentManager.shared.disable()
        } else {
            _ = LaunchAgentManager.shared.enable()
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }
}

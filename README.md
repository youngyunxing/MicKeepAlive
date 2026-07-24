# MicKeepAlive

macOS 菜单栏蓝牙麦克风保活工具。

## 解决什么问题

很多蓝牙麦克风/耳机为了省电，会在检测到"没有音频活动"一段时间后自动进入休眠或断开连接。典型场景：

- **视频会议**：开会前麦克风是好的，中间一段时间没说话，蓝牙耳麦自动断开，再说话时别人听不到。
- **语音通话/直播**：长时间通话中，麦克风突然掉线，需要手动重新连接或切换输入设备。
- **远程桌面/游戏语音**：系统把蓝牙麦克风当作"空闲设备"回收，导致语音中断。

MicKeepAlive 通过**持续读取默认输入设备的音频流**，让系统认为麦克风"正在使用中"，从而阻止蓝牙麦克风因空闲而自动休眠或断开。

## 核心特点

- **只读取，不录音**：音频数据仅用于计算实时电平，读取后立即释放，不存盘、不上传、不侵犯隐私。
- **一眼确认状态**：菜单栏图标根据输入音量实时变化（`🎤▁` ~ `🎤█`），看到图标在动就说明麦克风正被保持活跃。
- **常驻后台**：只出现在菜单栏，没有 Dock 图标和主窗口，不影响日常工作。
- **可选麦克风**：支持列出所有输入设备并切换系统默认麦克风。
- **命令行控制**：提供 `mkctl` 工具，方便脚本或自动化工具远程控制。

## 功能

- 只驻留菜单栏，不出现在 Dock
- 菜单栏图标实时显示输入电平：`🎤▁` ~ `🎤█`
- 支持选择系统默认输入麦克风
- 支持一键开关开机自启
- 提供 `mkctl` 命令行工具

## 技术方案

### 整体架构

- **App 目标**：纯菜单栏应用（`LSUIElement`），无 Dock 图标、无主窗口。
- **CLI 目标**：`mkctl`，与 App 共享音频工具代码，通过系统级通知控制 App。
- **共享代码**：`AudioDeviceUtils`、`MicKeepAliveConstants`、`MicKeepAliveState` 同时被 App 和 CLI 编译引用。

### 音频采集与电平显示

- 使用 `AVAudioEngine.inputNode.installTap(...)` 持续读取系统默认输入设备的音频 buffer。
- 每次 buffer 到来时计算 RMS，再换算为 dB 并映射到 0~1，最后选择对应的电平条字符：`🎤▁` ~ `🎤█`。
- 音频数据仅用于计算电平，读取后立即释放，**不录音、不缓存、不上传**。

### 麦克风选择

- 枚举：通过 CoreAudio `AudioObjectGetPropertyData(kAudioHardwarePropertyDevices)` 获取所有音频设备，再按输入通道数过滤。
- 过滤：排除系统自动创建的虚拟聚集设备（如 `CADefaultDeviceAggregate-*`），菜单中只保留真实输入麦克风。
- 切换：通过 `AudioObjectSetPropertyData(kAudioHardwarePropertyDefaultInputDevice)` 把选中设备设为系统默认输入，`AVAudioEngine` 会跟随系统默认设备变化。

### 跨进程控制（mkctl）

- CLI 与 App 之间使用 `CFNotificationCenterGetDarwinNotifyCenter()` 发送/接收 Darwin notify 通知。
- 命令名：
  - `com.example.MicKeepAlive.command.start`
  - `com.example.MicKeepAlive.command.stop`
  - `com.example.MicKeepAlive.command.toggle`
- App 在主线程中处理命令，避免音频引擎在非创建线程操作。

### 状态共享

- App 将当前保活状态写入 `~/Library/Application Support/MicKeepAlive/state.json`。
- CLI 的 `mkctl status` 读取该文件，展示 `app_running` 与 `keeping_alive`。

### 开机自启

- 通过 `~/Library/LaunchAgents/com.example.MicKeepAlive.plist` + `launchctl load/unload` 实现。
- plist 指向 `/Applications/MicKeepAlive.app/Contents/MacOS/MicKeepAlive`。

### 单例运行

- `main.swift` 启动前通过 `pgrep -x MicKeepAlive` 检查是否已有同名进程在运行；若有，则当前实例直接退出，防止菜单栏出现多个图标。

## 安装建议

建议安装到 `/Applications/MicKeepAlive.app`。

macOS 的麦克风权限与应用的安装路径相关。如果 App 从不同位置启动，系统可能要求重新授权麦克风。保持固定在 `/Applications` 可以避免重复弹窗。

## 麦克风权限

首次启动会弹窗申请麦克风权限，点击「允许」后通常不再弹窗。

如果误点拒绝：

系统设置 → 隐私与安全性 → 麦克风 → 找到 MicKeepAlive 打开。

## 命令行工具 `mkctl`

```bash
mkctl status              # 查看运行状态与当前默认麦克风
mkctl list                # 列出可用输入麦克风
mkctl start               # 启动/恢复保活
mkctl stop                # 停止保活
mkctl toggle              # 切换保活状态
mkctl set-device <名称或ID>  # 设置默认输入麦克风
mkctl launch-at-login on  # 开启开机自启
mkctl launch-at-login off # 关闭开机自启
```

## 构建与安装

```bash
cd MicKeepAlive
rm -rf /tmp/mk_derived

# 构建 App
xcodebuild -project MicKeepAlive.xcodeproj -scheme MicKeepAlive -configuration Release -derivedDataPath /tmp/mk_derived build

# 构建 CLI
xcodebuild -project MicKeepAlive.xcodeproj -scheme mkctl -configuration Release -derivedDataPath /tmp/mk_derived build

# 安装到 /Applications（唯一安装位置）
pkill -x MicKeepAlive
rm -rf /Applications/MicKeepAlive.app
cp -R /tmp/mk_derived/Build/Products/Release/MicKeepAlive.app /Applications/
cp /tmp/mk_derived/Build/Products/Release/mkctl /Applications/MicKeepAlive.app/Contents/MacOS/mkctl
ln -sf /Applications/MicKeepAlive.app/Contents/MacOS/mkctl /usr/local/bin/mkctl

# 启动
open /Applications/MicKeepAlive.app
```

## 注意事项

- 过滤了 `CADefaultDeviceAggregate-*` 等系统虚拟聚集设备，菜单中只显示真实输入麦克风。
- 开机自启通过 `~/Library/LaunchAgents/com.example.MicKeepAlive.plist` 实现。
- App 启动时会检查是否已有其他实例运行，防止多开。

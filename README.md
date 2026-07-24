# MicKeepAlive

macOS 菜单栏蓝牙麦克风保活工具。持续读取默认输入设备的音频流，让蓝牙麦克风不会因为空闲而自动断开连接。

## 功能

- 只驻留菜单栏，不出现在 Dock
- 菜单栏图标实时显示输入电平：`🎤▁` ~ `🎤█`
- 支持选择系统默认输入麦克风
- 支持一键开关开机自启
- 提供 `mkctl` 命令行工具

## 安装位置约定

**必须固定安装到：**

```
/Applications/MicKeepAlive.app
```

原因：macOS 的麦克风权限（TCC）是按应用路径 + Bundle ID 绑定的。如果同一 App 从不同路径启动，系统会把它视为不同应用，导致每次都需要重新授权麦克风。

因此：

- 构建产物必须复制到 `/Applications/MicKeepAlive.app`
- 启动/重启时必须使用 `open /Applications/MicKeepAlive.app`
- 不要直接运行 `build/Release/MicKeepAlive.app` 或二进制文件
- `mkctl` 已链接到 `/usr/local/bin/mkctl`，指向 `/Applications/MicKeepAlive.app/Contents/MacOS/mkctl`

## 麦克风权限

首次启动会弹窗申请麦克风权限，点击「允许」后不再弹窗（只要安装路径保持 `/Applications/MicKeepAlive.app`）。

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
cd /Users/apple/Downloads/MyCode/MicKeepAlive
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

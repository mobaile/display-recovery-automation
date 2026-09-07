# 双显示器自动恢复

这是一个原生 macOS 菜单栏程序，针对“老显示器先上线、新显示器没有枚举”的场景，按可观测状态执行一次恢复：

1. 识别已配置的老显示器和 MSI 模式显示器；
2. 通过小米智能插座关闭老显示器，并等待它离线；
3. 等待 MSI 显示器出现，通过 USB HID 将 `002E0` 写为 `001`（1080P320）；
4. 打开插座，等待老显示器重新枚举且两台都在线；
5. 将 `002E0` 写回 `000`（4K），并确认模式已恢复。

所有等待都由 CoreGraphics 显示器事件和轮询状态驱动，带超时、重试、冷却时间和失败回滚。角色使用 EDID 派生的厂商、型号、序列号和 EDID 哈希匹配，不依赖易变化的显示器编号；身份无法确定时不会自动断电。程序会在模式屏在线时缓存实际刷新率，因此目标暂时离线时不会把 4K144 误认为固定的其他刷新率。

## 支持范围

- macOS 13 或更高版本，非沙盒应用；
- MSI USB HID：VID `0x1462`、PID `0x3FA4`，模式寄存器 `002E0`；
- 小米局域网插座：`chuangmi.plug.212a01`（截图中的二代）和 `cuco.plug.v3`（三代兼容接口）；
- 插座使用 MIoT/miIO UDP 协议，端口默认为 `54321`。Token 只写入 macOS Keychain。

## 构建

```sh
cd /Volumes/resourse/CurCode/display-recovery-automation
swift build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test
./scripts/build.sh
```

`scripts/build.sh` 会生成 `dist/DisplayRecoveryAutomation.app` 和 `dist/display-recovery-cli`，并使用 ad-hoc 签名方便本机运行。当前命令行工具链没有 XCTest 模块时，请使用已安装的 Xcode `DEVELOPER_DIR` 路径运行测试。

## 使用

1. 启动 `dist/DisplayRecoveryAutomation.app`，从菜单栏打开控制面板；
2. 填写插座 IP 和型号，输入 token 后保存。程序会先调用 `miIO.info` 验证实际型号；
3. 在在线显示器列表中分别设置“插座屏”和“模式屏”；
4. 先保持自动恢复关闭，使用“立即恢复双屏”完成一次真实硬件验收；确认流程稳定后再开启自动恢复。

如果同一厂商连接了多台显示器，角色匹配会检测到多个候选并停止自动操作；此时在控制面板重新选择带有完整 EDID 信息的显示器角色。

CLI 只读诊断和控制命令：

```sh
dist/display-recovery-cli displays
dist/display-recovery-cli hid-status
dist/display-recovery-cli plug-info
dist/display-recovery-cli recover
dist/display-recovery-cli export-log
```

`plug-on` 和 `plug-off` 会真实切换插座，只有在确认 IP、型号和 token 正确后才应执行。`recover` 也会执行真实恢复流程，首次使用建议从菜单栏控制面板开始并保持自动恢复关闭。

## 日志和安全

恢复日志写入 `~/Library/Logs/DisplayRecoveryAutomation/recovery.log`。日志不记录 token；导出功能会把 IPv4 地址替换为 `<IP>`。插座命令失败、MSI HID 暂时消失、模式不存在、显示器未重新枚举等情况都会进入 `Failed` 状态，保留安全模式并尝试把插座恢复为开启。

MIoT 协议本身要求使用 MD5 派生 AES-128-CBC 密钥和校验和；这里仅为兼容设备协议，不把 MD5 用作新的安全哈希。

## 目录

- `Sources/DisplayRecoveryCore`：模型和恢复状态机；
- `Sources/MsiHid`：MSI HID 读写；
- `Sources/MiotLocal`：二代、三代插座的局域网客户端；
- `Sources/DisplayRecoveryMac`：CoreGraphics、IOKit、Keychain、配置和日志；
- `Sources/DisplayRecoveryApp`：AppKit 菜单栏界面；
- `Sources/DisplayRecoveryCLI`：诊断及手动恢复命令；
- `Tests`：状态机异常路径、协议输入校验、本地 MIoT UDP 模拟设备、配置和脱敏日志测试。

现有的 `mpg-dual-mode-switcher` 项目不会被本项目修改。

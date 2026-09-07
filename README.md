# 双显示器自动恢复

这是一个原生 macOS 菜单栏程序，针对 macOS 在多显示器启动或热插拔时出现的显示器枚举异常，按可观测状态执行一次恢复。

## macOS 问题背景

在部分 Mac、扩展坞/转接器和双显示器组合中，macOS 启动或唤醒后的显示器发现顺序并不稳定。常见表现是：

- 两台显示器物理上都已通电，但 macOS 只枚举先完成握手的老显示器；
- 第二台显示器没有出现在系统显示器列表中，或只短暂出现后消失；
- 拔插视频线、重启显示器，甚至打开“系统设置 → 显示器”也无法稳定恢复；
- 只有切断已被 macOS 识别的显示器电源，迫使显示链路重新建立，另一台显示器才会出现；
- 第二台显示器恢复后，如果它仍处于 4K 高刷新率模式，macOS 可能再次无法完成双屏握手。

这不是应用层可以通过重新排列窗口或调用一次显示器刷新 API 彻底解决的问题。根因通常位于 macOS 的显示器枚举、EDID 读取、DisplayPort/HDMI 链路训练或转接设备状态之间的时序竞争；具体触发点会随 Mac 型号、系统版本、线材、扩展坞和显示器固件而变化。因此本项目将它视为“可观测的系统级恢复场景”，不宣称存在适用于所有设备的单一 Apple 修复方案。

本项目的目标不是修改 macOS，而是把人工执行的安全恢复动作自动化：暂时让先上线的显示器离线，让 macOS 重新发现另一台显示器；待两台都完成枚举后，再恢复原来的显示模式。

## 处理机制

恢复流程严格按状态机执行，只有确认显示器身份后才允许切换电源：

1. 通过 CoreGraphics 获取当前显示器快照，并用 EDID 派生的厂商、型号、序列号和 EDID 哈希识别两台显示器；不依赖会变化的 `displayID`。
2. 仅在“插座控制的老显示器恰好在线、模式切换显示器明确不在线”时触发，存在多个候选时直接停止，避免误断电。
3. 读取并缓存模式显示器最后一次真实模式（例如 4K144），防止目标暂时离线后把原模式错误当成固定的 4K60。
4. 通过局域网 MIoT/miIO 控制智能插座关闭老显示器，并轮询确认插座已关闭、老显示器已离线。
5. 等待模式显示器重新被 macOS 枚举，然后通过 MSI USB HID 将寄存器 `002E0` 切换到 1080P 安全模式（`001`）。低分辨率模式降低链路训练和双屏重新握手的压力。
6. 打开老显示器电源，等待 macOS 同时枚举两台显示器，并确认它们是两个不同的显示设备。
7. 通过 USB HID 将模式显示器恢复到流程开始前记录的模式（4K 时写回 `000`），再次读取并确认模式已生效。

每个阶段都有超时、轮询和失败状态。流程中途失败时，如果插座曾被关闭，程序会尽力重新打开插座；不会在无法确认显示器身份或原始模式时贸然断电。自动恢复还带有冷却时间，避免显示器事件频繁触发连续切换。

这里的“恢复”是对当前硬件组合的经验性规避方案，不保证修复 macOS 的底层枚举缺陷，也不保证适用于所有 Mac、扩展坞、转接器或显示器。执行前必须确认插座确实只控制目标老显示器，并先使用手动恢复完成真实硬件验收。

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

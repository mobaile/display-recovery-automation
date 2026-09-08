# 双显示器自动恢复

原生 macOS 菜单栏 App 与 CLI，针对 ANT ANT27VU 和 MSI MPG 274U E16M 的显示枚举异常，通过已验证的插座断电与 MSI 双模式切换流程恢复双屏。要求 macOS 13 或更高版本。

## 恢复规则

所有已接管的恢复最终都要回到 MSI 4K。过程中允许临时进入 1080P；成功必须同时满足：两台目标显示器在线且身份明确、MSI HID 读回 UHD、系统显示 MSI 为 4K，并连续稳定 10 秒。旧缓存、缺失模式或 HID 与系统读数矛盾均不能算成功。

无未完成恢复责任时，自动恢复保留这两种手动选择：

- 双屏正常在线，用户手动使用 MSI 1080P。
- ANT 插座关闭，用户单独使用 MSI 1080P。

插座通信失败表示状态未知，不能当作插座关闭或开启。程序自己关闭的供电、自己留下的临时模式，会通过事务记录与手动选择区分。

## 恢复流程

- **只有 ANT 在线：** 同一单屏拓扑稳定 5 秒后，先登记恢复责任，关闭 ANT 插座并确认 ANT 离线；等待 MSI 枚举，重新开启 ANT 插座；给 ANT 最多 10 秒自然上线。自然恢复双屏后直接进入 4K 收尾；仍确认只有 MSI 在线才使用临时 1080P。
- **只有 MSI 在线：** 确认 ANT 插座开启、MSI HID 就绪、目标身份未变化，临时切换 FHD，等待双屏，然后切回 UHD 并验证系统 4K。即使 FHD 阶段等待双屏超时，也要继续进入统一 4K 收尾并完整核验；有些重新枚举会在回切 UHD 后才完成。最终仍缺屏时报告失败。
- **失败、取消、正常退出：** 独立尝试恢复供电和 MSI 4K，每项收尾最多一次写入、各 5 秒总预算。收尾失败会保留责任和具体错误，不会退回 FHD 并宣布完成。
- **重启：** 优先接续未完成收尾，不重发关电或 FHD 起始动作，不重置收尾额度。旧记录缺少目标绑定时阻止自动控制，保留记录供核对。

同一故障最多尝试三次，冷却从每次结束开始计算 30 秒。未完成收尾也会停止新的恢复动作，后续仅按冷却间隔核查和接续尚未使用的收尾额度。重启、保存配置和短暂双屏上线都不清零。双屏和 MSI 4K 持续健康 10 秒，或用户明确重新授权，才能解除停止。

启动、系统唤醒和非恢复期间的模式变化有 10 秒观察期。同一单屏观察窗口会在拓扑换边、歧义、休眠或观测中断时重新开始。时间判断使用单调时钟，系统时间修改不影响运行中的期限。

## 目标、互斥与持久化

通过配置的完整指纹识别显示器，排除内置屏。MSI 别名只能使用明确登记的完整指纹；不会用“同厂商”绕过序列号，不会将任意非 MSI 显示器认作 ANT。

App 自动恢复、手动恢复、重启收尾、CLI 恢复和插座写命令共用进程锁：

```text
~/Library/Application Support/DisplayRecoveryAutomation/recovery.lock
```

HID 查询也会发送 USB 报告，因此需要取得同一锁；锁忙时 CLI 只展示持久化状态。锁覆盖整个恢复与异常收尾，忙状态不会消耗恢复次数。

同目录中的文件：

| 文件 | 用途 |
| --- | --- |
| `config.json` | 版本化角色、插座和恢复配置，不含 Token |
| `secrets.json` | 本地 Token，原子写入且权限为 0600 |
| `recovery-transaction.json` | 第 2 版事务，保存阶段、目标绑定、失败次数、停止状态和收尾额度 |

关键事务必须落盘成功才能操作硬件；读取损坏记录会报错，不会当作空记录重新计数。完成记录提交成功后才清零。事务绑定固定角色和控制配置的不可逆指纹，不能借后来更换的目标或凭据处理旧责任。

普通凭据读取不访问 Keychain。只有用户点击“从 Keychain 导入”才会读取历史凭据，导入后保留 Keychain 原件。设置保存失败时保留草稿；恢复进行中或存在未完成责任时不能替换目标和凭据。关闭自动恢复会取消当前恢复并执行有限收尾。

## 构建与使用

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test -Xswiftc -strict-concurrency=complete
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./scripts/build.sh
```

产物是 `dist/DisplayRecoveryAutomation.app` 和 `dist/display-recovery-cli`。项目仍使用 Swift 5 语言兼容模式，通过完整并发检查验证；miIO 协议规定使用 MD5/AES，相关兼容实现保留协议算法。

```sh
dist/display-recovery-cli displays
dist/display-recovery-cli status
dist/display-recovery-cli diagnose
dist/display-recovery-cli hid-status
dist/display-recovery-cli plug-info
dist/display-recovery-cli recover --dry-run
dist/display-recovery-cli recover
dist/display-recovery-cli plug-on
dist/display-recovery-cli plug-off
dist/display-recovery-cli export-log
```

`recover --dry-run` 与恢复入口共用预检查，只读取状态，不写硬件、事务或恢复次数。真实 `recover` 会等待终态；失败、停止和忙返回非零，取消返回 130。CLI 接收 SIGINT/SIGTERM 后执行有限收尾再退出。SIGKILL 或断电无法执行即时收尾，由下次启动读取持久化责任。

日志位于 `~/Library/Logs/DisplayRecoveryAutomation/recovery.log`。记录事务、阶段、尝试次数与收尾责任，写入前脱敏 IP 和 Token，合并重复消息，超过 2 MB 轮转；导出包含当前和上一份日志。

## 验证范围

本次修复的测试结果、实机经过及未覆盖情形见 [2026-09-08 验收记录](docs/verification-20260908.md)。

自动化测试覆盖恢复正向流程、两种手动 1080P 例外、观测过期和身份歧义、落盘失败、重启接续、三次停止、独立收尾、进程互斥及取消。插座测试使用仅绑定 127.0.0.1 的模拟器，包含已执行命令但应答丢失、静默设备与取消，不控制真实插座。

诊断和 dry-run 只证明预检查可运行。真实恢复验收必须另行记录：初始拓扑、实际执行的电源/模式动作、最终 HID UHD 和系统 4K、双屏持续稳定的证据。软件不能保证修复 macOS 驱动、线缆或显示器本身的故障；不能确认 4K 时会保留未完成责任。

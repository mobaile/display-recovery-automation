# ScreenPilot 验收与验证报告

记录日期：2026-09-08
软件版本：ScreenPilot 1.0.0 (Build 1)
运行环境：macOS (Darwin 24.x / Apple Silicon)

## 一、改造定位与核心核查

本次改造将原有的自动化恢复系统彻底重构为纯手动控制台 ScreenPilot。各项核心要求核验情况如下：

1. 架构定位：
   - 彻底关闭了 RecoveryCoordinator 自动恢复状态机与后台 700ms 轮询计时器。
   - 登录后自动启动应用，常驻菜单栏，但不进行任何主动的硬件操作。
   - 移除自动重试、跨阶段自动链式推进与后台有限收尾。

2. 手动独立执行：
   - 6 个手动按钮各自独立触发单一职责：
     - Turn Off：关闭 ANT 显示器智能插座电源，回读核验。
     - Turn On：开启 ANT 显示器智能插座电源，回读核验。
     - Lower Resolution：通过 MSI HID 写入 FHD 硬件模式，核验硬件寄存器。
     - Restore Full Resolution：通过 MSI HID 写入 UHD 硬件模式，核验硬件寄存器。
     - Check Status：全面检查并输出当前显示器枚举、插座通信与 HID 连接状态。
     - Verify Both Screens：核验双显示器是否全部在线，并检测模式是否满足 4K 且持续稳定 10 秒。
   - Stop 按钮：在任何耗时操作期间可随时取消，取消后立即恢复就绪，绝不追加任何设备收尾写操作。

3. 技术细节隐藏规范：
   - 普通界面（主窗口、设置窗口、状态栏）绝不包含锁文件路径、事务 ID、协议原始十六进制、端口号或底层权限数字。
   - 日志与普通界面绝不记录明文密码与 Token（日志自动应用 IPv4 与 32 位 Token 正则脱敏）。
   - 状态提示统一使用规范英文短语（Ready、Running Turn On...、Success: Power is on.、Cancelled 等）。

## 二、自动化单元与并发测试验证

执行命令：
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test -Xswiftc -strict-concurrency=complete`

测试套件结果汇总：
- DisplayRecoveryCoreTests（59 个测试用例）：全部通过 (0 失败，耗时 0.017 秒)
  - 覆盖 ManualActionRunner 的 6 个手动动作正向执行、重入保护、超时标记为 unconfirmed、取消立即停止无收尾、锁冲突返回 busy。
- DisplayRecoveryPlatformTests（20 个测试用例）：全部通过 (0 失败，耗时 3.584 秒)
  - 覆盖 RecoveryLogStore 内存 500 条截断、2MB 日志轮转、IP/Token 正则脱敏、增量订阅。
  - 覆盖 ConfigurationStore 配置文件与密钥管理、进程锁互斥、MIoT 模拟器通信、HID 协议报文解析。
- DisplayRecoveryAppTests（5 个测试用例）：全部通过 (0 失败，耗时 0.064 秒)
  - 覆盖 AppModel 初始化被动观察、动作互斥防重入、设置保存与锁定互斥、退出取消动作且无收尾。
总计：84 个测试用例全部通过，严格并发模式（strict-concurrency=complete）零警告、零失败。

## 三、命令行 CLI 拦截与功能验证

针对 `./dist/display-recovery-cli` 进行终端命令验证：

1. 自动恢复屏蔽验证：
   - 运行 `./dist/display-recovery-cli recover`
     - 输出：`Error: Automated recovery has been disabled in ScreenPilot. Please use manual actions: plug-on, plug-off, or the ScreenPilot GUI.`
     - 退出码：`1`（成功拦截）
   - 运行 `./dist/display-recovery-cli recover --dry-run`
     - 输出：`Error: Automated recovery has been disabled in ScreenPilot. Please use manual actions: plug-on, plug-off, or the ScreenPilot GUI.`
     - 退出码：`1`（成功拦截）

2. 状态查询与脱敏日志导出验证：
   - 运行 `./dist/display-recovery-cli displays`：正确识别当前在线显示器。
   - 运行 `./dist/display-recovery-cli status`：正常输出显示器与硬件状态摘要，未泄露底层锁与事务信息。
   - 运行 `./dist/display-recovery-cli hid-status`：正确检测当前 USB HID 接口连接状态。
   - 运行 `./dist/display-recovery-cli export-log`：成功将脱敏日志导出为 `screenpilot-log-<timestamp>.txt` 文件，日志中 IP 与 Token 均已替换为脱敏掩码。

## 四、应用构建、签名与安装验证

1. 产物构建：
   - 运行 `./scripts/build.sh`，生成 `dist/ScreenPilot.app` 与 `dist/display-recovery-cli`。
   - 使用 `codesign --verify --deep --strict dist/ScreenPilot.app` 校验通过。

2. 系统安装部署：
   - 目标路径：`/Applications/ScreenPilot.app`。
   - 完成清理与部署，应用签名正常有效。
   - 菜单栏图标与三个核心菜单项正常渲染（Open ScreenPilot…、Settings…、Quit ScreenPilot）。

3. 系统登录项唯一性验证：
   - 通过 macOS AppleScript 管理系统登录项，清理旧的 DisplayRecoveryAutomation 登录项。
   - 新增 `/Applications/ScreenPilot.app`，验证其路径唯一且正常。

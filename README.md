# ScreenPilot 显示控制工具

ScreenPilot 是一款专为双显示器（ANT ANT27VU 与 MSI MPG 274U E16M）环境开发的原生 macOS 菜单栏控制台与 CLI 工具。通过精准的手动操作与硬件通信，用户可按需控制智能插座电源与显示器硬件显示模式。系统要求 macOS 13 或更高版本。

## 核心设计与交互定位

ScreenPilot 彻底关闭了全自动恢复、后台静默轮询、自动重试与链式自动收尾机制。

用户登录 macOS 系统后，程序会自动启动并常驻菜单栏，但绝不主动操作任何显示设备。每一次硬件动作均由用户明确点击或运行命令触发；每个动作只执行自己单一的职责并核验结果，执行完成后静默等待下一次用户指令。在动作执行期间，用户可随时点击停止（Stop）终止操作，停止后程序立即恢复就绪，不追加任何设备收尾动作。

在信息展示方面，ScreenPilot 严格遵守技术细节隐藏规范：面向用户的普通界面与常规日志中，严禁暴露进程互斥锁、事务标识、内部枚举原始值、协议型号编码、端口号与权限数值等底层实现细节；设备密码与 Token 绝不进入日志与普通界面。界面统一使用清晰简明的英文提示（例如 Ready、Running Turn On...、Success: Power is on. 等），便于专业工具定位。

## 界面与功能

ScreenPilot 采用纯原生 AppKit 技术开发，无多余第三方 GUI 依赖。

### 菜单栏入口

程序常驻于 macOS 系统状态栏，菜单项精简为以下三项：

1. Open ScreenPilot…：打开主控制台窗口。
2. Settings…：打开设备与网络设置窗口。
3. Quit ScreenPilot：安全退出应用程序。

### 主控制台窗口

主窗口包含状态区、动作区与执行日志区三个核心部分，窗口具备显示器断开防跑位保护机制：

1. 状态区（Status Section）：
   - 实时展示当前操作状态（就绪、执行中、成功或失败说明）。
   - 被动展示当前系统识别到的显示器拓扑与模式信息。
   - 显示 ANT 与 MSI 角色当前绑定的显示器名称。

2. 动作区（Actions Section）：
   - ANT 显示器控制：
     - Turn Off：关闭 ANT 显示器智能插座电源，并回读核验已处于关闭状态。
     - Turn On：开启 ANT 显示器智能插座电源，并回读核验已处于开启状态。
   - MSI 显示器控制：
     - Lower Resolution：通过 USB HID 接口将 MSI 显示器切换为 FHD 硬件模式，并核验硬件寄存器。
     - Restore Full Resolution：通过 USB HID 接口将 MSI 显示器恢复为 UHD 硬件模式，并核验硬件寄存器。
   - 检测与核验：
     - Check Status：全面检查并输出当前显示器枚举、插座通信与 HID 连接状态。
     - Verify Both Screens：核验双显示器是否全部在线，并检测模式是否满足 4K 且持续稳定 10 秒。
   - 停止按钮：
     - Stop：在任何耗时动作执行期间保持高亮可用，点击后立刻取消执行，不追加任何重试或收尾写操作。

3. 执行日志区（Execution Log Section）：
   - 保留最近 500 条操作记录，支持实时增量滚动跟随（用户向上翻阅时自动暂停滚动，回到底部恢复跟随）。
   - 提供 Copy Log（复制到剪贴板）与 Export Log（导出脱敏日志文件）功能，日志中的 IP 地址与 Token 自动完成脱敏屏蔽。

### 设置窗口

独立的原生设置窗口提供以下配置项：

1. Network Address：智能插座的局域网 IP 地址。
2. Access Key：32 位十六进制设备访问密钥，支持从 macOS Keychain 安全导入历史凭据；留空保存时自动保持原有密钥不变。
3. Display Assignment：分别从当前检测到的显示器下拉列表中选择绑定的 ANT 显示器与 MSI 显示器。
4. 保存保护：保存失败时保留用户输入草稿，不清除用户已录入的内容。保存时强制写入自动恢复禁用标记，杜绝后台恢复逻辑激活。

## 命令行工具（CLI）

项目提供配套命令行工具 `display-recovery-cli`，用于脚本调度与终端诊断：

```sh
# 显示当前连接的显示器信息
./dist/display-recovery-cli displays

# 查询整体状态（显示器、HID 与插座）
./dist/display-recovery-cli status

# 硬件诊断分析
./dist/display-recovery-cli diagnose

# 检查 MSI HID 硬件通信与寄存器状态
./dist/display-recovery-cli hid-status

# 查询智能插座当前硬件信息与开关状态
./dist/display-recovery-cli plug-info

# 手动开启插座电源（接入 ManualActionRunner 统一执行）
./dist/display-recovery-cli plug-on

# 手动关闭插座电源（接入 ManualActionRunner 统一执行）
./dist/display-recovery-cli plug-off

# 导出脱敏后的日志至文本文件
./dist/display-recovery-cli export-log
```

注意：原有的 `recover` 与 `recover --dry-run` 自动恢复命令已在 ScreenPilot 中完全屏蔽。若用户调用该命令，CLI 会明确返回错误提示并以退出码 1 退出，引导用户使用手动动作或图形界面。

## 构建与测试

项目使用 Swift 构建与测试，环境要求配置 Xcode 15+（推荐 Xcode-beta）：

```sh
# 运行全量严格并发测试（84 个用例全部通过）
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test -Xswiftc -strict-concurrency=complete

# 执行构建并产出 App 与 CLI
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./scripts/build.sh
```

构建脚本将产物输出至：
- `dist/ScreenPilot.app`（包含 ad-hoc 临时签名）
- `dist/display-recovery-cli`

## 系统安装与开机自启

ScreenPilot 的固定系统安装位置为：

```text
/Applications/ScreenPilot.app
```

安装部署及更新步骤如下：

1. 退出正在运行的 ScreenPilot 实例。
2. 将构建生成的 `dist/ScreenPilot.app` 复制到 `/Applications/ScreenPilot.app`。
3. 执行代码签名校验：
   ```sh
   codesign --force --deep --sign - /Applications/ScreenPilot.app
   codesign --verify --deep --strict /Applications/ScreenPilot.app
   ```
4. 在 macOS「系统设置 → 通用 → 登录项与扩展 → 登录时打开」中确保仅登记一条 `/Applications/ScreenPilot.app`（可通过系统事件脚本自动维护唯一性）。
5. 启动应用后，程序将在后台就绪，通过顶部菜单栏图标随时提供手动控制。

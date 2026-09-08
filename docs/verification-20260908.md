# 修复与验收记录（2026-09-08）

修复版已构建、签名校验并启动。最终实机检查为双屏在线，MSI 硬件 UHD、系统 3840×2160 @ 120Hz，ANT 3840×2160 @ 30Hz，插座开启；连续稳定验证通过，事务已完成，没有待恢复供电或 4K 责任。该次硬件验收结束时自动恢复配置为关闭，后续启用情况见下节。

## 登录后自动恢复配置（18:08 更新）

- 已将校验通过的发布包安装到 `/Applications/DisplayRecoveryAutomation.app`。安装前后可执行文件 SHA-256 一致，均为文末记录的 `b4fa2819ef285c5e63478ecebe8d6b0b965f9d0e5663d45833e804483215c101`；安装包再次通过严格签名校验。
- 已通过 macOS 原生登录项登记固定安装路径，读回确认数量为 1；系统后台项目记录为 `enabled, allowed, notified`。
- 旧 `dist/` 实例正常退出后，在恢复锁内原子更新 `recovery.automaticRecoveryEnabled` 为 `true`，读回验证除该开关外其余配置一致。原配置备份在本地 `.build/login-startup-20260908/config.before.json`；配置及凭据文件权限均为 0600。
- 18:08:44 从安装目录启动，核对仅有一个 App 进程，实际路径为 `/Applications/DisplayRecoveryAutomation.app/Contents/MacOS/DisplayRecoveryApp`。日志在 18:08:54 记录「双屏在线，MSI 为 4K」，证明启用后的自动观察循环已运行。
- 同次只读显示枚举为 MSI 3840×2160 @ 120Hz、ANT 3840×2160 @ 30Hz；事务保持 `Completed`、尝试次数 0、未停止，供电待恢复和 4K 待恢复均为 false，没有最近错误或收尾错误。正常双屏未触发新的恢复事务。

本次仅安装和启用既有行为，并补充维护说明，没有修改恢复算法。未主动重启、注销或制造单屏故障；真实登录自启动与单屏恢复的联动仍需在后续实际登录场景中核实，不能将本次手动启动等同于已通过重登录验收。

## 本次修复

- 将自动、手动、CLI 和重启收尾统一到同一恢复事务，锁覆盖预检查、设备操作与异常收尾，避免多入口交叉控制。
- 所有已接管恢复都负责回到 MSI 4K；成功要求新鲜 HID UHD 回报、系统实际 4K、双屏身份明确且连续稳定 10 秒。保留正常双屏与 ANT 断电时的手动 1080P 选择。
- 先持久化责任再操作硬件；保存真实阶段、固定目标、三次上限和有限收尾额度。取消、退出、重启和保存配置不会丢失旧责任。
- 用单调期限约束 HID 与插座操作；区分未知、不可用、身份歧义和确认状态，不使用缓存替代硬件读回。
- 接通 App 的取消、睡眠、唤醒和正常退出收尾；设置使用草稿，凭据原子写入并限制为 0600，普通读取不触发 Keychain。
- 实机验收补充发现：FHD 阶段等待双屏超时后，UHD 回切仍可能恢复双屏。因此现在继续完成统一 4K 收尾及完整稳定验证，再决定成功或失败；最终仍缺屏不会算成功，也不会反复切换 FHD。

## 自动化验证

完整并发检查下共 **60 项测试通过，0 失败**：核心模块 45 项，平台模块 15 项。

覆盖 ANT 自然恢复与 FHD 补救、MSI 单屏恢复、两种手动 FHD 例外、缺失或过期观测、身份歧义、HID 不可用、事务读写失败、重启接续、三次停止、取消、独立供电和 4K 收尾、跨进程锁、插座应答丢失与期限。新增用例先复现“ANT 只在回切 UHD 后返回却被判失败”，修复后通过，同时验证 ANT 始终缺失仍失败且只有一次 FHD/UHD 写入。

测试中的插座设备仅为 127.0.0.1 模拟器。硬件恢复状态机的失败场景主要使用虚拟时钟和模拟 I/O；不能将其解释为每一种物理故障都已实测。

命令：

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test -Xswiftc -strict-concurrency=complete
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./scripts/build.sh
codesign --verify --deep --strict dist/DisplayRecoveryAutomation.app
```

Release 构建及签名校验均通过。全量构建中 miIO 兼容算法的 MD5 弃用提示属于协议兼容实现，未替换设备规定算法。

## 实机经过与证据

1. 初始诊断：仅 MSI 在线，硬件 UHD、系统 4K，ANT 插座开启。打包后的只读推演通过。
2. 首次真实恢复：已确认 FHD，等待双屏 30 秒超时，异常收尾切回 UHD。随后独立诊断确认双屏与 MSI 4K 已恢复。该次记录仍为失败，没有将未经 10 秒验证的结果提前记为完成；由此补齐上述最终验证路径。
3. 对照异步主入口与原生主事件循环，在 ANT 插座开关过程中两者都能更新显示器列表，未复现事件循环卡住。
4. 尝试重新构造单屏起始状态时，ANT 断电后在限定观察期内仍被系统枚举。本次检查恢复插座供电后终止，没有据此强行切模；因此不能声称修改后的完整单屏故障路径已再次在实机重现。
5. 最终使用修复后的 Release CLI 验证现有双屏终态：17:53:53 开始稳定验证，17:54:03 记录 `Completed`，进程退出码 0。结束后再次诊断确认 MSI HID 回包 `5b002E0000`（UHD）、MSI 3840×2160 @ 120Hz、ANT 3840×2160 @ 30Hz、插座开启。

最终事务：`EFDC0F9A-AEE6-478A-8C63-FB8736509100`。尝试次数 0，未停止，供电待恢复和 4K 待恢复均为 false。

这次实测覆盖了 FHD 写入、失败时 UHD 收尾以及最终双屏 4K 稳定验证。只有 ANT 在线的完整起始路径、真实 USB 永久失联和强制断电等情形，不能据此宣称已完成物理验收。

原始本地验证输出保存在 `.build/repair-baseline/` 的 `final-tests.log`、`final-release-build.log`、`final-stability-verification.log`、`final-diagnose.log`；源代码及旧发布包备份分别为 `source.tar`、`dist.tar`。

## 发布产物

- `dist/DisplayRecoveryAutomation.app`
- `dist/display-recovery-cli`

SHA-256：

```text
CLI: f8e0e6cc7a903e7504b0ff940dc11ea8dd54a524ad3bdf6cabc4709743374fea
App 可执行文件: b4fa2819ef285c5e63478ecebe8d6b0b965f9d0e5663d45833e804483215c101
```

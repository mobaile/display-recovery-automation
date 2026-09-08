import Foundation
import DisplayRecoveryCore
import DisplayRecoveryMac
import MsiHid
import MiotLocal

@main struct DisplayRecoveryCLI {
    static func main() async {
        do { exit(try await run()) }
        catch { print("错误：\(error.localizedDescription)"); exit(1) }
    }
    private static func run() async throws -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        if ["help", "--help", "-h"].contains(command) { printHelp(); return 0 }
        let provider = MacDisplayProvider()
        if command == "displays" {
            for snapshot in try await provider.checkedSnapshots() { printDisplay(snapshot) }
            return 0
        }
        if command == "export-log" {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("display-recovery-log-\(Int(Date().timeIntervalSince1970)).txt")
            try RecoveryLogStore().exportRedacted(to: url)
            print("已导出脱敏日志：\(url.path)")
            return 0
        }
        let configuration = try ConfigurationStore().load()
        let lock = ProcessTransactionLock()
        let store = FileRecoveryTransactionStore()
        if command == "recover" {
            let hid = MsiHidController()
            let io = PlatformRecoveryIO(displayProvider: provider, hidController: hid,
                plugConfiguration: configuration.plug, recoveryConfiguration: configuration.recovery, token: SecretsStore().readToken())
            let logs = RecoveryLogStore()
            let coordinator = RecoveryCoordinator(io: io, configuration: configuration.recovery,
                transactionStore: store, transactionLock: lock, log: { text in print(text); logs.append(text) })
            let preview = arguments.contains("--dry-run")
            // 信号源将正常中断交给协调器，等待有限收尾后才退出。
            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            for source in [interrupt, terminate] {
                source.setEventHandler { Task { _ = await coordinator.cancelRecovery(reason: "CLI 收到退出信号", suspend: true) } }
                source.resume()
            }
            defer { interrupt.cancel(); terminate.cancel() }
            let outcome = preview ? await coordinator.previewRecovery() : await coordinator.triggerManualRecovery()
            switch outcome {
            case .success: print("恢复完成：双屏在线、MSI 4K 已通过连续稳定验证。"); return 0
            case .failure(let text): print("恢复失败：\(text)"); return 1
            case .stopped(let text): print("已停止：\(text)"); return 1
            case .cancelled(let text): print("已取消并结束有限收尾：\(text)"); return 130
            case .skipped(let text): print("\(preview ? "只读推演" : "未执行恢复")：\(text)"); return preview ? 0 : 1
            case .busy: print("已有其他设备操作在执行。"); return 1
            }
        }
        guard ["status", "diagnose", "hid-status", "plug-info", "plug-on", "plug-off"].contains(command) else {
            printHelp(); return 1
        }
        // HID 查询也发送 USB 报告，因此服从与写操作相同的进程互斥。
        guard lock.tryLock() else {
            print("设备通道正忙；以下为持久化事务记录，未查询硬件。")
            try printTransaction(store)
            return 1
        }
        defer { lock.unlock() }
        let tx = try store.load()
        if command == "plug-on" || command == "plug-off" {
            guard tx?.hasPendingCleanup != true else { throw RecoveryError.operationFailed("存在未完成恢复责任，请先执行 recover") }
            let client = try plug(configuration)
            let limit = RecoveryDeadline(seconds: 10)
            let on = command == "plug-on"
            try await client.setPower(on, expectedModel: configuration.plug.model, deadline: limit)
            guard try await client.getPower(deadline: limit) == on else { throw RecoveryError.operationFailed("插座状态读回不一致") }
            print(on ? "插座已确认开启" : "插座已确认关闭")
            return 0
        }
        if command == "plug-info" {
            let client = try plug(configuration)
            let limit = RecoveryDeadline(seconds: 10)
            let info = try await client.validate(expectedModel: configuration.plug.model, deadline: limit)
            print("型号：\(info.model)")
            print("固件：\(info.firmwareVersion ?? "未知")")
            print("电源：\(try await client.getPower(deadline: limit) ? "开启" : "关闭")")
            return 0
        }
        if command != "hid-status" {
            let snapshots = try await provider.checkedSnapshots()
            for snapshot in snapshots { printDisplay(snapshot) }
            print("ANT：\(description(DisplayRoleResolver.resolve(role: .powerControlled, rolesConfig: configuration.recovery.roles, snapshots: snapshots)))")
            print("MSI：\(description(DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: configuration.recovery.roles, snapshots: snapshots)))")
            try printTransaction(store)
        }
        let hardware = try await MsiHidController().readStatus(deadline: RecoveryDeadline(seconds: 3))
        print("MSI HID：\(hardware.isAmbiguous ? "身份歧义" : (hardware.connected ? "已连接" : "未连接"))；硬件模式：\(hardware.mode.rawValue)")
        print("002E0：\(hardware.rawMode)")
        if command == "diagnose" {
            do {
                let client = try plug(configuration)
                let limit = RecoveryDeadline(seconds: 10)
                _ = try await client.validate(expectedModel: configuration.plug.model, deadline: limit)
                print("插座：\(try await client.getPower(deadline: limit) ? "开启" : "关闭")")
            } catch { print("插座：未知（\(error.localizedDescription)）"); return 1 }
            return hardware.connected && hardware.mode != .unknown && !hardware.isAmbiguous ? 0 : 1
        }
        return 0
    }
    private static func plug(_ configuration: AppConfiguration) throws -> MiotLocalClient {
        guard MiotLocalClient.supportedModels.contains(configuration.plug.model), let token = SecretsStore().readToken() else { throw RecoveryError.plugNotConfigured }
        return try MiotLocalClient(host: configuration.plug.host, token: token, port: configuration.plug.port)
    }
    private static func printDisplay(_ snapshot: DisplaySnapshot) {
        print("[\(snapshot.displayID)] \(snapshot.fingerprint.displayName)\(snapshot.isBuiltin ? " [内置]" : "") · \(snapshot.mode?.shortDescription ?? "模式未知")")
        print("  vendor=\(snapshot.fingerprint.vendor ?? "未知") model=\(snapshot.fingerprint.model ?? "未知") serial=\(snapshot.fingerprint.serial ?? "未知") edid=\(snapshot.fingerprint.edidHash ?? "未知")")
    }
    private static func description(_ result: DisplayResolveResult) -> String {
        switch result {
        case .matched(let snapshot): return "已匹配 \(snapshot.displayID)"
        case .notFound: return "未在线"
        case .unconfigured: return "未配置"
        case .ambiguous(let snapshots): return "存在 \(snapshots.count) 个候选，不能操作"
        }
    }
    private static func printTransaction(_ store: FileRecoveryTransactionStore) throws {
        guard let tx = try store.load() else { print("暂无恢复事务"); return }
        print("事务：\(tx.id)；阶段：\(tx.stage.rawValue)；尝试：\(tx.attemptCount)/3")
        print("已停止：\(tx.isStopped)；供电待恢复：\(tx.powerPendingRestore)；4K 待恢复：\(tx.modePending4K)")
        if let error = tx.lastError { print("最近错误：\(error)") }
        for error in tx.cleanupErrors { print("收尾错误：\(error)") }
    }
    private static func printHelp() {
        print("用法：display-recovery-cli <命令>")
        print("  displays | status | diagnose | hid-status | plug-info")
        print("  recover [--dry-run]  恢复双屏并等待真实终态；dry-run 只读推演")
        print("  plug-on | plug-off  受全局锁保护的手动插座操作")
        print("  export-log          导出脱敏日志")
    }
}

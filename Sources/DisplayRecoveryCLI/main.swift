import Foundation

import DisplayRecoveryCore
import DisplayRecoveryMac
import MsiHid
import MiotLocal

@main
struct DisplayRecoveryCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        let store = ConfigurationStore()
        let appConfiguration = store.load()

        switch command {
        case "help", "--help", "-h":
            printHelp()
        case "displays":
            let provider = MacDisplayProvider()
            for snapshot in provider.snapshots() {
                let mode = snapshot.mode?.shortDescription ?? "未知模式"
                let name = snapshot.fingerprint.displayName.isEmpty ? "未命名显示器" : snapshot.fingerprint.displayName
                print("\(snapshot.displayID): \(name) | \(mode) | \(snapshot.connectionDescription ?? "")")
            }
        case "hid-status":
            let status = MsiHidController().readStatus()
            print("MSI HID：\(status.connected ? "已连接" : "未连接")")
            print("模式：\(status.mode.rawValue)")
            print("002E0：\(status.rawMode)")
            print("00190：\(status.rawConfirmation)")
            print("00500：\(status.rawInputSource)")
        case "plug-info":
            await withPlug(appConfiguration) { client in
                do {
                    let info = try await client.deviceInfo()
                    print("型号：\(info.model)")
                    print("固件：\(info.firmwareVersion ?? "未知")")
                    print("电源：\(try await client.getPower() ? "开启" : "关闭")")
                } catch {
                    print("插座访问失败：\(error.localizedDescription)")
                }
            }
        case "plug-on", "plug-off":
            await withPlug(appConfiguration) { client in
                do {
                    try await client.setPower(command == "plug-on")
                    print(command == "plug-on" ? "插座已开启" : "插座已关闭")
                } catch {
                    print("插座访问失败：\(error.localizedDescription)")
                }
            }
        case "recover":
            await recover(appConfiguration)
        case "export-log":
            let logs = RecoveryLogStore()
            let destination = FileManager.default.currentDirectoryPath
                + "/display-recovery-log-\(Int(Date().timeIntervalSince1970)).txt"
            do {
                try logs.exportRedacted(to: URL(fileURLWithPath: destination))
                print("已导出脱敏日志：\(destination)")
            } catch {
                print("日志导出失败：\(error.localizedDescription)")
            }
        default:
            print("未知命令：\(command)")
            printHelp()
        }
    }

    private static func withPlug(
        _ configuration: AppConfiguration,
        operation: (MiotLocalClient) async -> Void
    ) async {
        guard MiotLocalClient.supportedModels.contains(configuration.plug.model) else {
            print("不支持的插座型号：\(configuration.plug.model)")
            return
        }
        guard let token = try? KeychainStore().readToken(),
              !configuration.plug.host.isEmpty,
              let client = try? MiotLocalClient(
                host: configuration.plug.host,
                token: token,
                port: configuration.plug.port
              ) else {
            print("请先在菜单栏设置中配置插座 IP 和 token")
            return
        }
        do {
            _ = try await client.validate(expectedModel: configuration.plug.model)
        } catch {
            print("插座型号验证失败：\(error.localizedDescription)")
            return
        }
        await operation(client)
    }

    private static func recover(_ configuration: AppConfiguration) async {
        let provider = MacDisplayProvider()
        let hid = MsiHidController()
        let token = (try? KeychainStore().readToken()) ?? nil
        let logStore = RecoveryLogStore()
        let io = PlatformRecoveryIO(
            displayProvider: provider,
            hidController: hid,
            plugConfiguration: configuration.plug,
            recoveryConfiguration: configuration.recovery,
            token: token,
            logStore: logStore
        )
        let coordinator = RecoveryCoordinator(
            io: io,
            configuration: configuration.recovery,
            log: { message in logStore.append(message) }
        )
        await coordinator.triggerManualRecovery()

        for _ in 0..<80 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let status = await coordinator.status()
            print("[\(status.state.rawValue)] \(status.message)")
            if !status.recoveryInProgress {
                break
            }
        }
    }

    private static func printHelp() {
        print("用法：display-recovery-cli <命令>")
        print("  displays    列出在线显示器")
        print("  hid-status  读取 MSI HID 状态")
        print("  plug-info   读取智能插座状态")
        print("  plug-on     打开插座")
        print("  plug-off    关闭插座")
        print("  recover     执行一次双屏恢复")
        print("  export-log  导出脱敏日志")
    }
}

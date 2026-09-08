import Foundation
import DisplayRecoveryCore
import DisplayRecoveryMac
import MsiHid
import MiotLocal

@main struct DisplayRecoveryCLI {
    static func main() async {
        do { exit(try await run()) }
        catch { print("Error: \(error.localizedDescription)"); exit(1) }
    }

    private static func run() async throws -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"

        if ["help", "--help", "-h"].contains(command) {
            printHelp()
            return 0
        }

        // 1. 提前拦截 recover 与 recover --dry-run，明确提示功能已停用并返回非零
        if command == "recover" {
            print("Error: Automated recovery has been disabled in ScreenPilot.")
            print("Please use manual actions: plug-on, plug-off, or the ScreenPilot GUI.")
            return 1
        }

        let provider = MacDisplayProvider()

        if command == "displays" {
            for snapshot in try await provider.checkedSnapshots() {
                printDisplay(snapshot)
            }
            return 0
        }

        if command == "export-log" {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("screenpilot-log-\(Int(Date().timeIntervalSince1970)).txt")
            try RecoveryLogStore().exportRedacted(to: url)
            print("Exported redacted log to: \(url.path)")
            return 0
        }

        let configuration = try ConfigurationStore().load()
        let lock = ProcessTransactionLock()

        // 2. 单独插座操作接入新执行器 ManualActionRunner
        if command == "plug-on" || command == "plug-off" {
            let io = PlatformRecoveryIO(
                displayProvider: provider,
                hidController: MsiHidController(),
                plugConfiguration: configuration.plug,
                recoveryConfiguration: configuration.recovery,
                token: SecretsStore().readToken()
            )
            let runner = ManualActionRunner(
                io: io,
                configuration: configuration.recovery,
                transactionLock: lock
            )
            let action: ManualAction = (command == "plug-on") ? .powerOn : .powerOff
            let result = await runner.execute(action)
            switch result.outcome {
            case .succeeded:
                print("Success: \(result.shortMessage)")
                return 0
            case .failed:
                print("Failed: \(result.shortMessage)")
                if let tech = result.technicalDetails { print("  Details: \(tech)") }
                return 1
            case .unconfirmed:
                print("Unconfirmed: \(result.shortMessage)")
                if let tech = result.technicalDetails { print("  Details: \(tech)") }
                return 1
            case .busy:
                print("Busy: \(result.shortMessage)")
                return 1
            case .cancelled:
                print("Cancelled: \(result.shortMessage)")
                return 130
            }
        }

        guard ["status", "diagnose", "hid-status", "plug-info"].contains(command) else {
            printHelp()
            return 1
        }

        guard lock.tryLock() else {
            print("Device channel is currently busy (held by another action).")
            return 1
        }
        defer { lock.unlock() }

        if command == "plug-info" {
            let client = try plug(configuration)
            let limit = RecoveryDeadline(seconds: 10)
            let info = try await client.validate(expectedModel: configuration.plug.model, deadline: limit)
            print("Model: \(info.model)")
            print("Firmware: \(info.firmwareVersion ?? "Unknown")")
            print("Power: \(try await client.getPower(deadline: limit) ? "On" : "Off")")
            return 0
        }

        if command != "hid-status" {
            let snapshots = try await provider.checkedSnapshots()
            for snapshot in snapshots { printDisplay(snapshot) }
            print("ANT: \(description(DisplayRoleResolver.resolve(role: .powerControlled, rolesConfig: configuration.recovery.roles, snapshots: snapshots)))")
            print("MSI: \(description(DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: configuration.recovery.roles, snapshots: snapshots)))")
        }

        let hardware = try await MsiHidController().readStatus(deadline: RecoveryDeadline(seconds: 3))
        print("MSI HID: \(hardware.isAmbiguous ? "Ambiguous" : (hardware.connected ? "Connected" : "Disconnected")); Hardware Mode: \(hardware.mode.rawValue)")
        print("002E0 Raw: \(hardware.rawMode)")

        if command == "diagnose" {
            do {
                let client = try plug(configuration)
                let limit = RecoveryDeadline(seconds: 10)
                _ = try await client.validate(expectedModel: configuration.plug.model, deadline: limit)
                print("Smart plug: \(try await client.getPower(deadline: limit) ? "On" : "Off")")
            } catch {
                print("Smart plug: Unknown (\(error.localizedDescription))")
                return 1
            }
            return hardware.connected && hardware.mode != .unknown && !hardware.isAmbiguous ? 0 : 1
        }

        return 0
    }

    private static func plug(_ configuration: AppConfiguration) throws -> MiotLocalClient {
        guard MiotLocalClient.supportedModels.contains(configuration.plug.model),
              let token = SecretsStore().readToken() else {
            throw RecoveryError.plugNotConfigured
        }
        return try MiotLocalClient(host: configuration.plug.host, token: token, port: configuration.plug.port)
    }

    private static func printDisplay(_ snapshot: DisplaySnapshot) {
        print("[\(snapshot.displayID)] \(snapshot.fingerprint.displayName)\(snapshot.isBuiltin ? " [Builtin]" : "") · \(snapshot.mode?.shortDescription ?? "Unknown mode")")
        print("  vendor=\(snapshot.fingerprint.vendor ?? "Unknown") model=\(snapshot.fingerprint.model ?? "Unknown") serial=\(snapshot.fingerprint.serial ?? "Unknown") edid=\(snapshot.fingerprint.edidHash ?? "Unknown")")
    }

    private static func description(_ result: DisplayResolveResult) -> String {
        switch result {
        case .matched(let snapshot): return "Matched display \(snapshot.displayID)"
        case .notFound: return "Not detected"
        case .unconfigured: return "Not configured"
        case .ambiguous(let snapshots): return "\(snapshots.count) candidates found"
        }
    }

    private static func printHelp() {
        print("ScreenPilot CLI")
        print("Usage: display-recovery-cli <command>")
        print("  displays | status | diagnose | hid-status | plug-info")
        print("  plug-on | plug-off  Controlled smart plug operations via ManualActionRunner")
        print("  export-log          Export redacted logs to a file")
        print("Note: 'recover' command is disabled in ScreenPilot.")
    }
}

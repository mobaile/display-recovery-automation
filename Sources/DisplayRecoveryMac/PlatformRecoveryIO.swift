import Foundation
import os

import DisplayRecoveryCore
import MsiHid
import MiotLocal

public final class PlatformRecoveryIO: RecoveryIO, @unchecked Sendable {
    private let displayProvider: MacDisplayProvider
    private let hidController: MsiHidController
    private let plugClient: MiotLocalClient?
    private let configuration: RecoveryConfiguration
    private let plugModel: String
    private let logStore: RecoveryLogStore
    private let logger = Logger(subsystem: "local.codex.display-recovery-automation", category: "recovery")
    private let modeCacheLock = NSLock()
    private var lastKnownMode: DisplayModeSignature?

    public init(
        displayProvider: MacDisplayProvider,
        hidController: MsiHidController,
        plugConfiguration: PlugConfiguration,
        recoveryConfiguration: RecoveryConfiguration,
        token: String?,
        logStore: RecoveryLogStore = RecoveryLogStore()
    ) {
        self.displayProvider = displayProvider
        self.hidController = hidController
        self.configuration = recoveryConfiguration
        self.plugModel = plugConfiguration.model
        self.logStore = logStore
        if let token,
           !plugConfiguration.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let client = try? MiotLocalClient(
                host: plugConfiguration.host,
                token: token,
                port: plugConfiguration.port
           ) {
            self.plugClient = client
        } else {
            self.plugClient = nil
        }
    }

    public func displaySnapshots() async -> [DisplaySnapshot] {
        let snapshots = displayProvider.snapshots()
        recordMode(from: snapshots)
        return snapshots
    }

    /// 由菜单栏轮询主动提供最近一次显示器快照，保证在新屏暂时离线时仍能
    /// 保存流程开始前的真实 4K 刷新率。
    public func recordDisplaySnapshots(_ snapshots: [DisplaySnapshot]) {
        recordMode(from: snapshots)
    }

    public func setPlugPower(_ on: Bool) async throws {
        guard let plugClient else {
            throw RecoveryError.plugNotConfigured
        }
        guard MiotLocalClient.supportedModels.contains(plugModel) else {
            throw RecoveryError.plugModelMismatch(expected: plugModel, actual: "不支持的型号")
        }
        logger.info("设置智能插座电源：\(on ? "开启" : "关闭")")
        logStore.append("设置智能插座电源：\(on ? "开启" : "关闭")")
        do {
            _ = try await plugClient.validate(expectedModel: plugModel)
            try await plugClient.setPower(on)
            logStore.append("智能插座命令已返回")
        } catch let error as RecoveryError {
            logStore.append("智能插座命令失败：\(error.localizedDescription)")
            throw error
        } catch {
            logStore.append("智能插座命令失败：\(error.localizedDescription)")
            throw RecoveryError.plugUnavailable(error.localizedDescription)
        }
    }

    public func readPlugPower() async throws -> Bool {
        guard let plugClient else {
            throw RecoveryError.plugNotConfigured
        }
        guard MiotLocalClient.supportedModels.contains(plugModel) else {
            throw RecoveryError.plugModelMismatch(expected: plugModel, actual: "不支持的型号")
        }
        do {
            _ = try await plugClient.validate(expectedModel: plugModel)
            return try await plugClient.getPower()
        } catch let error as RecoveryError {
            throw error
        } catch {
            throw RecoveryError.plugUnavailable(error.localizedDescription)
        }
    }

    public func readModeSwitchMode() async throws -> DisplayModeSignature? {
        let snapshots = displayProvider.snapshots()
        recordMode(from: snapshots)
        if let snapshot = snapshots.first(where: {
            configuration.roles.modeSwitch.matches($0.fingerprint)
        }), let mode = snapshot.mode {
            return mode
        }

        let cachedMode = cachedMode()
        let status = hidController.readStatus(retries: 1)
        guard status.connected else { return nil }
        switch status.mode {
        case .uhd:
            if let cachedMode,
               cachedMode.width >= 3000,
               cachedMode.height >= 1800 {
                return cachedMode
            }
            return DisplayModeSignature(width: 3840, height: 2160, refreshRate: 0)
        case .fhd:
            if let cachedMode,
               cachedMode.width == 1920,
               cachedMode.height == 1080 {
                return cachedMode
            }
            return MsiDualMode.fhd.displayMode
        case .unknown:
            return nil
        }
    }

    public func setModeSwitchSafeMode() async throws {
        guard hidController.setMode(.fhd) else {
            throw RecoveryError.monitorUnavailable
        }
    }

    public func restoreModeSwitchMode(_ mode: DisplayModeSignature) async throws {
        let target: MsiDualMode
        if mode.width >= 3000 && mode.height >= 1800 {
            target = .uhd
        } else if mode.width == 1920 && mode.height == 1080 {
            target = .fhd
        } else {
            throw RecoveryError.modeNotAvailable(mode)
        }
        guard hidController.setMode(target) else {
            throw RecoveryError.monitorUnavailable
        }
    }

    private func recordMode(from snapshots: [DisplaySnapshot]) {
        guard let mode = snapshots.first(where: {
            configuration.roles.modeSwitch.matches($0.fingerprint) &&
                $0.online && $0.mode != nil
        })?.mode else { return }
        modeCacheLock.lock()
        lastKnownMode = mode
        modeCacheLock.unlock()
    }

    private func cachedMode() -> DisplayModeSignature? {
        modeCacheLock.lock()
        defer { modeCacheLock.unlock() }
        return lastKnownMode
    }
}

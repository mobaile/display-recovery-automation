import AppKit
import Combine
import Foundation

import DisplayRecoveryCore
import DisplayRecoveryMac
import MsiHid

@MainActor
final class AppModel: ObservableObject {
    @Published var appConfiguration: AppConfiguration
    @Published var tokenInput: String
    @Published private(set) var tokenConfigured: Bool
    @Published private(set) var snapshots: [DisplaySnapshot] = []
    @Published private(set) var recoveryStatus = RecoveryStatus()
    @Published private(set) var msiStatus: MsiHidStatus?
    @Published private(set) var plugStateText = "未配置"
    @Published private(set) var lastError: String?

    private let configurationStore = ConfigurationStore()
    private let keychainStore = KeychainStore()
    private let displayProvider = MacDisplayProvider()
    private let hidController = MsiHidController()
    private let logStore = RecoveryLogStore()
    private var platformIO: PlatformRecoveryIO?
    private var coordinator: RecoveryCoordinator?
    private var refreshTask: Task<Void, Never>?
    private var lastPlugRefresh = Date.distantPast

    init() {
        appConfiguration = configurationStore.load()
        let initialToken = (try? keychainStore.readToken()) ?? ""
        tokenInput = initialToken
        tokenConfigured = !initialToken.isEmpty
        rebuildCoordinator()

        displayProvider.startObserving { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refresh()
                await self.coordinator?.notifyDisplaysChanged()
            }
        }

        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        displayProvider.stopObserving()
    }

    var automaticRecoveryEnabled: Bool {
        get { appConfiguration.recovery.automaticRecoveryEnabled }
        set {
            guard !recoveryStatus.recoveryInProgress else {
                lastError = "恢复进行中，暂不能修改设置"
                return
            }
            appConfiguration.recovery.automaticRecoveryEnabled = newValue
            saveConfiguration()
        }
    }

    func refresh() async {
        snapshots = displayProvider.snapshots()
        platformIO?.recordDisplaySnapshots(snapshots)
        if let coordinator {
            recoveryStatus = await coordinator.status()
        }

        msiStatus = await Task.detached(priority: .utility) { [hidController] in
            hidController.readStatus(retries: 0)
        }.value

        if Date().timeIntervalSince(lastPlugRefresh) >= 4 {
            lastPlugRefresh = Date()
            await refreshPlugState()
        }
    }

    func triggerRecovery() {
        guard !recoveryStatus.recoveryInProgress else { return }
        guard let coordinator else {
            lastError = "恢复服务尚未初始化"
            return
        }
        Task { await coordinator.triggerManualRecovery() }
    }

    func resetStatus() {
        Task { await coordinator?.resetStatus() }
    }

    func saveConfiguration() {
        guard !recoveryStatus.recoveryInProgress else {
            lastError = "恢复进行中，暂不能保存设置"
            return
        }
        do {
            try configurationStore.save(appConfiguration)
            if !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try keychainStore.saveToken(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines))
                tokenConfigured = true
            }
            rebuildCoordinator()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteToken() {
        guard !recoveryStatus.recoveryInProgress else {
            lastError = "恢复进行中，暂不能修改 Token"
            return
        }
        do {
            try keychainStore.deleteToken()
            tokenInput = ""
            tokenConfigured = false
            rebuildCoordinator()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func exportRedactedLog() -> URL? {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let destination = desktop.appendingPathComponent("display-recovery-log-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try logStore.exportRedacted(to: destination)
            lastError = nil
            return destination
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func useAsPowerControlled(_ snapshot: DisplaySnapshot) {
        guard !recoveryStatus.recoveryInProgress else {
            lastError = "恢复进行中，暂不能修改显示器角色"
            return
        }
        appConfiguration.recovery.roles.powerControlled = snapshot.fingerprint
        saveConfiguration()
    }

    func useAsModeSwitch(_ snapshot: DisplaySnapshot) {
        guard !recoveryStatus.recoveryInProgress else {
            lastError = "恢复进行中，暂不能修改显示器角色"
            return
        }
        appConfiguration.recovery.roles.modeSwitch = snapshot.fingerprint
        saveConfiguration()
    }

    func clearPowerControlledRole() {
        guard !recoveryStatus.recoveryInProgress else {
            lastError = "恢复进行中，暂不能修改显示器角色"
            return
        }
        appConfiguration.recovery.roles.powerControlled = DisplayFingerprint()
        saveConfiguration()
    }

    func clearModeSwitchRole() {
        guard !recoveryStatus.recoveryInProgress else {
            lastError = "恢复进行中，暂不能修改显示器角色"
            return
        }
        appConfiguration.recovery.roles.modeSwitch = DisplayFingerprint()
        saveConfiguration()
    }

    func roleName(_ role: DisplayRole) -> String {
        let fingerprint: DisplayFingerprint
        switch role {
        case .powerControlled:
            fingerprint = appConfiguration.recovery.roles.powerControlled
        case .modeSwitch:
            fingerprint = appConfiguration.recovery.roles.modeSwitch
        }
        return fingerprint.displayName.isEmpty ? "未配置" : fingerprint.displayName
    }

    func roleSnapshot(_ role: DisplayRole) -> DisplaySnapshot? {
        let fingerprint: DisplayFingerprint
        switch role {
        case .powerControlled:
            fingerprint = appConfiguration.recovery.roles.powerControlled
        case .modeSwitch:
            fingerprint = appConfiguration.recovery.roles.modeSwitch
        }
        guard fingerprint.isConfigured else { return nil }
        let matches = snapshots.filter { fingerprint.matches($0.fingerprint) }
        return matches.count == 1 ? matches[0] : nil
    }

    private func refreshPlugState() async {
        guard let platformIO else {
            plugStateText = "未配置"
            return
        }
        do {
            plugStateText = try await platformIO.readPlugPower() ? "已开启" : "已关闭"
        } catch {
            plugStateText = "不可用"
        }
    }

    private func rebuildCoordinator() {
        let token = (try? keychainStore.readToken()) ?? tokenInput
        let io = PlatformRecoveryIO(
            displayProvider: displayProvider,
            hidController: hidController,
            plugConfiguration: appConfiguration.plug,
            recoveryConfiguration: appConfiguration.recovery,
            token: token.isEmpty ? nil : token,
            logStore: logStore
        )
        platformIO = io
        coordinator = RecoveryCoordinator(
            io: io,
            configuration: appConfiguration.recovery,
            log: { [logStore] message in logStore.append(message) }
        )
    }
}

private extension DisplayFingerprint {
    var isConfigured: Bool {
        [vendor, model, serial, edidHash].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

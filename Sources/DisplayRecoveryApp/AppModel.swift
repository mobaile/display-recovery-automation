import AppKit
import Combine
import Foundation
import DisplayRecoveryCore
import DisplayRecoveryMac
import MsiHid
import MiotLocal

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var appConfiguration: AppConfiguration
    @Published private(set) var tokenConfigured: Bool
    @Published private(set) var snapshots: [DisplaySnapshot] = []
    @Published private(set) var recoveryStatus = RecoveryStatus()
    @Published private(set) var msiStatus: MsiHidStatus?
    @Published private(set) var plugStateText = "未配置"
    @Published private(set) var lastError: String?
    @Published private(set) var settingsBusy = false

    private let configurationStore = ConfigurationStore()
    private let secretsStore = SecretsStore()
    private let displayProvider = MacDisplayProvider()
    private let hidController = MsiHidController()
    private let logStore = RecoveryLogStore()
    private let transactionStore = FileRecoveryTransactionStore()
    private let processLock = ProcessTransactionLock()
    private var platformIO: PlatformRecoveryIO!
    private var coordinator: RecoveryCoordinator!
    private var refreshTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastHardwareRefresh: TimeInterval = -10
    private var refreshing = false
    private var terminating = false
    private var configurationLoadFailed = false

    init() {
        let (configuration, error) = configurationStore.loadOrRecover()
        appConfiguration = configuration
        tokenConfigured = secretsStore.readToken() != nil
        configurationLoadFailed = error != nil
        lastError = error?.localizedDescription
        rebuildCoordinator()
        displayProvider.startObserving { [weak self] in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        let notifications = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(notifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in _ = await self?.coordinator.cancelRecovery(reason: "系统即将休眠", suspend: true) }
        })
        workspaceObservers.append(notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.coordinator.notifySystemWokeUp()
                await self?.refresh()
            }
        })
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .milliseconds(700)) } catch { break }
            }
        }
    }

    var automaticRecoveryEnabled: Bool {
        get { appConfiguration.recovery.automaticRecoveryEnabled }
        set {
            guard !settingsBusy, !configurationLoadFailed else { return }
            let old = appConfiguration
            var updated = old
            updated.recovery.automaticRecoveryEnabled = newValue
            do {
                try configurationStore.save(updated)
                appConfiguration = updated
                Task { await coordinator.setAutomaticRecoveryEnabled(newValue) }
            } catch { lastError = error.localizedDescription }
        }
    }

    func refresh() async {
        guard !refreshing, !terminating else { return }
        refreshing = true
        defer { refreshing = false }
        do { snapshots = try displayProvider.checkedSnapshots() }
        catch { lastError = error.localizedDescription }
        recoveryStatus = await coordinator.status()
        // 只有空闲且取得全局锁时才主动采样；恢复期间读取已发布的缓存。
        let now = SystemRecoveryClock().monotonicNow
        if now - lastHardwareRefresh >= 4, !(await coordinator.isBusy()), !settingsBusy, processLock.tryLock() {
            lastHardwareRefresh = now
            do {
                let status = try await hidController.readStatus(deadline: RecoveryDeadline(seconds: 2))
                msiStatus = status
            } catch { msiStatus = MsiHidStatus(connected: false) }
            do { plugStateText = try await platformIO.readPlugPower() ? "已开启" : "已关闭" }
            catch { plugStateText = "未知（无法读取）" }
            processLock.unlock()
        } else {
            let cached = hidController.cachedStatus()
            msiStatus = now - cached.observedAt <= 5 ? cached : nil
        }
        if !configurationLoadFailed, !settingsBusy { await coordinator.pollAutomaticRecovery() }
    }

    func triggerRecovery() {
        guard !settingsBusy, !configurationLoadFailed else { return }
        Task {
            let result = await coordinator.triggerManualRecovery()
            show(result)
            await refresh()
        }
    }
    func cancelRecovery() {
        Task {
            if let result = await coordinator.cancelRecovery(reason: "用户取消恢复") { show(result) }
            await refresh()
        }
    }
    func clearStop() {
        Task {
            if !(await coordinator.clearStop()) { lastError = "恢复服务忙，或无法保存解除停止状态" }
            await refresh()
        }
    }
    func shutdown() async {
        terminating = true
        refreshTask?.cancel()
        displayProvider.stopObserving()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        _ = await coordinator.cancelRecovery(reason: "应用正常退出", suspend: true)
    }

    func saveSettings(model: String, host: String, token: String, completion: @escaping @MainActor (Bool) -> Void) {
        var updated = appConfiguration
        updated.plug.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.plug.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        commitSettings(updated, token: token.isEmpty ? nil : token, completion: completion)
    }
    func useAsPowerControlled(_ snapshot: DisplaySnapshot) {
        guard !snapshot.isBuiltin else { return }
        var updated = appConfiguration
        updated.recovery.roles.powerControlled = snapshot.fingerprint
        commitSettings(updated)
    }
    func useAsModeSwitch(_ snapshot: DisplaySnapshot) {
        guard !snapshot.isBuiltin else { return }
        var updated = appConfiguration
        updated.recovery.roles.modeSwitch = snapshot.fingerprint
        updated.recovery.roles.modeSwitchAliases = []
        commitSettings(updated)
    }
    func importLegacyKeychainToken() {
        mutateSettings {
            guard let token = try self.secretsStore.migrateFromKeychainExplicitly() else {
                throw ConfigurationStoreError.migrationFailed("未找到历史 Token")
            }
            _ = try MiotLocalClient(host: self.appConfiguration.plug.host, token: token, port: self.appConfiguration.plug.port)
        }
    }
    func deleteToken() { mutateSettings { try self.secretsStore.deleteToken() } }

    private func commitSettings(_ updated: AppConfiguration, token: String? = nil, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        mutateSettings(completion: completion) {
            guard MiotLocalClient.supportedModels.contains(updated.plug.model) else {
                throw ConfigurationStoreError.corruptedConfiguration("不支持的插座型号")
            }
            if !updated.plug.host.isEmpty {
                _ = try MiotLocalClient(host: updated.plug.host, token: token ?? self.secretsStore.readToken() ?? String(repeating: "0", count: 32), port: updated.plug.port)
            }
            let previous = self.appConfiguration
            try self.configurationStore.save(updated)
            do { if let token { try self.secretsStore.saveToken(token) } }
            catch {
                try self.configurationStore.save(previous)
                throw error
            }
            self.appConfiguration = updated
            self.configurationLoadFailed = false
        }
    }
    private func mutateSettings(completion: @escaping @MainActor (Bool) -> Void = { _ in }, _ mutation: @escaping @MainActor () throws -> Void) {
        guard !settingsBusy, !terminating else { completion(false); return }
        settingsBusy = true
        Task {
            var succeeded = false
            defer { settingsBusy = false; completion(succeeded) }
            _ = await coordinator.status()
            guard await coordinator.retireForConfigurationChange() else {
                lastError = "恢复正在进行或仍有未完成责任，暂不能更改目标与凭据"
                return
            }
            guard processLock.tryLock() else {
                await coordinator.resumeAfterConfigurationFailure()
                lastError = "其他进程正在使用设备，暂不能更改设置"
                return
            }
            defer { processLock.unlock() }
            do {
                guard try transactionStore.load()?.hasPendingCleanup != true else {
                    throw RecoveryError.operationFailed("存在未完成事务，必须先处理恢复责任")
                }
                try mutation()
                tokenConfigured = secretsStore.readToken() != nil
                rebuildCoordinator()
                lastError = nil
                succeeded = true
            } catch {
                await coordinator.resumeAfterConfigurationFailure()
                lastError = error.localizedDescription
            }
        }
    }
    private func show(_ result: RecoveryOutcome) {
        switch result {
        case .success: lastError = nil
        case .failure(let text), .stopped(let text), .skipped(let text), .cancelled(let text): lastError = text
        case .busy: lastError = "已有恢复或设备操作在执行"
        }
    }
    func roleName(_ role: DisplayRole) -> String {
        let fp = role == .powerControlled ? appConfiguration.recovery.roles.powerControlled : appConfiguration.recovery.roles.modeSwitch
        return fp.displayName.isEmpty ? "未配置" : fp.displayName
    }
    func exportRedactedLog() -> URL? {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let destination = desktop.appendingPathComponent("display-recovery-log-\(Int(Date().timeIntervalSince1970)).txt")
        do { try logStore.exportRedacted(to: destination); return destination }
        catch { lastError = error.localizedDescription; return nil }
    }
    private func rebuildCoordinator() {
        platformIO = PlatformRecoveryIO(displayProvider: displayProvider, hidController: hidController,
            plugConfiguration: appConfiguration.plug, recoveryConfiguration: appConfiguration.recovery, token: secretsStore.readToken())
        coordinator = RecoveryCoordinator(io: platformIO, configuration: appConfiguration.recovery,
            transactionStore: transactionStore, transactionLock: processLock,
            log: { [logStore] message in logStore.append(message) })
    }
}

import AppKit
import Combine
import Foundation
import DisplayRecoveryCore
import DisplayRecoveryMac
import MsiHid
import MiotLocal

public enum AntDisplayState: String, CaseIterable, Equatable, Sendable {
    case on
    case off
    case unknown
}

public enum MsiDisplayState: String, CaseIterable, Equatable, Sendable {
    case fullResolution
    case lowerResolution
    case unknown
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var appConfiguration: AppConfiguration
    @Published public private(set) var tokenConfigured: Bool
    @Published public private(set) var snapshots: [DisplaySnapshot] = []
    @Published public private(set) var antState: AntDisplayState = .unknown
    @Published public private(set) var msiState: MsiDisplayState = .unknown
    @Published public private(set) var currentAction: ManualAction?
    @Published public private(set) var lastActionResult: ManualActionResult?
    @Published public private(set) var isBusy: Bool = false
    @Published public private(set) var statusMessage: String = "Ready"
    @Published public private(set) var lastError: String?
    @Published public private(set) var settingsBusy: Bool = false
    @Published public private(set) var logs: [String] = []

    private let configurationStore: ConfigurationStore
    private let secretsStore: SecretsStore
    private let displayProvider: MacDisplayProvider
    private let hidController: MsiHidController
    private let logStore: RecoveryLogStore
    private let processLock: any RecoveryTransactionLockProtocol

    private var platformIO: (any RecoveryIO)?
    private var actionRunner: ManualActionRunner!
    private var logSubscriberId: UUID?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var terminating = false

    public init() {
        let configStore = ConfigurationStore()
        let secStore = SecretsStore()
        let dispProvider = MacDisplayProvider()
        let hidCtrl = MsiHidController()
        let logger = RecoveryLogStore()
        let lock = ProcessTransactionLock()

        self.configurationStore = configStore
        self.secretsStore = secStore
        self.displayProvider = dispProvider
        self.hidController = hidCtrl
        self.logStore = logger
        self.processLock = lock

        let (config, error) = configStore.loadOrRecover()
        self.appConfiguration = config
        self.tokenConfigured = secStore.readToken() != nil
        self.lastError = error?.localizedDescription

        initCommon()
    }

    public init(
        configurationStore: ConfigurationStore,
        secretsStore: SecretsStore,
        displayProvider: MacDisplayProvider,
        hidController: MsiHidController,
        logStore: RecoveryLogStore,
        processLock: any RecoveryTransactionLockProtocol,
        io: (any RecoveryIO)? = nil,
        actionRunner: ManualActionRunner? = nil
    ) {
        self.configurationStore = configurationStore
        self.secretsStore = secretsStore
        self.displayProvider = displayProvider
        self.hidController = hidController
        self.logStore = logStore
        self.processLock = processLock
        self.platformIO = io
        self.actionRunner = actionRunner

        let (config, error) = configurationStore.loadOrRecover()
        self.appConfiguration = config
        self.tokenConfigured = secretsStore.readToken() != nil
        self.lastError = error?.localizedDescription

        initCommon()
    }

    private func initCommon() {
        logs = logStore.recentLogs()
        logSubscriberId = logStore.subscribe { [weak self] line in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logs.append(line)
                if self.logs.count > 500 {
                    self.logs.removeFirst(self.logs.count - 500)
                }
            }
        }

        rebuildRunner()
        refreshSnapshots()
        Task { @MainActor [weak self] in
            await self?.syncDeviceStates()
        }

        displayProvider.startObserving { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshSnapshots()
            }
        }

        let notifications = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            notifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.actionRunner.cancel()
                }
            }
        )
        workspaceObservers.append(
            notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshSnapshots()
                    await self?.syncDeviceStates()
                }
            }
        )
    }

    public func updateDisplayDerivedStates() {
        // 1. MSI display state
        let msiMatch = DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: appConfiguration.recovery.roles, snapshots: snapshots)
        if case .matched(let s) = msiMatch {
            if s.mode?.is4K == true {
                msiState = .fullResolution
            } else if s.mode?.is1080P == true {
                msiState = .lowerResolution
            } else {
                let hw = hidController.cachedStatus()
                if hw.mode == .uhd {
                    msiState = .fullResolution
                } else if hw.mode == .fhd {
                    msiState = .lowerResolution
                } else {
                    msiState = .unknown
                }
            }
        } else {
            let hw = hidController.cachedStatus()
            if hw.mode == .uhd {
                msiState = .fullResolution
            } else if hw.mode == .fhd {
                msiState = .lowerResolution
            } else {
                msiState = .unknown
            }
        }

        // 2. ANT display state
        let antMatch = DisplayRoleResolver.resolve(role: .powerControlled, rolesConfig: appConfiguration.recovery.roles, snapshots: snapshots)
        if case .matched(let s) = antMatch, s.online {
            antState = .on
        } else if case .notFound = antMatch {
            antState = .off
        }
    }

    public func syncDeviceStates() async {
        guard !terminating else { return }
        updateDisplayDerivedStates()

        if tokenConfigured, let io = platformIO {
            if let plugPower = try? await io.readPlugPower(deadline: RecoveryDeadline(seconds: 3)) {
                antState = plugPower ? .on : .off
            }
        }

        if let io = platformIO {
            if let hw = try? await io.readHardwareMode(deadline: RecoveryDeadline(seconds: 3)) {
                if hw.mode == .uhd {
                    msiState = .fullResolution
                } else if hw.mode == .fhd {
                    msiState = .lowerResolution
                }
            }
        }
    }

    public func refreshSnapshots() {
        guard !terminating else { return }
        do {
            snapshots = try displayProvider.checkedSnapshots()
        } catch {
            lastError = error.localizedDescription
        }
        updateDisplayDerivedStates()
    }

    public func execute(_ action: ManualAction) {
        guard !isBusy, !settingsBusy, !terminating else { return }
        isBusy = true
        currentAction = action
        statusMessage = "Running \(action.displayName)..."
        lastError = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.actionRunner.execute(action)
            self.lastActionResult = result
            self.currentAction = nil
            self.isBusy = false
            self.statusMessage = result.shortMessage
            if result.outcome == .failed {
                self.lastError = result.shortMessage
            }
            if result.outcome == .succeeded {
                switch action {
                case .powerOff:
                    self.antState = .off
                case .powerOn:
                    self.antState = .on
                case .lowerResolution:
                    self.msiState = .lowerResolution
                case .restoreFullResolution:
                    self.msiState = .fullResolution
                case .checkStatus, .verifyBothScreens:
                    break
                }
            }
            self.refreshSnapshots()
            await self.syncDeviceStates()
        }
    }

    public func stop() {
        Task {
            await actionRunner.cancel()
        }
    }

    public func shutdown() async {
        terminating = true
        if let id = logSubscriberId {
            logStore.unsubscribe(id)
        }
        displayProvider.stopObserving()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        await actionRunner.cancel()
    }

    public func saveSettings(
        host: String,
        token: String,
        powerFingerprint: DisplayFingerprint? = nil,
        modeFingerprint: DisplayFingerprint? = nil,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        guard !isBusy, !settingsBusy, !terminating else {
            lastError = "Another action is running."
            completion(false)
            return
        }
        settingsBusy = true
        Task { @MainActor [weak self] in
            guard let self else { completion(false); return }
            defer { self.settingsBusy = false }

            guard self.processLock.tryLock() else {
                self.lastError = "Another action is running."
                completion(false)
                return
            }
            defer { self.processLock.unlock() }

            var updated = self.appConfiguration
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedHost.isEmpty {
                updated.plug.host = trimmedHost
            }
            if let powerFingerprint {
                updated.recovery.roles.powerControlled = powerFingerprint
            }
            if let modeFingerprint {
                updated.recovery.roles.modeSwitch = modeFingerprint
                updated.recovery.roles.modeSwitchAliases = []
            }
            updated.recovery.automaticRecoveryEnabled = false

            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                if !trimmedToken.isEmpty {
                    try self.secretsStore.saveToken(trimmedToken)
                }
                try self.configurationStore.saveManualConfiguration(updated)
                self.appConfiguration = updated
                self.tokenConfigured = self.secretsStore.readToken() != nil
                self.platformIO = nil
                self.rebuildRunner()
                self.lastError = nil
                completion(true)
            } catch {
                self.lastError = error.localizedDescription
                completion(false)
            }
        }
    }

    public func roleName(_ role: DisplayRole) -> String {
        let fp = role == .powerControlled ? appConfiguration.recovery.roles.powerControlled : appConfiguration.recovery.roles.modeSwitch
        return fp.displayName.isEmpty ? "Unassigned" : fp.displayName
    }

    public func useAsPowerControlled(_ snapshot: DisplaySnapshot) {
        guard !snapshot.isBuiltin else { return }
        saveSettings(host: appConfiguration.plug.host, token: "", powerFingerprint: snapshot.fingerprint)
    }

    public func useAsModeSwitch(_ snapshot: DisplaySnapshot) {
        guard !snapshot.isBuiltin else { return }
        saveSettings(host: appConfiguration.plug.host, token: "", modeFingerprint: snapshot.fingerprint)
    }

    public func importLegacyKeychainToken() {
        guard !isBusy, !settingsBusy, !terminating else { return }
        do {
            guard try secretsStore.migrateFromKeychainExplicitly() != nil else {
                lastError = "No legacy token found in Keychain."
                return
            }
            tokenConfigured = true
            platformIO = nil
            rebuildRunner()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func deleteToken() {
        guard !isBusy, !settingsBusy, !terminating else { return }
        do {
            try secretsStore.deleteToken()
            tokenConfigured = false
            platformIO = nil
            rebuildRunner()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func exportRedactedLog() -> URL? {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let destination = desktop.appendingPathComponent("screenpilot-log-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try logStore.exportRedacted(to: destination)
            return destination
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func rebuildRunner() {
        if platformIO == nil {
            platformIO = PlatformRecoveryIO(
                displayProvider: displayProvider,
                hidController: hidController,
                plugConfiguration: appConfiguration.plug,
                recoveryConfiguration: appConfiguration.recovery,
                token: secretsStore.readToken(),
                logStore: logStore
            )
        }
        actionRunner = ManualActionRunner(
            io: platformIO,
            configuration: appConfiguration.recovery,
            transactionLock: processLock,
            log: { [weak self] event in
                switch event {
                case .started(let act):
                    self?.logStore.append("Started: \(act.displayName)")
                case .step(let msg):
                    self?.logStore.append(msg)
                case .finished(_, let outcome, let msg, let tech):
                    let outcomeStr: String
                    switch outcome {
                    case .succeeded: outcomeStr = "Success"
                    case .failed: outcomeStr = "Failed"
                    case .unconfirmed: outcomeStr = "Unconfirmed"
                    case .cancelled: outcomeStr = "Cancelled"
                    case .busy: outcomeStr = "Busy"
                    }
                    if let tech, !tech.isEmpty {
                        self?.logStore.append("\(outcomeStr): \(msg) (\(tech))")
                    } else {
                        self?.logStore.append("\(outcomeStr): \(msg)")
                    }
                }
            }
        )
    }
}

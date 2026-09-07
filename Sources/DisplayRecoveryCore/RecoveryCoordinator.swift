import Foundation

public actor RecoveryCoordinator {
    private let io: RecoveryIO
    private var configuration: RecoveryConfiguration
    private var currentStatus = RecoveryStatus()
    private var lastAttemptAt: Date?
    private var plugWasTurnedOff = false
    private let log: (@Sendable (String) -> Void)?

    public init(
        io: RecoveryIO,
        configuration: RecoveryConfiguration = RecoveryConfiguration(),
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.io = io
        self.configuration = configuration
        self.log = log
    }

    public func status() -> RecoveryStatus {
        currentStatus
    }

    public func currentConfiguration() -> RecoveryConfiguration {
        configuration
    }

    public func updateConfiguration(_ configuration: RecoveryConfiguration) {
        self.configuration = configuration
    }

    public func notifyDisplaysChanged() {
        guard configuration.automaticRecoveryEnabled else { return }
        Task { [weak self] in
            await self?.evaluateAndRecoverIfNeeded()
        }
    }

    public func triggerManualRecovery() {
        Task { [weak self] in
            await self?.evaluateAndRecoverIfNeeded(force: true)
        }
    }

    public func resetStatus() {
        guard !currentStatus.recoveryInProgress else { return }
        currentStatus = RecoveryStatus()
    }

    private func evaluateAndRecoverIfNeeded(force: Bool = false) async {
        guard !currentStatus.recoveryInProgress else { return }

        if !force, let lastAttemptAt,
           Date().timeIntervalSince(lastAttemptAt) < configuration.recoveryCooldown {
            return
        }

        let snapshots = await io.displaySnapshots()
        guard configuration.roles.powerControlled.isConfigured,
              configuration.roles.modeSwitch.isConfigured else {
            updateStatus(.failed, message: "未配置两台显示器角色", lastError: RecoveryError.incompleteDisplayConfiguration.localizedDescription)
            log?(RecoveryError.incompleteDisplayConfiguration.localizedDescription)
            return
        }

        guard shouldRecover(snapshots) else {
            if currentStatus.state != .completed {
                updateStatus(.idle, message: messageFor(snapshots), lastError: nil)
            }
            return
        }

        await runRecovery(initialSnapshots: snapshots)
    }

    private func shouldRecover(_ snapshots: [DisplaySnapshot]) -> Bool {
        let powerDisplays = matchingSnapshots(.powerControlled, in: snapshots)
        let modeDisplays = matchingSnapshots(.modeSwitch, in: snapshots)
        // 同一角色出现多个候选时身份不确定，禁止自动断电。
        return powerDisplays.count == 1 && modeDisplays.isEmpty
    }

    private func runRecovery(initialSnapshots: [DisplaySnapshot]) async {
        currentStatus = RecoveryStatus(
            state: .oldOnlyDetected,
            message: "检测到老显示器单独在线，准备恢复双屏",
            recoveryInProgress: true
        )
        lastAttemptAt = Date()
        plugWasTurnedOff = false

        var restoreMode: DisplayModeSignature?
        do {
            restoreMode = try await io.readModeSwitchMode() ?? matching(.modeSwitch, in: initialSnapshots)?.mode
            guard restoreMode != nil else {
                // 无法确认原始模式时不能先断电再把新屏留在未知状态。
                throw RecoveryError.monitorUnavailable
            }

            updateStatus(.powerOffControlledDisplay, message: "正在关闭老显示器电源")
            try await io.setPlugPower(false)
            plugWasTurnedOff = true
            try await waitForPlugPower(false, timeout: configuration.timeouts.powerOff)

            updateStatus(.waitingForNewDisplay, message: "等待新显示器出现")
            let powerFingerprint = configuration.roles.powerControlled
            let modeFingerprint = configuration.roles.modeSwitch
            try await waitFor(configuration.timeouts.newDisplayOnline, operation: "等待新显示器上线") { snapshots in
                let powerDisplays = snapshots.filter { snapshot in
                    snapshot.online && powerFingerprint.matches(snapshot.fingerprint)
                }
                let modeDisplays = snapshots.filter { snapshot in
                    snapshot.online && modeFingerprint.matches(snapshot.fingerprint)
                }
                return powerDisplays.isEmpty && modeDisplays.count == 1
            }

            updateStatus(.setNewDisplaySafeMode, message: "正在将新显示器切换到 \(configuration.safeMode.shortDescription)")
            try await io.setModeSwitchSafeMode()
            try await waitForMode(configuration.safeMode, timeout: configuration.timeouts.safeMode)

            updateStatus(.powerOnControlledDisplay, message: "正在重新打开老显示器电源")
            try await io.setPlugPower(true)
            try await waitForPlugPower(true, timeout: configuration.timeouts.powerOn)
            plugWasTurnedOff = false

            updateStatus(.waitingForOldDisplay, message: "等待老显示器重新枚举")
            try await waitFor(configuration.timeouts.oldDisplayOnline, operation: "等待老显示器上线") { snapshots in
                let powerDisplays = snapshots.filter { snapshot in
                    snapshot.online && powerFingerprint.matches(snapshot.fingerprint)
                }
                let modeDisplays = snapshots.filter { snapshot in
                    snapshot.online && modeFingerprint.matches(snapshot.fingerprint)
                }
                guard powerDisplays.count == 1, modeDisplays.count == 1 else { return false }
                return powerDisplays[0].displayID != modeDisplays[0].displayID
            }

            if let restoreMode {
                updateStatus(.restoreNewDisplayMode, message: "正在恢复新显示器到 \(restoreMode.shortDescription)")
                try await io.restoreModeSwitchMode(restoreMode)
                try await waitForMode(restoreMode, timeout: configuration.timeouts.restoreMode)
            }

            updateStatus(.completed, message: "双显示器已恢复", lastError: nil, recoveryInProgress: false)
            log?("双显示器已恢复")
        } catch {
            if plugWasTurnedOff {
                do {
                    try await io.setPlugPower(true)
                } catch {
                    log?("恢复失败后重新开启插座也失败：\(error.localizedDescription)")
                }
                plugWasTurnedOff = false
            }
            let message = error.localizedDescription
            updateStatus(.failed, message: "自动恢复失败", lastError: message, recoveryInProgress: false)
            log?("自动恢复失败：\(message)")
        }
    }

    private func waitFor(
        _ timeout: TimeInterval,
        operation: String,
        condition: @escaping @Sendable ([DisplaySnapshot]) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition(await io.displaySnapshots()) {
                return
            }
            if Date() >= deadline {
                throw RecoveryError.operationTimedOut(operation)
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        } while !Task.isCancelled

        throw CancellationError()
    }

    private func waitForMode(_ expected: DisplayModeSignature, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let mode = try? await io.readModeSwitchMode(),
               mode.approximatelyEquals(expected) {
                return
            }
            if let display = matching(.modeSwitch, in: await io.displaySnapshots()),
               let mode = display.mode,
               mode.approximatelyEquals(expected) {
                return
            }
            if Date() >= deadline {
                throw RecoveryError.operationTimedOut("等待模式 \(expected.shortDescription) 生效")
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        } while !Task.isCancelled

        throw CancellationError()
    }

    private func waitForPlugPower(_ expected: Bool, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            do {
                if try await io.readPlugPower() == expected {
                    return
                }
            } catch {
                throw RecoveryError.plugUnavailable(error.localizedDescription)
            }
            if Date() >= deadline {
                throw RecoveryError.operationTimedOut(expected ? "等待插座开启" : "等待插座关闭")
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        } while !Task.isCancelled

        throw CancellationError()
    }

    private var pollNanoseconds: UInt64 {
        UInt64(max(0.01, configuration.pollInterval) * 1_000_000_000)
    }

    private func matching(_ role: DisplayRole, in snapshots: [DisplaySnapshot]) -> DisplaySnapshot? {
        let fingerprint: DisplayFingerprint
        switch role {
        case .powerControlled:
            fingerprint = configuration.roles.powerControlled
        case .modeSwitch:
            fingerprint = configuration.roles.modeSwitch
        }
        let matches = snapshots.filter { fingerprint.matches($0.fingerprint) && $0.online }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func matchingSnapshots(_ role: DisplayRole, in snapshots: [DisplaySnapshot]) -> [DisplaySnapshot] {
        let fingerprint: DisplayFingerprint
        switch role {
        case .powerControlled:
            fingerprint = configuration.roles.powerControlled
        case .modeSwitch:
            fingerprint = configuration.roles.modeSwitch
        }
        return snapshots.filter { fingerprint.matches($0.fingerprint) && $0.online }
    }

    private func messageFor(_ snapshots: [DisplaySnapshot]) -> String {
        let online = snapshots.filter(\.online)
        if online.isEmpty {
            return "未检测到在线显示器"
        }
        return "已检测到 \(online.count) 台在线显示器"
    }

    private func updateStatus(
        _ state: RecoveryState,
        message: String,
        lastError: String? = nil,
        recoveryInProgress: Bool? = nil
    ) {
        currentStatus = RecoveryStatus(
            state: state,
            message: message,
            lastError: lastError,
            updatedAt: Date(),
            recoveryInProgress: recoveryInProgress ?? currentStatus.recoveryInProgress
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

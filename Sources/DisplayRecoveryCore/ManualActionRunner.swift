import Foundation

public actor ManualActionRunner {
    private let io: (any RecoveryIO)?
    private let configuration: RecoveryConfiguration
    private let transactionLock: (any RecoveryTransactionLockProtocol)?
    private let clock: any RecoveryClock
    private let log: (@Sendable (ManualActionLogEvent) -> Void)?

    private var runningAction: ManualAction?
    private var activeCancellation: RecoveryCancellation?

    public init(
        io: (any RecoveryIO)? = nil,
        configuration: RecoveryConfiguration = RecoveryConfiguration(),
        transactionLock: (any RecoveryTransactionLockProtocol)? = nil,
        clock: any RecoveryClock = SystemRecoveryClock(),
        log: (@Sendable (ManualActionLogEvent) -> Void)? = nil
    ) {
        self.io = io
        self.configuration = configuration
        self.transactionLock = transactionLock
        self.clock = clock
        self.log = log
    }

    public func currentAction() -> ManualAction? {
        runningAction
    }

    public func cancel() {
        activeCancellation?.cancel("User requested stop")
    }

    public func execute(_ action: ManualAction) async -> ManualActionResult {
        // 1. 在首个挂起点前登记当前动作，防止并发重入
        guard runningAction == nil else {
            return ManualActionResult(
                action: action,
                outcome: .busy,
                shortMessage: "Another action is running."
            )
        }
        runningAction = action

        // 2. 获取设备互斥锁
        if let lock = transactionLock {
            guard lock.tryLock() else {
                runningAction = nil
                return ManualActionResult(
                    action: action,
                    outcome: .busy,
                    shortMessage: "Another action is running.",
                    technicalDetails: "Device channel is busy or locked by another process."
                )
            }
        }

        let cancellation = RecoveryCancellation()
        activeCancellation = cancellation

        defer {
            transactionLock?.unlock()
            runningAction = nil
            activeCancellation = nil
        }

        log?(.started(action: action))

        do {
            let result: ManualActionResult
            switch action {
            case .checkStatus:
                result = try await runCheckStatus(cancellation: cancellation)
            case .powerOff:
                result = try await runPower(on: false, cancellation: cancellation)
            case .powerOn:
                result = try await runPower(on: true, cancellation: cancellation)
            case .lowerResolution:
                result = try await runLowerResolution(cancellation: cancellation)
            case .restoreFullResolution:
                result = try await runRestoreFullResolution(cancellation: cancellation)
            case .verifyBothScreens:
                result = try await runVerifyBothScreens(cancellation: cancellation)
            }
            log?(.finished(action: action, outcome: result.outcome, message: result.shortMessage, technicalDetails: result.technicalDetails))
            return result
        } catch is CancellationError {
            let res = ManualActionResult(action: action, outcome: .cancelled, shortMessage: "Action cancelled.")
            log?(.finished(action: action, outcome: .cancelled, message: res.shortMessage, technicalDetails: nil))
            return res
        } catch {
            let message: String
            let techDetails = error.localizedDescription
            if let recError = error as? RecoveryError {
                message = recError.localizedDescription
            } else {
                message = "Operation failed."
            }
            let res = ManualActionResult(action: action, outcome: .failed, shortMessage: message, technicalDetails: techDetails)
            log?(.finished(action: action, outcome: .failed, message: res.shortMessage, technicalDetails: techDetails))
            return res
        }
    }

    // MARK: - Action Implementations

    private func runCheckStatus(cancellation: RecoveryCancellation) async throws -> ManualActionResult {
        let deadline = RecoveryDeadline(seconds: 10, clock: clock, cancellation: cancellation)
        try deadline.check("Check Status")

        guard let io else {
            return ManualActionResult(action: .checkStatus, outcome: .failed, shortMessage: "Device interface unavailable.")
        }

        var reportLines: [String] = []

        // 1. 检查显示器
        do {
            let obs = try await io.observeDisplays(deadline: deadline)
            let antRes = DisplayRoleResolver.resolve(role: .powerControlled, rolesConfig: configuration.roles, snapshots: obs.snapshots)
            let msiRes = DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: configuration.roles, snapshots: obs.snapshots)

            let antDesc: String
            switch antRes {
            case .matched(let s): antDesc = "Connected (\(s.fingerprint.displayName), \(s.mode?.shortDescription ?? "Unknown mode"))"
            case .notFound: antDesc = "Not detected"
            case .unconfigured: antDesc = "Not configured"
            case .ambiguous: antDesc = "Ambiguous candidates"
            }

            let msiDesc: String
            switch msiRes {
            case .matched(let s): msiDesc = "Connected (\(s.fingerprint.displayName), \(s.mode?.shortDescription ?? "Unknown mode"))"
            case .notFound: msiDesc = "Not detected"
            case .unconfigured: msiDesc = "Not configured"
            case .ambiguous: msiDesc = "Ambiguous candidates"
            }

            reportLines.append("ANT display: \(antDesc)")
            reportLines.append("MSI display: \(msiDesc)")
            log?(.step(message: "Displays: ANT: \(antDesc); MSI: \(msiDesc)"))
        } catch {
            reportLines.append("Displays: Check failed (\(error.localizedDescription))")
            log?(.step(message: "Display check failed: \(error.localizedDescription)"))
        }

        // 2. 检查插座
        do {
            let power = try await io.readPlugPower(deadline: deadline)
            let pStr = power ? "On" : "Off"
            reportLines.append("Smart plug power: \(pStr)")
            log?(.step(message: "Smart plug power: \(pStr)"))
        } catch {
            reportLines.append("Smart plug: Read failed (\(error.localizedDescription))")
            log?(.step(message: "Smart plug read failed: \(error.localizedDescription)"))
        }

        // 3. 检查 MSI 硬件模式
        do {
            let hw = try await io.readHardwareMode(deadline: deadline)
            reportLines.append("MSI hardware mode: \(hw.mode.rawValue)")
            log?(.step(message: "MSI hardware mode: \(hw.mode.rawValue)"))
        } catch {
            reportLines.append("MSI hardware: Read failed (\(error.localizedDescription))")
            log?(.step(message: "MSI hardware read failed: \(error.localizedDescription)"))
        }

        return ManualActionResult(
            action: .checkStatus,
            outcome: .succeeded,
            shortMessage: "Status checked.",
            technicalDetails: reportLines.joined(separator: "\n")
        )
    }

    private func runPower(on targetOn: Bool, cancellation: RecoveryCancellation) async throws -> ManualActionResult {
        let action: ManualAction = targetOn ? .powerOn : .powerOff
        let targetWord = targetOn ? "on" : "off"
        let timeoutSeconds = configuration.timeouts.powerOn > 0 ? (targetOn ? configuration.timeouts.powerOn : configuration.timeouts.powerOff) : 15
        let deadline = RecoveryDeadline(seconds: timeoutSeconds, clock: clock, cancellation: cancellation)
        try deadline.check("Power \(targetWord)")

        guard let io else {
            return ManualActionResult(action: action, outcome: .failed, shortMessage: "Device interface unavailable.")
        }

        // 先读取当前状态；若已经处于目标状态，直接记录并返回成功，无需重复发送
        do {
            let current = try await io.readPlugPower(deadline: deadline)
            if current == targetOn {
                log?(.step(message: "Smart plug is already \(targetWord)."))
                return ManualActionResult(action: action, outcome: .succeeded, shortMessage: "Power is already \(targetWord).")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log?(.step(message: "Initial plug power read warning: \(error.localizedDescription)"))
        }

        // 最多发送一次控制命令
        var commandSent = false
        do {
            log?(.step(message: "Sending power \(targetWord) command..."))
            try await io.setPlugPower(targetOn, deadline: deadline)
            commandSent = true
            log?(.step(message: "Power command sent."))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if cancellation.reason != nil { throw CancellationError() }
            let confirmed = (try? await io.readPlugPower(deadline: deadline)) == targetOn
            if confirmed {
                return ManualActionResult(action: action, outcome: .succeeded, shortMessage: "Power is \(targetWord).")
            }
            return ManualActionResult(action: action, outcome: .failed, shortMessage: "Failed to send power command.", technicalDetails: error.localizedDescription)
        }

        // 循环核验直到读回状态一致
        do {
            while deadline.remaining > 0 {
                try deadline.check("Verifying power \(targetWord)")
                do {
                    let actual = try await io.readPlugPower(deadline: deadline)
                    if actual == targetOn {
                        return ManualActionResult(action: action, outcome: .succeeded, shortMessage: "Power is \(targetWord).")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if cancellation.reason != nil { throw CancellationError() }
                }
                try await deadline.sleep(0.5)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let err as RecoveryError {
            if case .operationTimedOut = err, commandSent {
                return ManualActionResult(action: action, outcome: .unconfirmed, shortMessage: "Power state unconfirmed.", technicalDetails: "Timed out waiting for plug power confirmation.")
            }
            throw err
        }

        // 超时未能确认
        return ManualActionResult(action: action, outcome: .unconfirmed, shortMessage: "Power state unconfirmed.", technicalDetails: "Timed out waiting for plug power confirmation.")
    }

    private func runLowerResolution(cancellation: RecoveryCancellation) async throws -> ManualActionResult {
        let action: ManualAction = .lowerResolution
        let timeoutSeconds = configuration.timeouts.safeMode > 0 ? configuration.timeouts.safeMode : 20
        let deadline = RecoveryDeadline(seconds: timeoutSeconds, clock: clock, cancellation: cancellation)
        try deadline.check("Lower resolution")

        guard let io else {
            return ManualActionResult(action: action, outcome: .failed, shortMessage: "Device interface unavailable.")
        }

        // 检查当前设备状态
        let currentHw = try? await io.readHardwareMode(deadline: deadline)
        let currentObs = try? await io.observeDisplays(deadline: deadline)
        let msiMatch = currentObs.flatMap { DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: configuration.roles, snapshots: $0.snapshots) }

        if case .matched(let s) = msiMatch, s.mode?.is1080P == true, currentHw?.mode == .fhd {
            log?(.step(message: "MSI display is already in low resolution (FHD 1080P)."))
            return ManualActionResult(action: action, outcome: .succeeded, shortMessage: "Resolution is already 1080P.")
        }

        guard let hwIdentity = currentHw?.identity else {
            return ManualActionResult(action: action, outcome: .failed, shortMessage: "MSI display hardware unavailable.")
        }

        // 发送一次切换模式指令
        var commandSent = false
        do {
            log?(.step(message: "Sending lower resolution command (FHD)..."))
            try await io.setHardwareMode(.fhd, expectedIdentity: hwIdentity, deadline: deadline)
            commandSent = true
            log?(.step(message: "Resolution switch command sent."))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if cancellation.reason != nil { throw CancellationError() }
            return ManualActionResult(action: action, outcome: .failed, shortMessage: "Failed to switch resolution.", technicalDetails: error.localizedDescription)
        }

        // 循环核验：硬件模式 FHD 且系统分辨率 1080P
        do {
            while deadline.remaining > 0 {
                try deadline.check("Verifying low resolution")
                do {
                    let hw = try await io.readHardwareMode(deadline: deadline)
                    let obs = try await io.observeDisplays(deadline: deadline)
                    let match = DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: configuration.roles, snapshots: obs.snapshots)
                    if hw.mode == .fhd, case .matched(let snapshot) = match, snapshot.mode?.is1080P == true {
                        return ManualActionResult(action: action, outcome: .succeeded, shortMessage: "Resolution lowered to 1080P.")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if cancellation.reason != nil { throw CancellationError() }
                }
                try await deadline.sleep(0.5)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let err as RecoveryError {
            if case .operationTimedOut = err, commandSent {
                return ManualActionResult(action: action, outcome: .unconfirmed, shortMessage: "Resolution switch unconfirmed.", technicalDetails: "Timed out waiting for FHD mode confirmation.")
            }
            throw err
        }

        return ManualActionResult(action: action, outcome: .unconfirmed, shortMessage: "Resolution switch unconfirmed.", technicalDetails: "Timed out waiting for FHD mode confirmation.")
    }

    private func runRestoreFullResolution(cancellation: RecoveryCancellation) async throws -> ManualActionResult {
        let action: ManualAction = .restoreFullResolution
        let timeoutSeconds = configuration.timeouts.restoreMode > 0 ? configuration.timeouts.restoreMode : 30
        let deadline = RecoveryDeadline(seconds: timeoutSeconds, clock: clock, cancellation: cancellation)
        try deadline.check("Restore full resolution")

        guard let io else {
            return ManualActionResult(action: action, outcome: .failed, shortMessage: "Device interface unavailable.")
        }

        // 检查当前设备状态
        let currentHw = try? await io.readHardwareMode(deadline: deadline)
        let currentObs = try? await io.observeDisplays(deadline: deadline)
        let msiMatch = currentObs.flatMap { DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: configuration.roles, snapshots: $0.snapshots) }

        if case .matched(let s) = msiMatch, s.mode?.is4K == true, currentHw?.mode == .uhd {
            log?(.step(message: "MSI display is already in full resolution (4K UHD)."))
            return ManualActionResult(action: action, outcome: .succeeded, shortMessage: "Resolution is already 4K UHD.")
        }

        guard let hwIdentity = currentHw?.identity else {
            return ManualActionResult(action: action, outcome: .failed, shortMessage: "MSI display hardware unavailable.")
        }

        // 发送一次切换模式指令
        var commandSent = false
        do {
            log?(.step(message: "Sending restore full resolution command (UHD)..."))
            try await io.setHardwareMode(.uhd, expectedIdentity: hwIdentity, deadline: deadline)
            commandSent = true
            log?(.step(message: "Restore resolution command sent."))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if cancellation.reason != nil { throw CancellationError() }
            return ManualActionResult(action: action, outcome: .failed, shortMessage: "Failed to restore resolution.", technicalDetails: error.localizedDescription)
        }

        // 循环核验：硬件模式 UHD 且系统分辨率 4K
        do {
            while deadline.remaining > 0 {
                try deadline.check("Verifying full resolution")
                do {
                    let hw = try await io.readHardwareMode(deadline: deadline)
                    let obs = try await io.observeDisplays(deadline: deadline)
                    let match = DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: configuration.roles, snapshots: obs.snapshots)
                    if hw.mode == .uhd, case .matched(let snapshot) = match, snapshot.mode?.is4K == true {
                        return ManualActionResult(action: action, outcome: .succeeded, shortMessage: "Full resolution restored (4K UHD).")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if cancellation.reason != nil { throw CancellationError() }
                }
                try await deadline.sleep(0.5)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let err as RecoveryError {
            if case .operationTimedOut = err, commandSent {
                return ManualActionResult(action: action, outcome: .unconfirmed, shortMessage: "Resolution restore unconfirmed.", technicalDetails: "Timed out waiting for 4K UHD confirmation.")
            }
            throw err
        }

        return ManualActionResult(action: action, outcome: .unconfirmed, shortMessage: "Resolution restore unconfirmed.", technicalDetails: "Timed out waiting for 4K UHD confirmation.")
    }

    private func runVerifyBothScreens(cancellation: RecoveryCancellation) async throws -> ManualActionResult {
        let action: ManualAction = .verifyBothScreens
        let totalTimeout: TimeInterval = 30
        let requiredStabilitySeconds: TimeInterval = 10
        let deadline = RecoveryDeadline(seconds: totalTimeout, clock: clock, cancellation: cancellation)
        try deadline.check("Verify both screens")

        guard let io else {
            return ManualActionResult(action: action, outcome: .failed, shortMessage: "Device interface unavailable.")
        }

        log?(.step(message: "Starting dual-screen verification (requires 10s continuous stability)..."))

        var stableStartTime: TimeInterval?
        var lastFailureReason: String?

        do {
            while deadline.remaining > 0 {
                try deadline.check("Verifying both screens stability")

                var healthy = true
                var reason: String?

                // 1. 读取插座供电状态
                do {
                    let plugOn = try await io.readPlugPower(deadline: deadline)
                    if !plugOn {
                        healthy = false
                        reason = "Smart plug is powered off."
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    healthy = false
                    reason = "Cannot read smart plug power: \(error.localizedDescription)"
                }

                // 2. 读取显示器快照
                if healthy {
                    do {
                        let obs = try await io.observeDisplays(deadline: deadline)
                        let antRes = DisplayRoleResolver.resolve(role: .powerControlled, rolesConfig: configuration.roles, snapshots: obs.snapshots)
                        let msiRes = DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: configuration.roles, snapshots: obs.snapshots)

                        switch (antRes, msiRes) {
                        case (.matched(let ant), .matched(let msi)):
                            if !ant.online || !ant.isActive || ant.isAsleep {
                                healthy = false
                                reason = "ANT display is not active or asleep."
                            } else if !msi.online || !msi.isActive || msi.isAsleep {
                                healthy = false
                                reason = "MSI display is not active or asleep."
                            } else if !(msi.mode?.is4K == true) {
                                healthy = false
                                reason = "MSI display is not in 4K resolution (current: \(msi.mode?.shortDescription ?? "Unknown"))."
                            }
                        case (.notFound, _):
                            healthy = false
                            reason = "ANT display not detected."
                        case (_, .notFound):
                            healthy = false
                            reason = "MSI display not detected."
                        case (.unconfigured, _), (_, .unconfigured):
                            healthy = false
                            reason = "Displays are not fully configured."
                        case (.ambiguous, _), (_, .ambiguous):
                            healthy = false
                            reason = "Ambiguous display match."
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        healthy = false
                        reason = "Failed to observe displays: \(error.localizedDescription)"
                    }
                }

                // 3. 读取 MSI 硬件模式
                if healthy {
                    do {
                        let hw = try await io.readHardwareMode(deadline: deadline)
                        if hw.mode != .uhd {
                            healthy = false
                            reason = "MSI hardware mode is not UHD (current: \(hw.mode.rawValue))."
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        healthy = false
                        reason = "Failed to read MSI hardware mode: \(error.localizedDescription)"
                    }
                }

                let now = clock.monotonicNow
                if healthy {
                    if let start = stableStartTime {
                        let elapsed = now - start
                        if elapsed >= requiredStabilitySeconds {
                            log?(.step(message: "Dual-screen state has been stable for 10s."))
                            return ManualActionResult(
                                action: action,
                                outcome: .succeeded,
                                shortMessage: "Both screens verified."
                            )
                        }
                    } else {
                        stableStartTime = now
                        log?(.step(message: "All checks passed. Stabilizing for 10s..."))
                    }
                } else {
                    if stableStartTime != nil {
                        log?(.step(message: "Stability interrupted: \(reason ?? "unknown reason")"))
                    }
                    stableStartTime = nil
                    lastFailureReason = reason
                }

                try await deadline.sleep(0.5)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let err as RecoveryError {
            if case .operationTimedOut = err {
                return ManualActionResult(
                    action: action,
                    outcome: .failed,
                    shortMessage: "Verification failed.",
                    technicalDetails: lastFailureReason ?? "Could not maintain 10s stability within 30s limit."
                )
            }
            throw err
        }

        return ManualActionResult(
            action: action,
            outcome: .failed,
            shortMessage: "Verification failed.",
            technicalDetails: lastFailureReason ?? "Could not maintain 10s stability within 30s limit."
        )
    }
}

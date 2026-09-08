import Foundation

public actor RecoveryCoordinator {
    private let io: any RecoveryIO
    private var configuration: RecoveryConfiguration
    private let clock: any RecoveryClock
    private let store: any RecoveryTransactionStoreProtocol
    private let transactionLock: any RecoveryTransactionLockProtocol
    private let log: (@Sendable (String) -> Void)?
    private var transaction = RecoveryTransaction()
    private var currentStatus = RecoveryStatus()
    private var initialization: Task<RecoveryTransaction?, Error>?
    private var initialized = false
    private var initializationGeneration = 0
    private var activeTask: Task<RecoveryOutcome, Never>?
    private var cancellation: RecoveryCancellation?
    private var graceUntil: TimeInterval
    private var cooldownUntil: TimeInterval = 0
    private var loadedAttemptEnd: Date?
    private var singleObservation: (key: String, since: TimeInterval, last: TimeInterval)?
    private var healthyObservation: (key: String, since: TimeInterval, last: TimeInterval)?
    private var lastIdleMode: DisplayModeSignature?
    private var lastRecoveryObservation: String?
    private var suspended = false

    public init(
        io: any RecoveryIO, configuration: RecoveryConfiguration = RecoveryConfiguration(),
        clock: any RecoveryClock = SystemRecoveryClock(),
        transactionStore: (any RecoveryTransactionStoreProtocol)? = nil,
        transactionLock: any RecoveryTransactionLockProtocol = InMemoryRecoveryTransactionLock(),
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.io = io; self.configuration = configuration; self.clock = clock
        self.store = transactionStore ?? InMemoryRecoveryTransactionStore()
        self.transactionLock = transactionLock; self.log = log
        self.graceUntil = clock.monotonicNow + 10
    }

    public func status() async -> RecoveryStatus {
        do { try await initialize() }
        catch { publish("事务读取失败，已阻止硬件操作", error: error.localizedDescription, stage: .failed) }
        return currentStatus
    }
    public func currentConfiguration() -> RecoveryConfiguration { configuration }
    public func isBusy() -> Bool { activeTask != nil }

    /// 配置换代前必须使旧协调器永久停止接收事件，不能只看 UI 的滞后状态。
    public func retireForConfigurationChange() -> Bool {
        guard activeTask == nil, !transaction.hasPendingCleanup else { return false }
        suspended = true
        return true
    }
    public func resumeAfterConfigurationFailure() { suspended = false }

    public func notifySystemWokeUp() {
        suspended = false
        graceUntil = clock.monotonicNow + 10
        resetObservationWindows()
    }
    public func notifyDisplaysChanged() { pollAutomaticRecovery() }
    public func pollAutomaticRecovery() {
        guard !suspended, activeTask == nil else { return }
        Task { [weak self] in _ = await self?.evaluateAndRecover() }
    }
    @discardableResult public func evaluateAndRecover() async -> RecoveryOutcome? {
        guard !suspended else { return nil }
        return await launch(manual: false)
    }
    @discardableResult public func triggerManualRecovery() async -> RecoveryOutcome {
        guard !suspended else { return .skipped("恢复服务已暂停") }
        return await launch(manual: true)
    }
    public func previewRecovery() async -> RecoveryOutcome { await launch(manual: true, preview: true) }

    @discardableResult public func cancelRecovery(reason: String, suspend: Bool = false) async -> RecoveryOutcome? {
        if suspend { suspended = true }
        cancellation?.cancel(reason)
        return await activeTask?.value
    }

    public func setAutomaticRecoveryEnabled(_ enabled: Bool) async {
        configuration.automaticRecoveryEnabled = enabled
        if !enabled { _ = await cancelRecovery(reason: "用户关闭自动恢复") }
        else { graceUntil = clock.monotonicNow + 10 }
        resetObservationWindows()
    }

    /// 明确的人工重新授权只解除停止；未完成责任仍须先收尾。
    @discardableResult public func clearStop() async -> Bool {
        guard activeTask == nil, transactionLock.tryLock() else { return false }
        defer { transactionLock.unlock() }
        var rollback: RecoveryTransaction?
        do {
            try await initialize()
            try await reloadUnderLock()
            rollback = transaction
            transaction.isStopped = false; transaction.stopReason = nil
            transaction.attemptCount = 0; transaction.failureID = UUID().uuidString
            transaction.powerCleanupUsed = false; transaction.modeCleanupUsed = false
            transaction.cleanupErrors = []; transaction.lastError = nil
            transaction.stage = .idle
            try await persist()
            resetObservationWindows()
            publish("已解除停止；未完成责任将优先处理")
            return true
        } catch {
            if let rollback { transaction = rollback }
            publish("解除停止失败", error: error.localizedDescription, stage: .failed)
            return false
        }
    }

    private func initialize() async throws {
        guard !initialized else { return }
        if initialization == nil {
            let store = self.store
            initializationGeneration += 1
            initialization = Task { try await store.load() }
        }
        let generation = initializationGeneration
        let loaded: RecoveryTransaction?
        do { loaded = try await initialization!.value }
        catch {
            if generation == initializationGeneration { initialization = nil }
            throw error
        }
        // 多个等候者只消费同一次初始化；不能覆盖后来已开始的事务。
        guard !initialized else { return }
        transaction = loaded ?? RecoveryTransaction()
        initialized = true
        updateCooldownFromDisk()
        publishPersistedState()
    }

    private func reloadUnderLock() async throws {
        let loaded = try await store.load() ?? transaction
        let changed = loaded != transaction
        transaction = loaded
        updateCooldownFromDisk()
        if changed { publishPersistedState() }
    }
    private func updateCooldownFromDisk() {
        guard loadedAttemptEnd != transaction.lastAttemptAt else { return }
        loadedAttemptEnd = transaction.lastAttemptAt
        let elapsed = transaction.lastAttemptAt.map { clock.now.timeIntervalSince($0) } ?? configuration.recoveryCooldown
        cooldownUntil = clock.monotonicNow + min(configuration.recoveryCooldown, max(0, configuration.recoveryCooldown - elapsed))
    }

    private func launch(manual: Bool, preview: Bool = false) async -> RecoveryOutcome {
        guard activeTask == nil else { return .busy }
        let token = RecoveryCancellation()
        cancellation = token
        let task = Task { await self.runLocked(manual: manual, token: token, preview: preview) }
        activeTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            token.cancel("调用方取消恢复")
        }
        activeTask = nil
        cancellation = nil
        currentStatus.recoveryInProgress = false
        return result
    }

    private func runLocked(manual: Bool, token: RecoveryCancellation, preview: Bool) async -> RecoveryOutcome {
        guard transactionLock.tryLock() else { return .busy }
        defer { transactionLock.unlock() }
        do {
            try await initialize()
            try await reloadUnderLock()
            guard !suspended else { return .skipped("恢复服务已暂停") }
            try validateConfiguration()
            try tokenCheck(token)
            try await io.validateTarget(deadline: deadline(3, token))
            if transaction.hasPendingCleanup {
                if preview {
                    return .skipped(transaction.target == target ? "存在未完成责任：只接续供电和 4K 收尾" : "旧事务目标不能确认，已阻止控制")
                }
                if !manual, transaction.isStopped, clock.monotonicNow < cooldownUntil {
                    return .stopped(transaction.stopReason ?? "未完成收尾处于冷却期")
                }
                return await resumeCleanup(manual: manual)
            }
            guard manual || configuration.automaticRecoveryEnabled else { return .skipped("自动恢复已关闭") }
            let probe = deadline(10, token)
            let topology = try await observe(probe)
            if !manual {
                noteIdleMode(topology.msi?.mode)
                if clock.monotonicNow < graceUntil { return .skipped("启动、唤醒或手动切模观察期") }
                if topology.kind == .both {
                    try await observeHealthy(topology, deadline: probe)
                    return .skipped("双屏在线，保留正常手动模式")
                }
                healthyObservation = nil
                if transaction.isStopped { return .stopped(transaction.stopReason ?? "已停止自动恢复") }
                if clock.monotonicNow < cooldownUntil { return .skipped("处于恢复冷却期") }
            }
            guard topology.kind != .none else {
                resetObservationWindows()
                publish("两台目标显示器均未在线，保持观察")
                return .skipped("两台目标显示器均未在线")
            }
            if topology.kind != .both {
                guard try await readPower(probe) else {
                    resetObservationWindows()
                    publish("ANT 插座关闭，保留手动使用状态")
                    return .skipped("ANT 插座未供电")
                }
                if !manual && !singleDisplayIsStable(topology) { return .skipped("等待同一单屏状态稳定 5 秒") }
            }
            var initialHardware: HardwareModeObservation?
            if topology.msi != nil { initialHardware = try await waitHardwareReady(deadline: probe) }
            try probe.check()
            // I/O 等待后重新判断，预检查期间的拓扑变化不能沿用旧决策。
            let latest = try await observe(probe)
            guard latest.key == topology.key else {
                resetObservationWindows()
                return .skipped("预检查期间显示器拓扑已变化")
            }
            if !manual && transaction.attemptCount >= 3 {
                transaction.isStopped = true; transaction.stopReason = "同一故障已达到三次恢复上限"
                try await persist(); publishPersistedState()
                return .stopped(transaction.stopReason!)
            }
            if preview { return .skipped("预检查通过；将从 \(latest.key) 恢复并验证 MSI 4K，当前未执行任何写操作") }
            return await execute(topology: latest, initialHardware: initialHardware, manual: manual, token: token)
        } catch {
            resetObservationWindows()
            if token.reason != nil { return .cancelled(token.reason!) }
            publish("预检查未通过，未执行恢复动作", error: error.localizedDescription, stage: .failed)
            return .skipped(error.localizedDescription)
        }
    }

    private func execute(topology: Topology, initialHardware: HardwareModeObservation?, manual: Bool, token: RecoveryCancellation) async -> RecoveryOutcome {
        let previous = transaction
        if manual { transaction.failureID = UUID().uuidString; transaction.attemptCount = 0 }
        transaction.id = UUID(); transaction.schemaVersion = 2
        transaction.attemptCount += 1
        transaction.isStopped = false; transaction.stopReason = nil
        transaction.target = target
        transaction.msiHIDIdentity = initialHardware?.identity
        transaction.modePending4K = true
        transaction.powerPendingRestore = false
        transaction.powerCleanupUsed = false; transaction.modeCleanupUsed = false
        transaction.cleanupErrors = []; transaction.lastError = nil
        transaction.stage = .evaluating
        do { try await persist() }
        catch {
            transaction = previous
            publish("无法登记恢复责任，未操作硬件", error: error.localizedDescription, stage: .failed)
            return .failure(error.localizedDescription)
        }
        currentStatus.recoveryInProgress = true
        resetObservationWindows()
        do {
            switch topology.kind {
            case .antOnly: try await recoverFromANT(token)
            case .msiOnly: try await recoverFromMSI(token)
            case .both: break
            case .none: throw RecoveryError.operationFailed("恢复起始状态无目标显示器")
            }
            try await finalize4K(token)
            try await complete()
            return .success
        } catch {
            let reason = token.reason ?? error.localizedDescription
            transaction.lastError = reason
            await cleanup()
            await finishFailure(reason, cancelled: token.reason != nil)
            return token.reason.map(RecoveryOutcome.cancelled) ?? .failure(failureDescription(reason))
        }
    }

    private func recoverFromANT(_ token: RecoveryCancellation) async throws {
        let off = deadline(configuration.timeouts.powerOff, token)
        guard try await observe(off).kind == .antOnly, try await readPower(off) else {
            throw RecoveryError.operationFailed("ANT 断电前状态已变化")
        }
        transaction.powerPendingRestore = true
        try await transition(.antPowerOff, "关闭 ANT 插座，等待确认离线")
        try off.check()
        try await io.setPlugPower(false, deadline: off)
        try await wait(off) { try await self.readPower(off) == false }
        try await transition(.waitingAntDisconnect, "等待 ANT 确认离线")
        try await wait(off) { try await self.observe(off).ant == nil }

        let online = deadline(configuration.timeouts.newDisplayOnline, token)
        try await transition(.waitingMsiEnumerate, "等待 MSI 重新枚举")
        try await wait(online) { try await self.observe(online).kind == .msiOnly }

        let on = deadline(configuration.timeouts.powerOn, token)
        try await transition(.antPowerOn, "恢复 ANT 插座供电")
        try await io.setPlugPower(true, deadline: on)
        try await wait(on) { try await self.readPower(on) }
        transaction.powerPendingRestore = false
        try await persist()

        try await transition(.antWaitingReenumerate, "等待 ANT 自然上线，最多 10 秒")
        let natural = deadline(10, token)
        while natural.remaining > 0 {
            try natural.check()
            let current = try await observe(natural)
            if current.kind == .both { return }
            if current.kind != .msiOnly { throw RecoveryError.operationFailed("等待 ANT 时拓扑已变化") }
            if natural.remaining <= configuration.pollInterval { break }
            try await natural.sleep(configuration.pollInterval)
        }
        try tokenCheck(token)
        guard try await observe(deadline(3, token)).kind == .msiOnly else {
            throw RecoveryError.operationFailed("进入临时 1080P 前已不再是 MSI 单屏")
        }
        try await recoverFromMSI(token)
    }

    private func recoverFromMSI(_ token: RecoveryCancellation) async throws {
        let ready = deadline(10, token)
        guard try await observe(ready).kind == .msiOnly, try await readPower(ready) else {
            throw RecoveryError.operationFailed("临时切模前的 MSI 单屏或供电条件不满足")
        }
        let hardware = try await waitHardwareReady(deadline: ready)
        try await bindHardware(hardware)
        let mode = deadline(configuration.timeouts.safeMode, token)
        try await transition(.msiSwitch1080P, "将 MSI 临时切换到 1080P")
        guard try await observe(mode).kind == .msiOnly, try await readPower(mode) else {
            throw RecoveryError.operationFailed("临时切模前状态发生变化")
        }
        let latest = try await readHardware(mode)
        if latest.mode != .fhd { try await writeMode(.fhd, deadline: mode) }
        try await wait(mode) { try await self.readHardware(mode).mode == .fhd }
        let dual = deadline(configuration.timeouts.oldDisplayOnline, token)
        try await transition(.waitingDualOnline, "等待两台目标显示器上线")
        do {
            try await wait(dual) { try await self.observe(dual).kind == .both }
        } catch RecoveryError.operationTimedOut {
            try tokenCheck(token)
            // 部分重新枚举要到回切 UHD 后才完成。中间等待期限耗尽也必须
            // 进入统一 4K 收尾，最终仍以新鲜双屏观测连续稳定 10 秒为准。
            publish("1080P 阶段等待双屏超时；继续恢复 4K 并核验最终状态")
        }
    }

    private func finalize4K(_ token: RecoveryCancellation) async throws {
        try await transition(.finalizing4K, "恢复 MSI UHD，并核对系统实际模式")
        let mode = deadline(configuration.timeouts.restoreMode, token)
        let hardware = try await waitHardwareReady(deadline: mode)
        try await bindHardware(hardware)
        if hardware.mode != .uhd { try await writeMode(.uhd, deadline: mode) }
        try await wait(mode) { try await self.readHardware(mode).mode == .uhd }
        try await verifyStable4K(token)
    }

    private func verifyStable4K(_ token: RecoveryCancellation) async throws {
        try await transition(.stabilizing4K, "验证双屏与 MSI 4K 连续稳定 10 秒")
        let verification = deadline(max(30, configuration.timeouts.dualDisplayStabilize + 5), token)
        var since: TimeInterval?
        var lastGood: TimeInterval?
        while true {
            try verification.check()
            var good = false
            do {
                let topology = try await observe(verification)
                let hardware = try await readHardware(verification)
                good = topology.kind == .both && topology.msi?.mode?.is4K == true && hardware.mode == .uhd
            } catch {
                if token.reason != nil { throw CancellationError() }
                if isIdentityError(error) { throw error }
            }
            let now = clock.monotonicNow
            if good {
                if since == nil || now - (lastGood ?? now) > maximumObservationGap { since = now }
                lastGood = now
                if now - since! >= configuration.timeouts.dualDisplayStabilize { return }
            } else { since = nil; lastGood = nil }
            try await verification.sleep(configuration.pollInterval)
        }
    }

    private func resumeCleanup(manual: Bool) async -> RecoveryOutcome {
        guard transaction.target == target else {
            let reason = "未完成事务缺少可验证的原目标，或当前角色、插座、凭据已经改变；已阻止自动控制"
            publish(reason, error: reason, stage: .stopped)
            return .stopped(reason)
        }
        currentStatus.recoveryInProgress = true
        if transaction.powerPendingRestore && !transaction.modePending4K {
            transaction.modePending4K = true
            do { try await persist() }
            catch { return .failure("无法补记恢复的 4K 责任：\(error.localizedDescription)") }
        }
        if manual {
            transaction.attemptCount = 1; transaction.failureID = UUID().uuidString
            transaction.isStopped = false; transaction.stopReason = nil
            transaction.powerCleanupUsed = false; transaction.modeCleanupUsed = false
            do { try await persist() }
            catch { return .failure("无法登记人工收尾授权：\(error.localizedDescription)") }
        }
        await cleanup()
        if !transaction.hasPendingCleanup {
            do {
                // 收尾动作完成仍不代表双屏恢复成功。
                let token = cancellation ?? RecoveryCancellation()
                try await verifyStable4K(token)
                try await complete()
                return .success
            } catch {
                await finishFailure(error.localizedDescription, cancelled: cancellation?.reason != nil)
                return .failure(failureDescription(error.localizedDescription))
            }
        }
        let reason = "上次恢复仍有未完成责任；收尾额度已使用，等待明确的手动恢复"
        transaction.isStopped = true; transaction.stopReason = reason
        await finishFailure(reason, cancelled: false)
        return .stopped(failureDescription(reason))
    }

    /// 独立取消上下文：调用方取消不能打断本次已授权的有限收尾。
    private func cleanup() async {
        transaction.cleanupErrors = []
        transaction.stage = .cleanupAndRollback
        publish("异常收尾：分别恢复供电和 MSI 4K")
        if transaction.powerPendingRestore {
            let limit = deadline(5, RecoveryCancellation())
            do {
                guard transaction.target == target else { throw RecoveryError.operationFailed("供电收尾目标不一致") }
                if try await !readPower(limit) {
                    guard !transaction.powerCleanupUsed else { throw RecoveryError.operationFailed("供电收尾额度已使用") }
                    transaction.powerCleanupUsed = true
                    try await persist()
                    try limit.check()
                    try await io.setPlugPower(true, deadline: limit)
                }
                try await wait(limit) { try await self.readPower(limit) }
                transaction.powerPendingRestore = false
                try await persist()
            } catch { transaction.powerPendingRestore = true; transaction.cleanupErrors.append("供电：\(error.localizedDescription)") }
        }
        if transaction.modePending4K {
            let limit = deadline(5, RecoveryCancellation())
            do {
                guard transaction.target == target else { throw RecoveryError.operationFailed("4K 收尾目标不一致") }
                let topology = try await observe(limit)
                let hardware = try await readHardware(limit)
                if transaction.msiHIDIdentity == nil {
                    guard topology.msi != nil else { throw RecoveryError.monitorUnavailable }
                    try await bindHardware(hardware)
                }
                if hardware.mode != .uhd {
                    guard !transaction.modeCleanupUsed else { throw RecoveryError.operationFailed("4K 收尾额度已使用") }
                    transaction.modeCleanupUsed = true
                    try await persist()
                    try await writeMode(.uhd, deadline: limit)
                }
                try await wait(limit) {
                    let h = try await self.readHardware(limit)
                    let t = try await self.observe(limit)
                    return h.mode == .uhd && t.msi?.mode?.is4K == true
                }
                transaction.modePending4K = false
                try await persist()
            } catch { transaction.modePending4K = true; transaction.cleanupErrors.append("4K：\(error.localizedDescription)") }
        }
    }

    private func complete() async throws {
        guard !transaction.powerPendingRestore else { throw RecoveryError.operationFailed("供电责任尚未完成") }
        var completed = transaction
        completed.modePending4K = false
        completed.isStopped = false; completed.stopReason = nil; completed.attemptCount = 0
        completed.lastError = nil; completed.cleanupErrors = []; completed.stage = .completed
        completed.lastAttemptAt = clock.now; completed.updatedAt = clock.now
        // 只有成功提交完成记录才能清零；提交失败时仍保留本轮责任与次数。
        try await store.save(completed)
        transaction = completed
        markCooldown()
        publish("双屏恢复完成：MSI 4K 已通过连续稳定验证")
    }
    private func finishFailure(_ reason: String, cancelled: Bool) async {
        transaction.lastError = reason
        if transaction.attemptCount >= 3 || transaction.hasPendingCleanup {
            transaction.isStopped = true
            transaction.stopReason = transaction.hasPendingCleanup ? "异常收尾未完成，需要手动恢复" : "同一故障已达到三次恢复上限"
        }
        transaction.stage = transaction.isStopped ? .stopped : (cancelled ? .cancelled : .failed)
        transaction.lastAttemptAt = clock.now
        do { try await persist() }
        catch { transaction.cleanupErrors.append("事务落盘：\(error.localizedDescription)") }
        markCooldown()
        publish(cancelled ? "恢复已取消，有限收尾已结束" : "恢复失败", error: failureDescription(reason))
    }
    private func markCooldown() {
        loadedAttemptEnd = transaction.lastAttemptAt
        cooldownUntil = clock.monotonicNow + configuration.recoveryCooldown
    }
    private func failureDescription(_ reason: String) -> String {
        ([reason] + transaction.cleanupErrors).joined(separator: "；")
    }

    private var target: RecoveryTarget { RecoveryTarget(roles: configuration.roles, controlIdentity: io.targetIdentity) }
    private var maximumObservationGap: TimeInterval { max(3, configuration.pollInterval * 3) }
    private func deadline(_ seconds: TimeInterval, _ token: RecoveryCancellation) -> RecoveryDeadline {
        RecoveryDeadline(seconds: seconds, clock: clock, cancellation: token)
    }
    private func tokenCheck(_ token: RecoveryCancellation) throws {
        if token.reason != nil { throw CancellationError() }
    }
    private func validateConfiguration() throws {
        guard configuration.roles.powerControlled.isConfigured, configuration.roles.modeSwitch.isConfigured else {
            throw RecoveryError.incompleteDisplayConfiguration
        }
        let t = configuration.timeouts
        let intervals = [configuration.pollInterval, t.powerOff, t.powerOn, t.newDisplayOnline, t.safeMode, t.oldDisplayOnline, t.restoreMode, t.dualDisplayStabilize, t.singleDisplayObserve]
        guard intervals.allSatisfy({ $0.isFinite && $0 > 0 }), configuration.recoveryCooldown.isFinite, configuration.recoveryCooldown >= 0 else {
            throw RecoveryError.operationFailed("恢复时间配置必须为有效正数")
        }
    }

    private struct Topology {
        enum Kind { case antOnly, msiOnly, both, none }
        let ant: DisplaySnapshot?
        let msi: DisplaySnapshot?
        var kind: Kind {
            if ant != nil { return msi == nil ? .antOnly : .both }
            return msi == nil ? .none : .msiOnly
        }
        var key: String { "ANT:\(ant?.displayID.description ?? "absent")/MSI:\(msi?.displayID.description ?? "absent")" }
    }
    private func observe(_ limit: RecoveryDeadline) async throws -> Topology {
        try limit.check()
        let observation = try await io.observeDisplays(deadline: limit)
        try limit.check()
        try checkFresh(observation.observedAt)
        func resolve(_ role: DisplayRole) throws -> DisplaySnapshot? {
            switch DisplayRoleResolver.resolve(role: role, rolesConfig: configuration.roles, snapshots: observation.snapshots) {
            case .matched(let snapshot):
                guard snapshot.isActive, !snapshot.isAsleep else { throw RecoveryError.operationFailed("目标显示器休眠或尚未激活") }
                return snapshot
            case .notFound: return nil
            case .unconfigured: throw RecoveryError.incompleteDisplayConfiguration
            case .ambiguous: throw RecoveryError.ambiguousDisplay(role.rawValue)
            }
        }
        let ant = try resolve(.powerControlled), msi = try resolve(.modeSwitch)
        if let ant, let msi, ant.displayID == msi.displayID { throw RecoveryError.ambiguousDisplay("ANT 与 MSI 指向同一显示器") }
        let topology = Topology(ant: ant, msi: msi)
        if currentStatus.recoveryInProgress {
            let observation = "\(topology.key) MSI=\(msi?.mode?.shortDescription ?? "未知")"
            if lastRecoveryObservation != observation {
                lastRecoveryObservation = observation
                log?("事务=\(transaction.id) 显示观测：\(observation)")
            }
        }
        return topology
    }
    private func readPower(_ limit: RecoveryDeadline) async throws -> Bool {
        try limit.check()
        let power = try await io.readPlugPower(deadline: limit)
        try limit.check()
        return power
    }
    private func readHardware(_ limit: RecoveryDeadline) async throws -> HardwareModeObservation {
        try limit.check()
        let hardware = try await io.readHardwareMode(deadline: limit)
        try limit.check(); try checkFresh(hardware.observedAt)
        guard !hardware.identity.isEmpty else { throw RecoveryError.monitorUnavailable }
        if transaction.hasPendingCleanup || currentStatus.recoveryInProgress, let expected = transaction.msiHIDIdentity, expected != hardware.identity {
            throw RecoveryError.ambiguousDisplay("MSI HID 身份发生变化")
        }
        return hardware
    }
    private func checkFresh(_ observedAt: TimeInterval) throws {
        let age = clock.monotonicNow - observedAt
        guard age >= -0.001, age <= 3 else { throw RecoveryError.operationFailed("观测结果已过期") }
    }
    private func bindHardware(_ hardware: HardwareModeObservation) async throws {
        guard hardware.mode != .unknown else { throw RecoveryError.monitorUnavailable }
        if let expected = transaction.msiHIDIdentity, expected != hardware.identity { throw RecoveryError.ambiguousDisplay("MSI HID 身份不一致") }
        if transaction.msiHIDIdentity == nil {
            transaction.msiHIDIdentity = hardware.identity
            try await persist()
        }
    }
    private func writeMode(_ mode: MsiHardwareDualMode, deadline: RecoveryDeadline) async throws {
        guard transaction.target == target, let identity = transaction.msiHIDIdentity else { throw RecoveryError.monitorUnavailable }
        _ = try await observe(deadline) // 歧义时不能继续下发指令。
        try deadline.check()
        try await io.setHardwareMode(mode, expectedIdentity: identity, deadline: deadline)
        try deadline.check()
    }
    private func waitHardwareReady(deadline: RecoveryDeadline) async throws -> HardwareModeObservation {
        while true {
            try deadline.check("等待 MSI HID 就绪")
            do {
                let hardware = try await readHardware(deadline)
                if hardware.mode != .unknown { return hardware }
            } catch { if isIdentityError(error) { throw error } }
            try await deadline.sleep(configuration.pollInterval)
        }
    }
    private func wait(_ limit: RecoveryDeadline, condition: () async throws -> Bool) async throws {
        while true {
            try limit.check()
            do {
                if try await condition() { try limit.check(); return }
            } catch {
                if limit.cancellation.reason != nil || isIdentityError(error) { throw error }
            }
            try await limit.sleep(configuration.pollInterval)
        }
    }
    private func isIdentityError(_ error: Error) -> Bool {
        if case RecoveryError.ambiguousDisplay = error { return true }
        if case RecoveryError.incompleteDisplayConfiguration = error { return true }
        return false
    }

    private func noteIdleMode(_ mode: DisplayModeSignature?) {
        guard let mode else { return }
        if let previous = lastIdleMode, previous != mode {
            graceUntil = clock.monotonicNow + 10
            resetObservationWindows()
        }
        lastIdleMode = mode
    }
    private func singleDisplayIsStable(_ topology: Topology) -> Bool {
        let now = clock.monotonicNow
        if let previous = singleObservation, previous.key == topology.key, now - previous.last <= maximumObservationGap {
            singleObservation = (previous.key, previous.since, now)
            return now - previous.since >= configuration.timeouts.singleDisplayObserve
        }
        singleObservation = (topology.key, now, now)
        publish("等待同一单屏状态稳定 5 秒")
        return false
    }
    private func observeHealthy(_ topology: Topology, deadline: RecoveryDeadline) async throws {
        singleObservation = nil
        guard topology.msi?.mode?.is4K == true, try await readHardware(deadline).mode == .uhd else {
            healthyObservation = nil
            publishPersistedState(defaultMessage: "双屏在线，保留手动模式")
            return
        }
        let now = clock.monotonicNow
        if let previous = healthyObservation, previous.key == topology.key, now - previous.last <= maximumObservationGap {
            healthyObservation = (previous.key, previous.since, now)
            if now - previous.since >= configuration.timeouts.dualDisplayStabilize,
               transaction.attemptCount > 0 || transaction.isStopped {
                var completed = transaction
                completed.attemptCount = 0; completed.isStopped = false; completed.stopReason = nil
                completed.lastError = nil; completed.cleanupErrors = []
                completed.failureID = UUID().uuidString; completed.stage = .completed; completed.updatedAt = clock.now
                try await store.save(completed)
                transaction = completed
                publish("双屏已自行恢复并通过 4K 稳定验证，已解除停止")
            }
        } else { healthyObservation = (topology.key, now, now) }
        if !transaction.isStopped, transaction.attemptCount == 0 { publish("双屏在线，MSI 为 4K") }
    }
    private func resetObservationWindows() {
        singleObservation = nil; healthyObservation = nil; lastRecoveryObservation = nil
    }
    private func transition(_ stage: RecoveryStage, _ message: String) async throws {
        transaction.stage = stage
        try await persist()
        publish(message)
    }
    private func persist() async throws {
        transaction.updatedAt = clock.now
        try await store.save(transaction)
    }
    private func publishPersistedState(defaultMessage: String = "等待显示器状态") {
        let message = transaction.isStopped ? "自动恢复已停止" : (transaction.hasPendingCleanup ? "存在未完成恢复责任" : defaultMessage)
        publish(message, error: transaction.lastError)
    }
    private func publish(_ message: String, error: String? = nil, stage: RecoveryStage? = nil) {
        let stage = stage ?? transaction.stage
        let state: RecoveryState = stage == .completed ? .completed : ([RecoveryStage.failed, .stopped, .cancelled].contains(stage) ? .failed : .idle)
        let status = RecoveryStatus(state: state, stage: stage, message: message, lastError: error, updatedAt: clock.now,
            recoveryInProgress: currentStatus.recoveryInProgress, attemptCount: transaction.attemptCount,
            isStopped: transaction.isStopped, stopReason: transaction.stopReason, modePending4K: transaction.modePending4K,
            powerPendingRestore: transaction.powerPendingRestore, cleanupErrors: transaction.cleanupErrors)
        if currentStatus.stage != status.stage || currentStatus.message != message || currentStatus.lastError != error {
            log?("事务=\(transaction.id) 阶段=\(stage.rawValue) 尝试=\(transaction.attemptCount) 供电待恢复=\(transaction.powerPendingRestore) 4K待恢复=\(transaction.modePending4K) \(message)\(error.map { " 错误=\($0)" } ?? "")")
        }
        currentStatus = status
    }
}

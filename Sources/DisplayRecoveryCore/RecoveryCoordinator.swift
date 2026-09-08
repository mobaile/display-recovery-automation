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
    // 在调用 I/O 前登记，命令已执行但应答丢失时也必须保持间隔。
    private var nextControlAt: TimeInterval = 0
    private var needsResumeObservation = false

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
        needsResumeObservation = transaction.hasPendingCleanup
        initialized = true
        updateCooldownFromDisk()
        publishPersistedState()
    }

    private func reloadUnderLock() async throws {
        let loaded = try await store.load() ?? transaction
        let changed = loaded != transaction
        transaction = loaded
        if changed && loaded.hasPendingCleanup { needsResumeObservation = true }
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
                    return .skipped(transaction.target == target ? "存在未完成责任：先接续收尾；若仍为 ANT 单屏，手动入口可重新执行一次完整恢复" : "旧事务目标不能确认，已阻止控制")
                }
                if !manual, transaction.isStopped, clock.monotonicNow < cooldownUntil {
                    return .stopped(transaction.stopReason ?? "未完成收尾处于冷却期")
                }
                return await resumeCleanup(manual: manual)
            }
            guard manual || configuration.automaticRecoveryEnabled else { return .skipped("自动恢复已关闭") }
            let probe = deadline(15, token)
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
                if !manual && !singleDisplayIsStable(topology) { return .skipped(singleObservationMessage) }
            }
            var initialHardware: HardwareModeObservation?
            if topology.msi != nil { initialHardware = try await waitHardwareReady(deadline: deadline(configuration.timeouts.hardwareReady, token)) }
            try tokenCheck(token)
            // I/O 等待后重新判断，预检查期间的拓扑变化不能沿用旧决策。
            let latest = try await observe(deadline(3, token))
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
        return await performRecovery(topology: topology, token: token)
    }

    private func performRecovery(topology: Topology, token: RecoveryCancellation) async -> RecoveryOutcome {
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
        try await transition(.antPowerOff, "关闭 ANT 插座，确认断电后保持至少 10 秒")
        try await writePower(false, deadline: off)
        try await wait(off, operation: "确认 ANT 插座关闭") { try await self.readPower(off) == false }
        holdControls(for: configuration.timeouts.powerOffMinimum)
        let online = deadline(configuration.timeouts.newDisplayOnline, token)
        try await transition(.waitingMsiEnumerate, "保持 ANT 断电，同时观察 ANT 和 MSI")
        do {
            try await wait(online, operation: "ANT 断电后等待 MSI 上线", minimumUntil: nextControlAt) {
                let topology = try await self.observe(online, allowInactive: true)
                return topology.msi.map { $0.isActive && !$0.isAsleep } == true
            }
        } catch RecoveryError.operationTimedOut {
            try tokenCheck(token)
            publish("ANT 断电观察期限已到，恢复供电后继续观察；未将枚举残留或未知状态当作离线")
        }

        let on = deadline(configuration.timeouts.powerOn, token)
        try await transition(.antPowerOn, "恢复 ANT 插座供电")
        try await writePower(true, deadline: on)
        try await wait(on, operation: "确认 ANT 插座开启") { try await self.readPower(on) }
        holdControls(for: configuration.timeouts.powerOnSettle)
        transaction.powerPendingRestore = false
        try await persist()

        try await transition(.antWaitingReenumerate, "ANT 已复电，保持 15 秒后重新判断拓扑")
        try await settleControls(token, operation: "ANT 复电稳定观察")
        let current = try await observe(deadline(3, token))
        if current.kind == .both { return }
        guard current.kind == .msiOnly else {
            throw RecoveryError.operationFailed("ANT 复电并等待稳定后仍未恢复 MSI：\(current.key)")
        }
        try await recoverFromMSI(token)
    }

    private func recoverFromMSI(_ token: RecoveryCancellation) async throws {
        let ready = deadline(15, token)
        guard try await observe(ready).kind == .msiOnly, try await readPower(ready) else {
            throw RecoveryError.operationFailed("临时切模前的 MSI 单屏或供电条件不满足")
        }
        let hardware = try await waitHardwareReady(deadline: deadline(configuration.timeouts.hardwareReady, token))
        try await bindHardware(hardware)
        let mode = deadline(configuration.timeouts.safeMode, token)
        try await transition(.msiSwitch1080P, "将 MSI 临时切换到 1080P")
        guard try await observe(mode).kind == .msiOnly, try await readPower(mode) else {
            throw RecoveryError.operationFailed("临时切模前状态发生变化")
        }
        let latest = try await readHardware(mode)
        let wroteFHD = latest.mode != .fhd
        if wroteFHD { try await writeMode(.fhd, deadline: mode) }
        // 双屏等待窗口从 FHD 写入（或确认已是 FHD）开始计算，包含模式确认和稳定保持时间。
        let dual = deadline(configuration.timeouts.oldDisplayOnline, token)
        let confirmation = deadline(configuration.timeouts.hardwareReady, token)
        try await wait(confirmation, operation: "确认 MSI 1080P") { try await self.readHardware(confirmation).mode == .fhd }
        // 即使读到的本来就是 FHD，也要从确认时刻起保持完整的模式稳定窗口。
        holdControls(for: configuration.timeouts.modeSettle)
        try await transition(.waitingDualOnline, "等待两台目标显示器上线")
        do {
            try await wait(dual, operation: "保持 1080P 并等待双屏", minimumUntil: nextControlAt) { try await self.observe(dual).kind == .both }
        } catch RecoveryError.operationTimedOut {
            try tokenCheck(token)
            // 部分重新枚举要到回切 UHD 后才完成。中间等待期限耗尽也必须
            // 进入统一 4K 收尾，最终仍以新鲜双屏观测连续稳定 10 秒为准。
            publish("1080P 阶段等待双屏超时；继续恢复 4K 并核验最终状态")
        }
    }

    private func finalize4K(_ token: RecoveryCancellation) async throws {
        try await transition(.finalizing4K, "恢复 MSI UHD，并核对系统实际模式")
        let hardware = try await waitHardwareReady(deadline: deadline(configuration.timeouts.hardwareReady, token))
        try await bindHardware(hardware)
        let wrote = hardware.mode != .uhd
        if wrote { try await writeMode(.uhd, deadline: deadline(configuration.timeouts.restoreMode, token)) }
        let confirmation = deadline(configuration.timeouts.hardwareReady, token)
        try await wait(confirmation, operation: "确认 MSI UHD") { try await self.readHardware(confirmation).mode == .uhd }
        // 已经是 UHD 时也要从新鲜确认起观察至少 15 秒，再计入最终稳定窗口。
        holdControls(for: configuration.timeouts.modeSettle)
        try await verifyStable4K(token)
    }

    private func verifyStable4K(_ token: RecoveryCancellation) async throws {
        try await transition(.stabilizing4K, "验证双屏与 MSI 4K 连续稳定 10 秒")
        let verification = deadline(max(30, max(0, nextControlAt - clock.monotonicNow) + configuration.timeouts.dualDisplayStabilize + 5), token)
        let started = clock.monotonicNow
        var lastProgress: TimeInterval = -Double.infinity
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
                if now >= nextControlAt, now - since! >= configuration.timeouts.dualDisplayStabilize { return }
            } else { since = nil; lastGood = nil }
            reportWaiting("验证 MSI 4K 与双屏稳定", started: started, lastProgress: &lastProgress, detail: "连续达标 \(Int(now - (since ?? now))) 秒；\(lastRecoveryObservation ?? "暂无有效观测")")
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
        if needsResumeObservation {
            // 单调时间不能跨进程持久化。接续时完整观察一轮，避免紧接着旧进程的写入。
            holdControls(for: max(configuration.timeouts.powerOnSettle, configuration.timeouts.modeSettle))
            do { try await settleControls(RecoveryCancellation(), operation: "接续旧事务前重新观察") }
            catch { return .stopped("接续观察失败，未执行控制：\(error.localizedDescription)") }
            needsResumeObservation = false
        }
        await cleanup()
        if manual, !transaction.powerPendingRestore, transaction.modePending4K {
            let token = cancellation ?? RecoveryCancellation()
            do {
                try tokenCheck(token)
                let probe = deadline(15, token)
                let topology = try await observe(probe)
                if topology.kind == .antOnly, try await readPower(probe) {
                    // 同一次人工授权至多重走一次；保留原目标、HID 绑定和 4K 责任。
                    transaction.powerCleanupUsed = false; transaction.modeCleanupUsed = false
                    transaction.cleanupErrors = []; transaction.lastError = nil
                    try await transition(.evaluating, "人工接续：供电已恢复，仍为 ANT 单屏，重新执行一次完整恢复")
                    resetObservationWindows()
                    return await performRecovery(topology: topology, token: token)
                }
            } catch {
                await finishFailure(error.localizedDescription, cancelled: token.reason != nil)
                return token.reason.map(RecoveryOutcome.cancelled) ?? .failure(failureDescription(error.localizedDescription))
            }
        }
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
        let used = (transaction.powerPendingRestore && transaction.powerCleanupUsed)
            || (transaction.modePending4K && transaction.modeCleanupUsed)
        let reason = used ? "上次恢复仍有未完成责任；对应收尾写入额度已使用，需要手动恢复"
            : "上次恢复仍有未完成责任；设备尚未就绪，收尾写入额度未使用"
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
            let limit = deadline(30, RecoveryCancellation())
            do {
                guard transaction.target == target else { throw RecoveryError.operationFailed("供电收尾目标不一致") }
                var actual: Bool?
                let ready = boundedDeadline(configuration.timeouts.hardwareReady, within: limit)
                try await wait(ready, operation: "收尾读取 ANT 插座状态") { actual = try await self.readPower(ready); return true }
                if actual == false {
                    guard !transaction.powerCleanupUsed else { throw RecoveryError.operationFailed("供电收尾额度已使用") }
                    try await waitControlGap(limit)
                    transaction.powerCleanupUsed = true
                    try await persist()
                    try await writePower(true, deadline: limit)
                    try await wait(limit, operation: "收尾确认 ANT 复电") { try await self.readPower(limit) }
                    holdControls(for: configuration.timeouts.powerOnSettle)
                }
                try await wait(limit, operation: "供电收尾稳定观察", minimumUntil: nextControlAt) { try await self.readPower(limit) }
                transaction.powerPendingRestore = false
                try await persist()
            } catch { transaction.powerPendingRestore = true; transaction.cleanupErrors.append("供电：\(error.localizedDescription)") }
        }
        if transaction.modePending4K {
            let limit = deadline(45, RecoveryCancellation())
            do {
                guard transaction.target == target else { throw RecoveryError.operationFailed("4K 收尾目标不一致") }
                let hardware = try await waitHardwareReady(deadline: boundedDeadline(configuration.timeouts.hardwareReady, within: limit))
                if transaction.msiHIDIdentity == nil {
                    try await wait(limit, operation: "收尾等待 MSI 显示目标就绪") { try await self.observe(limit).msi != nil }
                    try await bindHardware(hardware)
                }
                if hardware.mode != .uhd {
                    guard !transaction.modeCleanupUsed else { throw RecoveryError.operationFailed("4K 收尾额度已使用") }
                    try await waitControlGap(limit)
                    transaction.modeCleanupUsed = true
                    try await persist()
                    try await writeMode(.uhd, deadline: limit)
                    try await wait(limit, operation: "收尾确认 MSI UHD") { try await self.readHardware(limit).mode == .uhd }
                }
                // 无需写入时也从新鲜 HID 确认起保持模式稳定窗口。
                holdControls(for: configuration.timeouts.modeSettle)
                try await wait(limit, operation: "MSI 4K 收尾稳定观察", minimumUntil: nextControlAt) {
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
            transaction.stopReason = transaction.hasPendingCleanup ? reason : "同一故障已达到三次恢复上限"
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
        let intervals = [configuration.pollInterval, t.powerOff, t.powerOn, t.newDisplayOnline, t.safeMode, t.oldDisplayOnline, t.restoreMode, t.dualDisplayStabilize, t.singleDisplayObserve, t.powerOffMinimum, t.powerOnSettle, t.modeSettle, t.hardwareReady]
        guard intervals.allSatisfy({ $0.isFinite && $0 > 0 }), configuration.recoveryCooldown.isFinite, configuration.recoveryCooldown >= 0 else {
            throw RecoveryError.operationFailed("恢复时间配置必须为有效正数")
        }
        guard t.newDisplayOnline >= t.powerOffMinimum, t.oldDisplayOnline >= t.modeSettle,
              t.powerOffMinimum <= 15, t.powerOnSettle <= 15, t.modeSettle <= 15, t.hardwareReady <= 15 else {
            throw RecoveryError.operationFailed("观察窗口必须覆盖最低保持时间，保持与就绪时间不能超过有限收尾预算允许的 15 秒")
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
    private func observe(_ limit: RecoveryDeadline, allowInactive: Bool = false) async throws -> Topology {
        try limit.check()
        let observation = try await io.observeDisplays(deadline: limit)
        try limit.check()
        try checkFresh(observation.observedAt)
        func resolve(_ role: DisplayRole) throws -> DisplaySnapshot? {
            switch DisplayRoleResolver.resolve(role: role, rolesConfig: configuration.roles, snapshots: observation.snapshots) {
            case .matched(let snapshot):
                guard allowInactive || (snapshot.isActive && !snapshot.isAsleep) else { throw RecoveryError.operationFailed("目标显示器休眠或尚未激活") }
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
            let observation = "\(topology.key) ANT激活=\(ant?.isActive.description ?? "未知") MSI激活=\(msi?.isActive.description ?? "未知") MSI=\(msi?.mode?.shortDescription ?? "未知")"
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
        try await waitControlGap(deadline)
        _ = try await observe(deadline) // 歧义时不能继续下发指令。
        try deadline.check()
        holdControls(for: configuration.timeouts.modeSettle)
        publish("发送 MSI \(mode.rawValue) 控制命令；下一次控制最早在 \(Int(configuration.timeouts.modeSettle)) 秒后")
        do {
            try await io.setHardwareMode(mode, expectedIdentity: identity, deadline: deadline)
        } catch {
            // 命令可能已到达设备但应答丢失；失败也从本次尝试开始重新计时。
            holdControls(for: configuration.timeouts.modeSettle)
            throw error
        }
        // 从 I/O 返回后再延长一次，确保耗时写入也留下完整的最低稳定时间。
        holdControls(for: configuration.timeouts.modeSettle)
        try deadline.check()
    }
    private func waitHardwareReady(deadline: RecoveryDeadline) async throws -> HardwareModeObservation {
        var result: HardwareModeObservation?
        try await wait(deadline, operation: "等待 MSI HID 就绪") {
            let hardware = try await self.readHardware(deadline)
            guard hardware.mode != .unknown else { throw RecoveryError.monitorUnavailable }
            result = hardware
            return true
        }
        return result!
    }
    private func wait(_ limit: RecoveryDeadline, operation: String = "等待硬件状态", minimumUntil: TimeInterval = 0,
                      condition: () async throws -> Bool) async throws {
        let started = clock.monotonicNow
        var lastProgress: TimeInterval = -Double.infinity
        var detail = "尚未满足条件"
        while true {
            try tokenCheck(limit.cancellation)
            guard limit.remaining > 0 else {
                throw RecoveryError.operationTimedOut("\(operation)，已等待 \(Int(clock.monotonicNow - started)) 秒；最后状态：\(detail)")
            }
            do {
                let ready = try await condition()
                try limit.check(operation)
                detail = ready ? "已读到目标状态，继续满足最低保持时间" : (lastRecoveryObservation ?? "尚未满足条件")
                if ready, clock.monotonicNow >= minimumUntil { return }
            } catch {
                if limit.cancellation.reason != nil || isIdentityError(error) { throw error }
                detail = error.localizedDescription
            }
            reportWaiting(operation, started: started, lastProgress: &lastProgress, detail: detail)
            try await clock.sleep(seconds: min(configuration.pollInterval, limit.remaining))
        }
    }

    private func boundedDeadline(_ seconds: TimeInterval, within limit: RecoveryDeadline) -> RecoveryDeadline {
        deadline(min(seconds, limit.remaining), limit.cancellation)
    }
    private func holdControls(for seconds: TimeInterval) {
        nextControlAt = max(nextControlAt, clock.monotonicNow + seconds)
    }
    private func writePower(_ on: Bool, deadline: RecoveryDeadline) async throws {
        try await waitControlGap(deadline)
        try deadline.check("插座控制")
        holdControls(for: on ? configuration.timeouts.powerOnSettle : configuration.timeouts.powerOffMinimum)
        publish("发送 ANT 插座\(on ? "开启" : "关闭")命令；记录最低控制间隔")
        do {
            try await io.setPlugPower(on, deadline: deadline)
        } catch {
            holdControls(for: on ? configuration.timeouts.powerOnSettle : configuration.timeouts.powerOffMinimum)
            throw error
        }
        holdControls(for: on ? configuration.timeouts.powerOnSettle : configuration.timeouts.powerOffMinimum)
        try deadline.check("插座控制")
    }
    private func waitControlGap(_ limit: RecoveryDeadline) async throws {
        guard clock.monotonicNow < nextControlAt else { return }
        try await wait(limit, operation: "等待上一控制动作稳定", minimumUntil: nextControlAt) { true }
    }
    private func settleControls(_ token: RecoveryCancellation, operation: String) async throws {
        let limit = deadline(max(0, nextControlAt - clock.monotonicNow) + 3, token)
        try await wait(limit, operation: operation, minimumUntil: nextControlAt) {
            do { _ = try await self.observe(limit, allowInactive: true) }
            catch { if self.isIdentityError(error) { throw error } }
            return true
        }
    }
    private func reportWaiting(_ operation: String, started: TimeInterval, lastProgress: inout TimeInterval, detail: String) {
        let now = clock.monotonicNow
        guard now - lastProgress >= 5 else { return }
        lastProgress = now
        publish("\(operation)：已等待 \(Int(now - started)) 秒；\(detail)")
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
        publish(singleObservationMessage)
        return false
    }
    private var singleObservationMessage: String { "等待同一单屏状态稳定 \(Int(configuration.timeouts.singleDisplayObserve)) 秒" }
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

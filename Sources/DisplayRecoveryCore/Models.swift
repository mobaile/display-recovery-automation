import Foundation

public struct DisplayModeSignature: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var refreshRate: Double
    public var pixelEncoding: String?

    public init(width: Int, height: Int, refreshRate: Double, pixelEncoding: String? = nil) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.pixelEncoding = pixelEncoding
    }

    public var shortDescription: String {
        let refresh: String
        if refreshRate <= 0 {
            refresh = "未知"
        } else {
            refresh = refreshRate.rounded() == refreshRate
                ? String(format: "%.0f", refreshRate)
                : String(format: "%.2f", refreshRate)
        }
        return refreshRate <= 0
            ? "\(width)×\(height) @ 未知"
            : "\(width)×\(height) @ \(refresh)Hz"
    }

    public func approximatelyEquals(_ other: DisplayModeSignature, tolerance: Double = 0.75) -> Bool {
        guard width == other.width, height == other.height else { return false }
        // HID 只能告诉我们当前是 UHD/FHD 双模式，无法提供实际刷新率；0
        // 表示未知刷新率，在等待模式生效时只校验分辨率。
        return refreshRate <= 0 || other.refreshRate <= 0 || abs(refreshRate - other.refreshRate) <= tolerance
    }
    public var is4K: Bool {
        width >= 3840 && height >= 2160
    }

    public var is1080P: Bool {
        width == 1920 && height == 1080
    }
}

public enum MsiHardwareDualMode: String, Codable, Sendable {
    case uhd = "UHD"
    case fhd = "FHD"
    case unknown = "Unknown"
}

public struct DisplayFingerprint: Codable, Equatable, Hashable, Sendable {
    public var vendor: String?
    public var model: String?
    public var serial: String?
    public var edidHash: String?

    public init(vendor: String? = nil, model: String? = nil, serial: String? = nil, edidHash: String? = nil) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.edidHash = edidHash
    }

    public func matches(_ other: DisplayFingerprint) -> Bool {
        matchesConfiguredComponent(vendor, other.vendor) &&
            matchesConfiguredComponent(model, other.model) &&
            matchesConfiguredComponent(serial, other.serial) &&
            matchesConfiguredComponent(edidHash, other.edidHash)
    }

    private func matchesConfiguredComponent(_ configured: String?, _ actual: String?) -> Bool {
        guard let configured, !configured.isEmpty else {
            return true
        }
        guard let actual, !actual.isEmpty else { return false }
        return configured.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(actual.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    public var isConfigured: Bool {
        [vendor, model, serial, edidHash].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public var displayName: String {
        [vendor, model].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " ")
    }
}

public struct DisplaySnapshot: Codable, Equatable, Hashable, Sendable {
    public var displayID: UInt32
    public var fingerprint: DisplayFingerprint
    public var mode: DisplayModeSignature?
    public var online: Bool
    public var isBuiltin: Bool
    public var isActive: Bool
    public var isAsleep: Bool
    public var connectionDescription: String?

    public init(
        displayID: UInt32,
        fingerprint: DisplayFingerprint,
        mode: DisplayModeSignature? = nil,
        online: Bool = true,
        isBuiltin: Bool = false,
        connectionDescription: String? = nil,
        isActive: Bool = true,
        isAsleep: Bool = false
    ) {
        self.displayID = displayID
        self.fingerprint = fingerprint
        self.mode = mode
        self.online = online
        self.isBuiltin = isBuiltin
        self.isActive = isActive
        self.isAsleep = isAsleep
        self.connectionDescription = connectionDescription
    }
}

public enum DisplayRole: String, Codable, CaseIterable, Sendable {
    case powerControlled
    case modeSwitch
}

public enum DisplayResolveResult: Equatable, Sendable {
    case matched(DisplaySnapshot)
    case notFound
    case unconfigured
    case ambiguous([DisplaySnapshot])
}

public struct DisplayRoleResolver: Sendable {
    public static func resolve(
        role: DisplayRole,
        rolesConfig: DisplayRoleConfiguration,
        snapshots: [DisplaySnapshot]
    ) -> DisplayResolveResult {
        let activeSnapshots = snapshots.filter { $0.online && !$0.isBuiltin }
        let targetFingerprint: DisplayFingerprint
        switch role {
        case .powerControlled:
            targetFingerprint = rolesConfig.powerControlled
        case .modeSwitch:
            targetFingerprint = rolesConfig.modeSwitch
        }

        guard targetFingerprint.isConfigured else {
            return .unconfigured
        }

        let matches = activeSnapshots.filter { snapshot in
            if targetFingerprint.matches(snapshot.fingerprint) {
                return true
            }
            // 别名必须是明确登记的完整指纹，不能用厂商名绕过序列号。
            return role == .modeSwitch && rolesConfig.modeSwitchAliases.contains {
                $0.isConfigured && $0.matches(snapshot.fingerprint)
            }
        }

        if matches.count == 1 {
            return .matched(matches[0])
        } else if matches.count > 1 {
            return .ambiguous(matches)
        } else {
            return .notFound
        }
    }
}

public struct DisplayRoleConfiguration: Codable, Equatable, Sendable {
    public var powerControlled: DisplayFingerprint
    public var modeSwitch: DisplayFingerprint
    public var modeSwitchAliases: [DisplayFingerprint]

    public init(
        powerControlled: DisplayFingerprint = DisplayFingerprint(vendor: "ANT", model: "ANT27VU"),
        modeSwitch: DisplayFingerprint = DisplayFingerprint(vendor: "MSI"),
        modeSwitchAliases: [DisplayFingerprint] = []
    ) {
        self.powerControlled = powerControlled
        self.modeSwitch = modeSwitch
        self.modeSwitchAliases = modeSwitchAliases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let def = DisplayRoleConfiguration()
        self.powerControlled = try container.decodeIfPresent(DisplayFingerprint.self, forKey: .powerControlled) ?? def.powerControlled
        self.modeSwitch = try container.decodeIfPresent(DisplayFingerprint.self, forKey: .modeSwitch) ?? def.modeSwitch
        self.modeSwitchAliases = try container.decodeIfPresent([DisplayFingerprint].self, forKey: .modeSwitchAliases) ?? []
    }
}

public struct RecoveryTimeouts: Codable, Equatable, Sendable {
    public var powerOff: TimeInterval
    public var newDisplayOnline: TimeInterval
    public var safeMode: TimeInterval
    public var powerOn: TimeInterval
    public var oldDisplayOnline: TimeInterval
    public var restoreMode: TimeInterval
    public var dualDisplayStabilize: TimeInterval
    public var singleDisplayObserve: TimeInterval
    public var powerOffMinimum: TimeInterval
    public var powerOnSettle: TimeInterval
    public var modeSettle: TimeInterval
    public var hardwareReady: TimeInterval

    public init(
        powerOff: TimeInterval = 15,
        newDisplayOnline: TimeInterval = 15,
        safeMode: TimeInterval = 20,
        powerOn: TimeInterval = 15,
        oldDisplayOnline: TimeInterval = 30,
        restoreMode: TimeInterval = 30,
        dualDisplayStabilize: TimeInterval = 10,
        singleDisplayObserve: TimeInterval = 10,
        powerOffMinimum: TimeInterval = 10,
        powerOnSettle: TimeInterval = 15,
        modeSettle: TimeInterval = 15,
        hardwareReady: TimeInterval = 15
    ) {
        self.powerOff = powerOff
        self.newDisplayOnline = newDisplayOnline
        self.safeMode = safeMode
        self.powerOn = powerOn
        self.oldDisplayOnline = oldDisplayOnline
        self.restoreMode = restoreMode
        self.dualDisplayStabilize = dualDisplayStabilize
        self.singleDisplayObserve = singleDisplayObserve
        self.powerOffMinimum = powerOffMinimum
        self.powerOnSettle = powerOnSettle
        self.modeSettle = modeSettle
        self.hardwareReady = hardwareReady
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let def = RecoveryTimeouts()
        self.powerOff = try container.decodeIfPresent(TimeInterval.self, forKey: .powerOff) ?? def.powerOff
        self.newDisplayOnline = try container.decodeIfPresent(TimeInterval.self, forKey: .newDisplayOnline) ?? def.newDisplayOnline
        self.safeMode = try container.decodeIfPresent(TimeInterval.self, forKey: .safeMode) ?? def.safeMode
        self.powerOn = try container.decodeIfPresent(TimeInterval.self, forKey: .powerOn) ?? def.powerOn
        self.oldDisplayOnline = try container.decodeIfPresent(TimeInterval.self, forKey: .oldDisplayOnline) ?? def.oldDisplayOnline
        self.restoreMode = try container.decodeIfPresent(TimeInterval.self, forKey: .restoreMode) ?? def.restoreMode
        self.dualDisplayStabilize = try container.decodeIfPresent(TimeInterval.self, forKey: .dualDisplayStabilize) ?? def.dualDisplayStabilize
        self.singleDisplayObserve = try container.decodeIfPresent(TimeInterval.self, forKey: .singleDisplayObserve) ?? def.singleDisplayObserve
        self.powerOffMinimum = try container.decodeIfPresent(TimeInterval.self, forKey: .powerOffMinimum) ?? def.powerOffMinimum
        self.powerOnSettle = try container.decodeIfPresent(TimeInterval.self, forKey: .powerOnSettle) ?? def.powerOnSettle
        self.modeSettle = try container.decodeIfPresent(TimeInterval.self, forKey: .modeSettle) ?? def.modeSettle
        self.hardwareReady = try container.decodeIfPresent(TimeInterval.self, forKey: .hardwareReady) ?? def.hardwareReady
    }
}

public struct RecoveryConfiguration: Codable, Equatable, Sendable {
    public var roles: DisplayRoleConfiguration
    public var safeMode: DisplayModeSignature
    public var recoveryCooldown: TimeInterval
    public var pollInterval: TimeInterval
    public var timeouts: RecoveryTimeouts
    public var automaticRecoveryEnabled: Bool

    public init(
        roles: DisplayRoleConfiguration = DisplayRoleConfiguration(),
        safeMode: DisplayModeSignature = DisplayModeSignature(width: 1920, height: 1080, refreshRate: 320),
        recoveryCooldown: TimeInterval = 30,
        pollInterval: TimeInterval = 0.5,
        timeouts: RecoveryTimeouts = RecoveryTimeouts(),
        automaticRecoveryEnabled: Bool = false
    ) {
        self.roles = roles
        self.safeMode = safeMode
        self.recoveryCooldown = recoveryCooldown
        self.pollInterval = pollInterval
        self.timeouts = timeouts
        self.automaticRecoveryEnabled = automaticRecoveryEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let def = RecoveryConfiguration()
        self.roles = try container.decodeIfPresent(DisplayRoleConfiguration.self, forKey: .roles) ?? def.roles
        self.safeMode = try container.decodeIfPresent(DisplayModeSignature.self, forKey: .safeMode) ?? def.safeMode
        self.recoveryCooldown = try container.decodeIfPresent(TimeInterval.self, forKey: .recoveryCooldown) ?? def.recoveryCooldown
        self.pollInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .pollInterval) ?? def.pollInterval
        self.timeouts = try container.decodeIfPresent(RecoveryTimeouts.self, forKey: .timeouts) ?? def.timeouts
        self.automaticRecoveryEnabled = try container.decodeIfPresent(Bool.self, forKey: .automaticRecoveryEnabled) ?? def.automaticRecoveryEnabled
    }
}

public struct PlugConfiguration: Codable, Equatable, Sendable {
    public var model: String
    public var host: String
    public var port: UInt16

    public init(model: String = "chuangmi.plug.212a01", host: String = "", port: UInt16 = 54321) {
        self.model = model
        self.host = host
        self.port = port
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let def = PlugConfiguration()
        self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? def.model
        self.host = try container.decodeIfPresent(String.self, forKey: .host) ?? def.host
        self.port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? def.port
    }
}

public enum RecoveryStage: String, Codable, Sendable {
    case idle = "Idle"
    case evaluating = "Evaluating"
    case antPowerOff = "AntPowerOff"
    case waitingAntDisconnect = "WaitingAntDisconnect"
    case waitingMsiEnumerate = "WaitingMsiEnumerate"
    case antPowerOn = "AntPowerOn"
    case antWaitingReenumerate = "AntWaitingReenumerate"
    case msiSwitch1080P = "MsiSwitch1080P"
    case waitingDualOnline = "WaitingDualOnline"
    case finalizing4K = "Finalizing4K"
    case stabilizing4K = "Stabilizing4K"
    case cleanupAndRollback = "CleanupAndRollback"
    case completed = "Completed"
    case failed = "Failed"
    case stopped = "Stopped"
    case cancelled = "Cancelled"
}

public enum RecoveryState: String, Codable, Sendable {
    case idle = "Idle"
    case oldOnlyDetected = "OldOnlyDetected"
    case newOnlyDetected = "NewOnlyDetected"
    case powerOffControlledDisplay = "PowerOffControlledDisplay"
    case waitingForNewDisplay = "WaitingForNewDisplay"
    case setNewDisplaySafeMode = "SetNewDisplaySafeMode"
    case powerOnControlledDisplay = "PowerOnControlledDisplay"
    case waitingForOldDisplay = "WaitingForOldDisplay"
    case restoreNewDisplayMode = "RestoreNewDisplayMode"
    case completed = "Completed"
    case failed = "Failed"
}

public struct RecoveryStatus: Equatable, Sendable {
    public var state: RecoveryState
    public var stage: RecoveryStage
    public var message: String
    public var lastError: String?
    public var updatedAt: Date
    public var recoveryInProgress: Bool
    public var attemptCount: Int
    public var isStopped: Bool
    public var stopReason: String?
    public var modePending4K: Bool
    public var powerPendingRestore: Bool
    public var cleanupErrors: [String]

    public init(
        state: RecoveryState = .idle,
        stage: RecoveryStage = .idle,
        message: String = "等待显示器状态",
        lastError: String? = nil,
        updatedAt: Date = Date(),
        recoveryInProgress: Bool = false,
        attemptCount: Int = 0,
        isStopped: Bool = false,
        stopReason: String? = nil,
        modePending4K: Bool = false,
        powerPendingRestore: Bool = false,
        cleanupErrors: [String] = []
    ) {
        self.state = state
        self.stage = stage
        self.message = message
        self.lastError = lastError
        self.updatedAt = updatedAt
        self.recoveryInProgress = recoveryInProgress
        self.attemptCount = attemptCount
        self.isStopped = isStopped
        self.stopReason = stopReason
        self.modePending4K = modePending4K
        self.powerPendingRestore = powerPendingRestore
        self.cleanupErrors = cleanupErrors
    }
}

public enum RecoveryOutcome: Equatable, Sendable {
    case success
    case failure(String)
    case stopped(String)
    case skipped(String)
    case busy
    case cancelled(String)
}

public protocol RecoveryClock: Sendable {
    var now: Date { get }
    var monotonicNow: TimeInterval { get }
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemRecoveryClock: RecoveryClock {
    private static let origin = ContinuousClock.now
    public init() {}
    public var now: Date { Date() }
    public var monotonicNow: TimeInterval {
        let components = Self.origin.duration(to: ContinuousClock.now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
    public func sleep(seconds: TimeInterval) async throws {
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }
}

public enum RecoveryError: LocalizedError, Equatable, Sendable {
    case incompleteDisplayConfiguration
    case displayNotFound(String)
    case ambiguousDisplay(String)
    case modeNotAvailable(DisplayModeSignature)
    case plugNotConfigured
    case plugModelMismatch(expected: String, actual: String)
    case plugUnavailable(String)
    case operationTimedOut(String)
    case monitorUnavailable
    case operationFailed(String)
    case alreadyBusy

    public var errorDescription: String? {
        switch self {
        case .incompleteDisplayConfiguration:
            return "显示器角色配置不完整"
        case .displayNotFound(let name):
            return "未找到显示器：\(name)"
        case .ambiguousDisplay(let name):
            return "发现多个匹配候选：\(name)"
        case .modeNotAvailable(let mode):
            return "显示器不支持模式：\(mode.shortDescription)"
        case .plugNotConfigured:
            return "智能插座尚未配置"
        case .plugModelMismatch(let expected, let actual):
            return "插座型号不匹配：期望 \(expected)，实际 \(actual)"
        case .plugUnavailable(let reason):
            return "智能插座不可用：\(reason)"
        case .operationTimedOut(let operation):
            return "操作超时：\(operation)"
        case .monitorUnavailable:
            return "MSI 显示器 HID 控制接口不可用"
        case .operationFailed(let reason):
            return "操作失败：\(reason)"
        case .alreadyBusy:
            return "已有恢复任务在执行中"
        }
    }
}

public protocol DisplayObservationIO: AnyObject, Sendable {
    func observeDisplays(deadline: RecoveryDeadline) async throws -> DisplayObservation
}

public protocol PlugControlIO: AnyObject, Sendable {
    func readPlugPower(deadline: RecoveryDeadline) async throws -> Bool
    func setPlugPower(_ on: Bool, deadline: RecoveryDeadline) async throws
}

public protocol ModeControlIO: AnyObject, Sendable {
    func readHardwareMode(deadline: RecoveryDeadline) async throws -> HardwareModeObservation
    func setHardwareMode(_ mode: MsiHardwareDualMode, expectedIdentity: String, deadline: RecoveryDeadline) async throws
}

public protocol RecoveryIO: DisplayObservationIO, PlugControlIO, ModeControlIO, AnyObject, Sendable {
    /// 固定控制配置的不可逆标识；不能包含原始 Token。
    var targetIdentity: String { get }
    func validateTarget(deadline: RecoveryDeadline) async throws
}

public extension RecoveryIO {
    func validateTarget(deadline: RecoveryDeadline) async throws { try deadline.check() }
}

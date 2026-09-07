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
    public var connectionDescription: String?

    public init(
        displayID: UInt32,
        fingerprint: DisplayFingerprint,
        mode: DisplayModeSignature? = nil,
        online: Bool = true,
        connectionDescription: String? = nil
    ) {
        self.displayID = displayID
        self.fingerprint = fingerprint
        self.mode = mode
        self.online = online
        self.connectionDescription = connectionDescription
    }
}

public enum DisplayRole: String, Codable, CaseIterable, Sendable {
    case powerControlled
    case modeSwitch
}

public struct DisplayRoleConfiguration: Codable, Equatable, Sendable {
    public var powerControlled: DisplayFingerprint
    public var modeSwitch: DisplayFingerprint

    public init(
        powerControlled: DisplayFingerprint = DisplayFingerprint(),
        modeSwitch: DisplayFingerprint = DisplayFingerprint(vendor: "MSI")
    ) {
        self.powerControlled = powerControlled
        self.modeSwitch = modeSwitch
    }
}

public struct RecoveryTimeouts: Codable, Equatable, Sendable {
    public var powerOff: TimeInterval
    public var newDisplayOnline: TimeInterval
    public var safeMode: TimeInterval
    public var powerOn: TimeInterval
    public var oldDisplayOnline: TimeInterval
    public var restoreMode: TimeInterval

    public init(
        powerOff: TimeInterval = 15,
        newDisplayOnline: TimeInterval = 20,
        safeMode: TimeInterval = 20,
        powerOn: TimeInterval = 15,
        oldDisplayOnline: TimeInterval = 30,
        restoreMode: TimeInterval = 30
    ) {
        self.powerOff = powerOff
        self.newDisplayOnline = newDisplayOnline
        self.safeMode = safeMode
        self.powerOn = powerOn
        self.oldDisplayOnline = oldDisplayOnline
        self.restoreMode = restoreMode
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
}

public enum RecoveryState: String, Codable, Sendable {
    case idle = "Idle"
    case oldOnlyDetected = "OldOnlyDetected"
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
    public var message: String
    public var lastError: String?
    public var updatedAt: Date
    public var recoveryInProgress: Bool

    public init(
        state: RecoveryState = .idle,
        message: String = "等待显示器状态",
        lastError: String? = nil,
        updatedAt: Date = Date(),
        recoveryInProgress: Bool = false
    ) {
        self.state = state
        self.message = message
        self.lastError = lastError
        self.updatedAt = updatedAt
        self.recoveryInProgress = recoveryInProgress
    }
}

public enum RecoveryError: LocalizedError, Equatable, Sendable {
    case incompleteDisplayConfiguration
    case displayNotFound(String)
    case modeNotAvailable(DisplayModeSignature)
    case plugNotConfigured
    case plugModelMismatch(expected: String, actual: String)
    case plugUnavailable(String)
    case operationTimedOut(String)
    case monitorUnavailable
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .incompleteDisplayConfiguration:
            return "显示器角色配置不完整"
        case .displayNotFound(let name):
            return "未找到显示器：\(name)"
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
        }
    }
}

public protocol RecoveryIO: AnyObject {
    func displaySnapshots() async -> [DisplaySnapshot]
    func setPlugPower(_ on: Bool) async throws
    func readPlugPower() async throws -> Bool
    func readModeSwitchMode() async throws -> DisplayModeSignature?
    func setModeSwitchSafeMode() async throws
    func restoreModeSwitchMode(_ mode: DisplayModeSignature) async throws
}

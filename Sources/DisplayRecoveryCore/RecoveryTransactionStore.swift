import Foundation
import Darwin

public struct RecoveryTarget: Codable, Equatable, Sendable {
    public var roles: DisplayRoleConfiguration
    public var controlIdentity: String
    public init(roles: DisplayRoleConfiguration, controlIdentity: String) {
        self.roles = roles
        self.controlIdentity = controlIdentity
    }
}

public struct RecoveryTransaction: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 2
    public var id: UUID
    public var failureID: String
    public var attemptCount: Int
    public var isStopped: Bool
    public var stopReason: String?
    public var stage: RecoveryStage
    public var powerPendingRestore: Bool
    public var modePending4K: Bool
    public var target: RecoveryTarget?
    public var msiHIDIdentity: String?
    public var powerCleanupUsed: Bool
    public var modeCleanupUsed: Bool
    public var lastError: String?
    public var cleanupErrors: [String]
    public var lastAttemptAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public var hasPendingCleanup: Bool { powerPendingRestore || modePending4K }

    public init(
        id: UUID = UUID(), failureID: String = UUID().uuidString, attemptCount: Int = 0,
        isStopped: Bool = false, stopReason: String? = nil, stage: RecoveryStage = .idle,
        powerPendingRestore: Bool = false, modePending4K: Bool = false,
        target: RecoveryTarget? = nil, msiHIDIdentity: String? = nil,
        powerCleanupUsed: Bool = false, modeCleanupUsed: Bool = false,
        lastAttemptAt: Date? = nil, createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id; self.failureID = failureID; self.attemptCount = attemptCount
        self.isStopped = isStopped; self.stopReason = stopReason; self.stage = stage
        self.powerPendingRestore = powerPendingRestore; self.modePending4K = modePending4K
        self.target = target; self.msiHIDIdentity = msiHIDIdentity
        self.powerCleanupUsed = powerCleanupUsed; self.modeCleanupUsed = modeCleanupUsed
        self.lastAttemptAt = lastAttemptAt; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.lastError = nil; self.cleanupErrors = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...2).contains(schemaVersion) else {
            throw RecoveryError.operationFailed("Unsupported transaction version: \(schemaVersion)")
        }
        id = try c.decode(UUID.self, forKey: .id)
        failureID = try c.decode(String.self, forKey: .failureID)
        attemptCount = try c.decode(Int.self, forKey: .attemptCount)
        guard (0...3).contains(attemptCount) else { throw RecoveryError.operationFailed("Invalid transaction attempt count.") }
        isStopped = try c.decode(Bool.self, forKey: .isStopped)
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        stage = try c.decode(RecoveryStage.self, forKey: .stage)
        powerPendingRestore = try c.decode(Bool.self, forKey: .powerPendingRestore)
        modePending4K = try c.decode(Bool.self, forKey: .modePending4K)
        target = try c.decodeIfPresent(RecoveryTarget.self, forKey: .target)
        msiHIDIdentity = try c.decodeIfPresent(String.self, forKey: .msiHIDIdentity)
        // 旧记录没有额度与目标证据，不能假定可以重新发出控制命令。
        powerCleanupUsed = try c.decodeIfPresent(Bool.self, forKey: .powerCleanupUsed) ?? powerPendingRestore
        modeCleanupUsed = try c.decodeIfPresent(Bool.self, forKey: .modeCleanupUsed) ?? modePending4K
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        cleanupErrors = try c.decodeIfPresent([String].self, forKey: .cleanupErrors) ?? []
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

public protocol RecoveryTransactionStoreProtocol: Sendable {
    func load() async throws -> RecoveryTransaction?
    func save(_ transaction: RecoveryTransaction) async throws
    func clear() async throws
}

public actor InMemoryRecoveryTransactionStore: RecoveryTransactionStoreProtocol {
    private var transaction: RecoveryTransaction?
    public init(initial: RecoveryTransaction? = nil) { transaction = initial }
    public func load() async throws -> RecoveryTransaction? { transaction }
    public func save(_ transaction: RecoveryTransaction) async throws { self.transaction = transaction }
    public func clear() async throws { transaction = nil }
}

/// 同目录临时文件、0600、同步数据后原子替换。替换失败保留原文件。
public enum AtomicPrivateFile {
    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RecoveryError.operationFailed("Failed to create private persistence file.")
        }
        defer { try? fm.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

public final class FileRecoveryTransactionStore: RecoveryTransactionStoreProtocol, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DisplayRecoveryAutomation/recovery-transaction.json")
    }
    public func load() throws -> RecoveryTransaction? {
        try lock.withLock {
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
            return try JSONDecoder().decode(RecoveryTransaction.self, from: data)
        }
    }
    public func save(_ transaction: RecoveryTransaction) throws {
        try lock.withLock {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicPrivateFile.write(encoder.encode(transaction), to: url)
        }
    }
    public func clear() throws {
        try lock.withLock {
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { return }
        }
    }
}

import Foundation

/// 取消标记也传给阻塞式平台接口；这些接口不继承调用方 Task 的取消状态。
public final class RecoveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReason: String?
    public init() {}
    public var reason: String? { lock.withLock { storedReason } }
    public func cancel(_ reason: String) { lock.withLock { if storedReason == nil { storedReason = reason } } }
}

public struct RecoveryDeadline: Sendable {
    public let clock: any RecoveryClock
    public let expiresAt: TimeInterval
    public let cancellation: RecoveryCancellation

    public init(seconds: TimeInterval, clock: any RecoveryClock = SystemRecoveryClock(), cancellation: RecoveryCancellation = RecoveryCancellation()) {
        self.clock = clock
        self.expiresAt = clock.monotonicNow + max(0, seconds)
        self.cancellation = cancellation
    }

    public var remaining: TimeInterval { max(0, expiresAt - clock.monotonicNow) }
    public func check(_ operation: String = "硬件操作") throws {
        if cancellation.reason != nil { throw CancellationError() }
        guard remaining > 0 else { throw RecoveryError.operationTimedOut(operation) }
    }
    public func sleep(_ seconds: TimeInterval) async throws {
        try check()
        try await clock.sleep(seconds: min(seconds, remaining))
        try check()
    }
}

public struct DisplayObservation: Equatable, Sendable {
    public let snapshots: [DisplaySnapshot]
    public let observedAt: TimeInterval
    public init(snapshots: [DisplaySnapshot], observedAt: TimeInterval) {
        self.snapshots = snapshots
        self.observedAt = observedAt
    }
}

public struct HardwareModeObservation: Equatable, Sendable {
    public let mode: MsiHardwareDualMode
    public let identity: String
    public let observedAt: TimeInterval
    public init(mode: MsiHardwareDualMode, identity: String, observedAt: TimeInterval) {
        self.mode = mode
        self.identity = identity
        self.observedAt = observedAt
    }
}

public protocol RecoveryTransactionLockProtocol: Sendable {
    func tryLock() -> Bool
    func unlock()
}

public final class InMemoryRecoveryTransactionLock: RecoveryTransactionLockProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    public init() {}
    public func tryLock() -> Bool {
        lock.withLock {
            guard !held else { return false }
            held = true
            return true
        }
    }
    public func unlock() { lock.withLock { held = false } }
}

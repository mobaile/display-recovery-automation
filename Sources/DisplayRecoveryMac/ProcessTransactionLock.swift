import Foundation
import Darwin
import DisplayRecoveryCore

public final class ProcessTransactionLock: RecoveryTransactionLockProtocol, @unchecked Sendable {
    public let url: URL
    private var fileDescriptor: Int32 = -1
    private let lock = NSLock()

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.url = appSupport
                .appendingPathComponent("DisplayRecoveryAutomation", isDirectory: true)
                .appendingPathComponent("recovery.lock")
        }
    }

    deinit {
        unlock()
    }

    public func tryLock() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard fileDescriptor < 0 else { return false }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }

        self.fileDescriptor = fd
        return true
    }

    public func unlock() {
        lock.lock()
        defer { lock.unlock() }

        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
    }

    public func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        guard tryLock() else {
            throw RecoveryError.alreadyBusy
        }
        defer { unlock() }
        return try await operation()
    }
}

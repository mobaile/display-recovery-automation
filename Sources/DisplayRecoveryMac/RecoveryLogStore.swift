import Foundation

public final class RecoveryLogStore: @unchecked Sendable {
    public let url: URL
    public let legacyUrl: URL
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter
    private var lastMessage: String?
    private var repeatCount = 0
    private let maxFileSize: Int64 = 2 * 1024 * 1024 // 2MB
    private let maxInMemoryLogs = 500
    private var memoryBuffer: [String] = []
    private var subscribers: [UUID: @Sendable (String) -> Void] = [:]

    public init(url: URL? = nil) {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let baseDir = logsDir.appendingPathComponent("Logs/DisplayRecoveryAutomation", isDirectory: true)

        if let url {
            self.url = url
            self.legacyUrl = url.deletingLastPathComponent().appendingPathComponent("recovery.log")
        } else {
            self.url = baseDir.appendingPathComponent("screenpilot.log")
            self.legacyUrl = baseDir.appendingPathComponent("recovery.log")
        }

        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func subscribe(_ subscriber: @escaping @Sendable (String) -> Void) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        subscribers[id] = subscriber
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        subscribers.removeValue(forKey: id)
    }

    public func recentLogs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return memoryBuffer
    }

    public func append(_ message: String, transactionID: String? = nil) {
        let redacted = Self.redact(message)
        let formattedMsg = transactionID.map { "[\($0)] \(redacted)" } ?? redacted

        var callbacks: [@Sendable (String) -> Void] = []
        var linesToEmit: [String] = []

        lock.lock()
        if formattedMsg == lastMessage {
            repeatCount += 1
            lock.unlock()
            return
        }

        if repeatCount > 0 {
            let repeatText = "[\(formatter.string(from: Date()))] (Previous message repeated \(repeatCount) times)"
            linesToEmit.append(repeatText)
            appendMemoryLocked(repeatText)
        }
        repeatCount = 0
        lastMessage = formattedMsg

        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(formattedMsg)"
        linesToEmit.append(line)
        appendMemoryLocked(line)

        callbacks = Array(subscribers.values)
        lock.unlock()

        // 发送给订阅者（锁外调用）
        for line in linesToEmit {
            for cb in callbacks {
                cb(line)
            }
        }

        // 写入文件
        for line in linesToEmit {
            writeLine(line)
        }
    }

    private func appendMemoryLocked(_ line: String) {
        memoryBuffer.append(line)
        if memoryBuffer.count > maxInMemoryLogs {
            memoryBuffer.removeFirst(memoryBuffer.count - maxInMemoryLogs)
        }
    }

    private func writeLine(_ formattedLine: String) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            rotateIfNeeded()

            let text = formattedLine + "\n"
            if let data = text.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url, options: [.atomic])
                }
            }
        } catch {
            // 日志保存失败不阻止设备操作，内存日志仍显示
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              size > maxFileSize else {
            return
        }
        let backup = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    public func redactedContents() -> String {
        lock.lock()
        defer { lock.unlock() }

        // 若当前文件尚无内容且存在旧日志，则包含旧日志
        let currentRotated = (try? String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8)) ?? ""
        let currentFile = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let legacyFile = (FileManager.default.fileExists(atPath: legacyUrl.path) ? (try? String(contentsOf: legacyUrl, encoding: .utf8)) : nil) ?? ""

        let repeats = repeatCount > 0 ? "[\(formatter.string(from: Date()))] (Last message repeated \(repeatCount) times)\n" : ""

        var combined = ""
        if !legacyFile.isEmpty {
            combined += "--- Legacy Logs ---\n" + legacyFile + "\n--- ScreenPilot Logs ---\n"
        }
        combined += currentRotated + currentFile + repeats

        if combined.isEmpty {
            if !memoryBuffer.isEmpty {
                return memoryBuffer.joined(separator: "\n") + "\n"
            }
            return "No logs available\n"
        }
        return Self.redact(combined)
    }

    public func exportRedacted(to destination: URL) throws {
        guard let data = redactedContents().data(using: .utf8) else {
            throw NSError(
                domain: "ScreenPilot.LogStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode redacted log content."]
            )
        }
        try data.write(to: destination, options: [.atomic])
    }

    public static func redact(_ text: String) -> String {
        var result = text
        // 脱敏 IPv4
        if let ipRegex = try? NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = ipRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "<IP>")
        }
        // 脱敏 32 位 Token
        if let tokenRegex = try? NSRegularExpression(pattern: #"\b[0-9a-fA-F]{32}\b"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = tokenRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "<TOKEN>")
        }
        return result
    }
}

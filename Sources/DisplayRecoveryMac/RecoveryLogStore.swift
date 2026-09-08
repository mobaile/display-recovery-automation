import Foundation

public final class RecoveryLogStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter
    private var lastMessage: String?
    private var repeatCount = 0
    private let maxFileSize: Int64 = 2 * 1024 * 1024 // 2MB

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
            self.url = logs
                .appendingPathComponent("Logs/DisplayRecoveryAutomation", isDirectory: true)
                .appendingPathComponent("recovery.log")
        }
        formatter = ISO8601DateFormatter()
    }

    public func append(_ message: String, transactionID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        let redacted = Self.redact(message)
        let formattedMsg = transactionID.map { "[\($0)] \(redacted)" } ?? redacted

        // 去重检查：相同消息只记录计数
        if formattedMsg == lastMessage {
            repeatCount += 1
            return
        }

        if repeatCount > 0 {
            writeLine("（上一条消息重复 \(repeatCount) 次）")
        }
        repeatCount = 0

        lastMessage = formattedMsg
        NSLog("DisplayRecovery: %@", formattedMsg)
        writeLine(formattedMsg)
    }

    private func writeLine(_ text: String) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            rotateIfNeeded()

            let line = "[\(formatter.string(from: Date()))] \(text)\n"
            if let data = line.data(using: .utf8) {
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
            // 日志写入失败不改变主流程
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
        let rotated = (try? String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8)) ?? ""
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let repeats = repeatCount > 0 ? "（最后一条消息重复 \(repeatCount) 次）\n" : ""
        let contents = rotated + current + repeats
        return contents.isEmpty ? "暂无日志\n" : Self.redact(contents)
    }

    public func exportRedacted(to destination: URL) throws {
        guard let data = redactedContents().data(using: .utf8) else {
            throw NSError(
                domain: "DisplayRecoveryAutomation.LogStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法编码脱敏日志"]
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

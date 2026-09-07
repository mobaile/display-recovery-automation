import Foundation

public final class RecoveryLogStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

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

    public func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
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
            // 日志失败不应改变显示器恢复流程。
        }
    }

    public func redactedContents() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "暂无日志\n"
        }
        return Self.redact(contents)
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

    private static func redact(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "<IP>")
    }
}

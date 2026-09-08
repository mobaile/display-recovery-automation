import XCTest
@testable import DisplayRecoveryMac

final class RecoveryLogStoreTests: XCTestCase {
    func testIncrementalLogSubscriptionEmitsNewLines() {
        let tempUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-test-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: tempUrl)
            try? FileManager.default.removeItem(at: tempUrl.appendingPathExtension("1"))
        }

        let store = RecoveryLogStore(url: tempUrl)
        let receivedLines = SafeBox<[String]>([])

        let subId = store.subscribe { line in
            receivedLines.mutate { $0.append(line) }
        }

        store.append("Action 1 started")
        store.append("Action 1 finished")

        let lines = receivedLines.value
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("Action 1 started"))
        XCTAssertTrue(lines[1].contains("Action 1 finished"))

        store.unsubscribe(subId)
        store.append("Action 2 started")

        XCTAssertEqual(receivedLines.value.count, 2, "Unsubscribed subscriber should not receive new lines")
    }

    func testRedactionOfIPAndToken() {
        let tempUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-test-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: tempUrl)
        }

        let store = RecoveryLogStore(url: tempUrl)
        let emittedLine = SafeBox<String>("")

        _ = store.subscribe { line in
            emittedLine.mutate { $0 = line }
        }

        let rawMessage = "Connected to 192.168.31.55 with token 3457607c43a7f21d9db4166e0ef2788c successfully."
        store.append(rawMessage)

        let line = emittedLine.value
        XCTAssertFalse(line.contains("192.168.31.55"))
        XCTAssertTrue(line.contains("<IP>"))
        XCTAssertFalse(line.contains("3457607c43a7f21d9db4166e0ef2788c"))
        XCTAssertTrue(line.contains("<TOKEN>"))

        let content = store.redactedContents()
        XCTAssertFalse(content.contains("192.168.31.55"))
        XCTAssertTrue(content.contains("<IP>"))
        XCTAssertFalse(content.contains("3457607c43a7f21d9db4166e0ef2788c"))
        XCTAssertTrue(content.contains("<TOKEN>"))
    }

    func testMemoryBufferCapAt500() {
        let tempUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-test-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: tempUrl)
        }

        let store = RecoveryLogStore(url: tempUrl)
        for i in 1...600 {
            store.append("Entry \(i)")
        }

        let recent = store.recentLogs()
        XCTAssertEqual(recent.count, 500)
        XCTAssertTrue(recent.first?.contains("Entry 101") == true)
        XCTAssertTrue(recent.last?.contains("Entry 600") == true)
    }

    func testRotationAt2MB() throws {
        let tempUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-test-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: tempUrl)
            try? FileManager.default.removeItem(at: tempUrl.appendingPathExtension("1"))
        }

        let store = RecoveryLogStore(url: tempUrl)
        // 创建超过 2MB 的前置文件
        let bigData = Data(repeating: 65, count: 2 * 1024 * 1024 + 100)
        try bigData.write(to: tempUrl)

        // 再次写入日志应触发轮转
        store.append("Trigger rotation")

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempUrl.appendingPathExtension("1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempUrl.path))
    }

    func testExportRedacted() throws {
        let tempUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-test-\(UUID().uuidString).log")
        let exportUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("exported-log-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: tempUrl)
            try? FileManager.default.removeItem(at: exportUrl)
        }

        let store = RecoveryLogStore(url: tempUrl)
        store.append("Test export with 10.0.0.1")

        try store.exportRedacted(to: exportUrl)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportUrl.path))

        let exportedText = try String(contentsOf: exportUrl, encoding: .utf8)
        XCTAssertTrue(exportedText.contains("<IP>"))
        XCTAssertFalse(exportedText.contains("10.0.0.1"))
    }
}

private final class SafeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var internalValue: T

    init(_ value: T) {
        self.internalValue = value
    }

    var value: T {
        lock.withLock { internalValue }
    }

    func mutate(_ transform: (inout T) -> Void) {
        lock.withLock { transform(&internalValue) }
    }
}

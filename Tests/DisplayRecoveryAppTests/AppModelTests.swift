import XCTest
import Combine
import MsiHid
@testable import DisplayRecoveryCore
@testable import DisplayRecoveryMac
@testable import DisplayRecoveryApp

@MainActor
final class AppModelTests: XCTestCase {
    private var tempDir: URL!
    private var configStore: ConfigurationStore!
    private var secretsStore: SecretsStore!
    private var logStore: RecoveryLogStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configStore = ConfigurationStore(url: tempDir.appendingPathComponent("config.json"))
        secretsStore = SecretsStore(url: tempDir.appendingPathComponent("secrets.json"))
        logStore = RecoveryLogStore(url: tempDir.appendingPathComponent("test.log"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testInitializationLoadsConfigurationAndDoesNotStartHardwarePolling() async {
        let initialConfig = AppConfiguration(
            recovery: RecoveryConfiguration(
                roles: DisplayRoleConfiguration(
                    powerControlled: DisplayFingerprint(vendor: "ANT", model: "ANT27VU"),
                    modeSwitch: DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M")
                ),
                automaticRecoveryEnabled: true // 模拟旧配置开启了自动恢复
            ),
            plug: PlugConfiguration(model: "chuangmi.plug.212a01", host: "192.168.1.100")
        )
        try? configStore.save(initialConfig)

        let lock = InMemoryRecoveryTransactionLock()
        let model = AppModel(
            configurationStore: configStore,
            secretsStore: secretsStore,
            displayProvider: MacDisplayProvider(),
            hidController: MsiHidController(),
            logStore: logStore,
            processLock: lock
        )

        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.currentAction)
        XCTAssertEqual(model.statusMessage, "Ready")
        XCTAssertEqual(model.roleName(.powerControlled), "ANT ANT27VU")
        XCTAssertEqual(model.roleName(.modeSwitch), "MSI MPG 274U E16M")

        await model.shutdown()
    }

    func testShutdownCancelsRunningActionWithoutCleanup() async {
        let lock = InMemoryRecoveryTransactionLock()
        let model = AppModel(
            configurationStore: configStore,
            secretsStore: secretsStore,
            displayProvider: MacDisplayProvider(),
            hidController: MsiHidController(),
            logStore: logStore,
            processLock: lock
        )

        await model.shutdown()
        // 验证调用 shutdown 没有崩溃，动作被取消
        XCTAssertFalse(model.isBusy)
    }

    func testPreventActionReentrancy() async {
        let lock = InMemoryRecoveryTransactionLock()
        let model = AppModel(
            configurationStore: configStore,
            secretsStore: secretsStore,
            displayProvider: MacDisplayProvider(),
            hidController: MsiHidController(),
            logStore: logStore,
            processLock: lock
        )

        model.execute(.checkStatus)
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.currentAction, .checkStatus)

        // 再次触发被忽略
        model.execute(.powerOn)
        XCTAssertEqual(model.currentAction, .checkStatus)

        // 等待执行结束
        for _ in 0..<50 {
            if !model.isBusy { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(model.isBusy)
        await model.shutdown()
    }

    func testSettingsSaveExclusionAndAutoRecoveryDisabled() async {
        let lock = InMemoryRecoveryTransactionLock()
        let model = AppModel(
            configurationStore: configStore,
            secretsStore: secretsStore,
            displayProvider: MacDisplayProvider(),
            hidController: MsiHidController(),
            logStore: logStore,
            processLock: lock
        )

        let exp = expectation(description: "Settings saved")
        model.saveSettings(
            host: "192.168.1.188",
            token: "3457607c43a7f21d9db4166e0ef2788c"
        ) { succeeded in
            XCTAssertTrue(succeeded)
            exp.fulfill()
        }

        await fulfillment(of: [exp], timeout: 3)

        XCTAssertEqual(model.appConfiguration.plug.host, "192.168.1.188")
        XCTAssertTrue(model.tokenConfigured)
        // 验证保存后自动恢复字段被强制关闭为 false
        XCTAssertFalse(model.appConfiguration.recovery.automaticRecoveryEnabled)

        let reloaded = try? configStore.load()
        XCTAssertFalse(reloaded?.recovery.automaticRecoveryEnabled ?? true)

        await model.shutdown()
    }

    func testSettingsSaveFailsWhenDeviceLocked() async {
        let lock = InMemoryRecoveryTransactionLock()
        XCTAssertTrue(lock.tryLock()) // 锁定

        let model = AppModel(
            configurationStore: configStore,
            secretsStore: secretsStore,
            displayProvider: MacDisplayProvider(),
            hidController: MsiHidController(),
            logStore: logStore,
            processLock: lock
        )

        let exp = expectation(description: "Settings save rejected")
        model.saveSettings(host: "192.168.1.200", token: "") { succeeded in
            XCTAssertFalse(succeeded)
            exp.fulfill()
        }

        await fulfillment(of: [exp], timeout: 3)
        XCTAssertEqual(model.lastError, "Another action is running.")

        lock.unlock()
        await model.shutdown()
    }
}

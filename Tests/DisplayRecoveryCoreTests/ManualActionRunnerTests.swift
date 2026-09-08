import XCTest
@testable import DisplayRecoveryCore

final class ManualActionRunnerTests: XCTestCase {
    func testCheckStatusReportsAllSubsystemsEvenIfSomeFail() async {
        let clock = TestRecoveryClock()
        let ant = DisplaySnapshot(
            displayID: 1,
            fingerprint: DisplayFingerprint(vendor: "ANT", model: "ANT27VU"),
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 60),
            online: true
        )
        let msi = DisplaySnapshot(
            displayID: 2,
            fingerprint: DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M"),
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 120),
            online: true
        )
        let io = MockRecoveryIO(
            snapshots: [ant, msi],
            plugPower: true,
            hardwareMode: HardwareModeObservation(mode: .uhd, identity: "msi-1", observedAt: 0)
        )
        io.shouldFailReadPlugPower = RecoveryError.plugUnavailable("Network unreachable")

        let runner = ManualActionRunner(io: io, clock: clock)
        let result = await runner.execute(.checkStatus)

        XCTAssertEqual(result.action, .checkStatus)
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(result.shortMessage, "Status checked.")
        XCTAssertTrue(result.technicalDetails?.contains("ANT display") == true)
        XCTAssertTrue(result.technicalDetails?.contains("Smart plug: Read failed") == true)
        XCTAssertTrue(result.technicalDetails?.contains("MSI hardware mode: UHD") == true)
    }

    func testPowerOffAlreadyOffReturnsImmediatelyWithoutWriting() async {
        let clock = TestRecoveryClock()
        let io = MockRecoveryIO(snapshots: [], plugPower: false)
        let runner = ManualActionRunner(io: io, clock: clock)

        let result = await runner.execute(.powerOff)
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(result.shortMessage, "Power is already off.")
        XCTAssertEqual(io.plugPowerCalls.count, 0)
    }

    func testPowerOffSendsCommandAndVerifiesReadback() async {
        let clock = TestRecoveryClock()
        let io = MockRecoveryIO(snapshots: [], plugPower: true)
        // 第一次读取是开；写入关后读回变成关
        io.onSetPlugPower = { on in
            io.plugPower = on
        }
        let runner = ManualActionRunner(io: io, clock: clock)

        let result = await runner.execute(.powerOff)
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(result.shortMessage, "Power is off.")
        XCTAssertEqual(io.plugPowerCalls, [false])
    }

    func testPowerOnAlreadyOnReturnsImmediatelyWithoutWriting() async {
        let clock = TestRecoveryClock()
        let io = MockRecoveryIO(snapshots: [], plugPower: true)
        let runner = ManualActionRunner(io: io, clock: clock)

        let result = await runner.execute(.powerOn)
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(result.shortMessage, "Power is already on.")
        XCTAssertEqual(io.plugPowerCalls.count, 0)
    }

    func testPowerOnSendsCommandAndVerifiesReadback() async {
        let clock = TestRecoveryClock()
        let io = MockRecoveryIO(snapshots: [], plugPower: false)
        io.onSetPlugPower = { on in
            io.plugPower = on
        }
        let runner = ManualActionRunner(io: io, clock: clock)

        let result = await runner.execute(.powerOn)
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(result.shortMessage, "Power is on.")
        XCTAssertEqual(io.plugPowerCalls, [true])
    }

    func testPowerTimeoutReturnsUnconfirmed() async {
        let clock = TestRecoveryClock()
        let io = MockRecoveryIO(snapshots: [], plugPower: true)
        // 写入不改变状态，造成读回超时
        let runner = ManualActionRunner(io: io, clock: clock)

        let result = await runner.execute(.powerOff)
        XCTAssertEqual(result.outcome, .unconfirmed)
        XCTAssertEqual(result.shortMessage, "Power state unconfirmed.")
        XCTAssertEqual(io.plugPowerCalls, [false])
    }

    func testLowerResolutionAlreadyFHDReturnsImmediately() async {
        let clock = TestRecoveryClock()
        let msi = DisplaySnapshot(
            displayID: 2,
            fingerprint: DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M"),
            mode: DisplayModeSignature(width: 1920, height: 1080, refreshRate: 60),
            online: true
        )
        let io = MockRecoveryIO(
            snapshots: [msi],
            hardwareMode: HardwareModeObservation(mode: .fhd, identity: "msi-1", observedAt: 0)
        )
        let runner = ManualActionRunner(io: io, clock: clock)

        let result = await runner.execute(.lowerResolution)
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(result.shortMessage, "Resolution is already 1080P.")
        XCTAssertEqual(io.hardwareModeCalls.count, 0)
    }

    func testLowerResolutionSwitchesAndVerifies() async {
        let clock = TestRecoveryClock()
        let msi4K = DisplaySnapshot(
            displayID: 2,
            fingerprint: DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M"),
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 120),
            online: true
        )
        let io = MockRecoveryIO(
            snapshots: [msi4K],
            hardwareMode: HardwareModeObservation(mode: .uhd, identity: "msi-1", observedAt: 0)
        )
        io.onSetHardwareMode = { mode in
            io.hardwareMode = HardwareModeObservation(mode: mode, identity: "msi-1", observedAt: clock.monotonicNow)
            io.snapshots = [
                DisplaySnapshot(
                    displayID: 2,
                    fingerprint: DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M"),
                    mode: DisplayModeSignature(width: 1920, height: 1080, refreshRate: 60),
                    online: true
                )
            ]
        }
        let runner = ManualActionRunner(io: io, clock: clock)

        let result = await runner.execute(.lowerResolution)
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(result.shortMessage, "Resolution lowered to 1080P.")
        XCTAssertEqual(io.hardwareModeCalls, [.fhd])
    }

    func testRestoreFullResolutionAlready4KUHDReturnsImmediately() async {
        let clock = TestRecoveryClock()
        let msi4K = DisplaySnapshot(
            displayID: 2,
            fingerprint: DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M"),
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 120),
            online: true
        )
        let io = MockRecoveryIO(
            snapshots: [msi4K],
            hardwareMode: HardwareModeObservation(mode: .uhd, identity: "msi-1", observedAt: 0)
        )
        let runner = ManualActionRunner(io: io, clock: clock)

        let result = await runner.execute(.restoreFullResolution)
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(result.shortMessage, "Resolution is already 4K UHD.")
        XCTAssertEqual(io.hardwareModeCalls.count, 0)
    }

    func testRestoreFullResolutionSwitchesAndVerifies() async {
        let clock = TestRecoveryClock()
        let msiFHD = DisplaySnapshot(
            displayID: 2,
            fingerprint: DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M"),
            mode: DisplayModeSignature(width: 1920, height: 1080, refreshRate: 60),
            online: true
        )
        let io = MockRecoveryIO(
            snapshots: [msiFHD],
            hardwareMode: HardwareModeObservation(mode: .fhd, identity: "msi-1", observedAt: 0)
        )
        io.onSetHardwareMode = { mode in
            io.hardwareMode = HardwareModeObservation(mode: mode, identity: "msi-1", observedAt: clock.monotonicNow)
            io.snapshots = [
                DisplaySnapshot(
                    displayID: 2,
                    fingerprint: DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M"),
                    mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 120),
                    online: true
                )
            ]
        }
        let runner = ManualActionRunner(io: io, clock: clock)

        let result = await runner.execute(.restoreFullResolution)
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(result.shortMessage, "Full resolution restored (4K UHD).")
        XCTAssertEqual(io.hardwareModeCalls, [.uhd])
    }

    func testVerifyBothScreensSucceedsWhenStableFor10s() async {
        let clock = TestRecoveryClock()
        let ant = DisplaySnapshot(
            displayID: 1,
            fingerprint: DisplayFingerprint(vendor: "ANT", model: "ANT27VU"),
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 60),
            online: true,
            isActive: true,
            isAsleep: false
        )
        let msi = DisplaySnapshot(
            displayID: 2,
            fingerprint: DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M"),
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 120),
            online: true,
            isActive: true,
            isAsleep: false
        )
        let io = MockRecoveryIO(
            snapshots: [ant, msi],
            plugPower: true,
            hardwareMode: HardwareModeObservation(mode: .uhd, identity: "msi-1", observedAt: 0)
        )
        let runner = ManualActionRunner(io: io, clock: clock)

        let result = await runner.execute(.verifyBothScreens)
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertEqual(result.shortMessage, "Both screens verified.")
    }

    func testVerifyBothScreensFailsWhenDisplayMissing() async {
        let clock = TestRecoveryClock()
        let ant = DisplaySnapshot(
            displayID: 1,
            fingerprint: DisplayFingerprint(vendor: "ANT", model: "ANT27VU"),
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 60),
            online: true,
            isActive: true,
            isAsleep: false
        )
        // 缺少 MSI
        let io = MockRecoveryIO(
            snapshots: [ant],
            plugPower: true,
            hardwareMode: HardwareModeObservation(mode: .uhd, identity: "msi-1", observedAt: 0)
        )
        let runner = ManualActionRunner(io: io, clock: clock)

        let result = await runner.execute(.verifyBothScreens)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.shortMessage, "Verification failed.")
        XCTAssertTrue(result.technicalDetails?.contains("MSI display not detected") == true)
    }

    func testCancelStopsExecutionWithoutCleanup() async {
        let clock = TestRecoveryClock()
        let io = MockRecoveryIO(snapshots: [], plugPower: true)
        let runner = ManualActionRunner(io: io, clock: clock)

        io.onSetPlugPower = { _ in
            Task {
                await runner.cancel()
            }
        }

        let result = await runner.execute(.powerOff)

        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.shortMessage, "Action cancelled.")
    }

    func testLockBusyReturnsBusy() async {
        let clock = TestRecoveryClock()
        let io = MockRecoveryIO(snapshots: [])
        let lock = InMemoryRecoveryTransactionLock()
        XCTAssertTrue(lock.tryLock()) // 模拟被另一个进程/任务持有

        let runner = ManualActionRunner(io: io, transactionLock: lock, clock: clock)
        let result = await runner.execute(.checkStatus)

        XCTAssertEqual(result.outcome, .busy)
        XCTAssertEqual(result.shortMessage, "Another action is running.")
    }
}

// MARK: - Test Helpers

private final class TestRecoveryClock: RecoveryClock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentTime: TimeInterval = 1000

    var now: Date { Date(timeIntervalSince1970: monotonicNow) }
    var monotonicNow: TimeInterval { lock.withLock { currentTime } }

    func advance(seconds: TimeInterval) {
        lock.withLock { currentTime += max(0, seconds) }
    }

    func sleep(seconds: TimeInterval) async throws {
        advance(seconds: seconds)
        try await Task.sleep(nanoseconds: 1_000) // 让出时间片
    }
}

private final class MockRecoveryIO: RecoveryIO, @unchecked Sendable {
    let targetIdentity: String = "mock-io"
    private let lock = NSLock()

    var snapshots: [DisplaySnapshot]
    var plugPower: Bool
    var hardwareMode: HardwareModeObservation

    var plugPowerCalls: [Bool] = []
    var hardwareModeCalls: [MsiHardwareDualMode] = []

    var shouldFailObserveDisplays: Error?
    var shouldFailReadPlugPower: Error?
    var shouldFailSetPlugPower: Error?
    var shouldFailReadHardwareMode: Error?
    var shouldFailSetHardwareMode: Error?

    var onSetPlugPower: (@Sendable (Bool) -> Void)?
    var onSetHardwareMode: (@Sendable (MsiHardwareDualMode) -> Void)?

    init(
        snapshots: [DisplaySnapshot] = [],
        plugPower: Bool = false,
        hardwareMode: HardwareModeObservation = HardwareModeObservation(mode: .uhd, identity: "test-id", observedAt: 0)
    ) {
        self.snapshots = snapshots
        self.plugPower = plugPower
        self.hardwareMode = hardwareMode
    }

    func observeDisplays(deadline: RecoveryDeadline) async throws -> DisplayObservation {
        try deadline.check("observeDisplays")
        if let err = shouldFailObserveDisplays { throw err }
        return lock.withLock {
            DisplayObservation(snapshots: snapshots, observedAt: deadline.clock.monotonicNow)
        }
    }

    func readPlugPower(deadline: RecoveryDeadline) async throws -> Bool {
        try deadline.check("readPlugPower")
        if let err = shouldFailReadPlugPower { throw err }
        return lock.withLock { plugPower }
    }

    func setPlugPower(_ on: Bool, deadline: RecoveryDeadline) async throws {
        try deadline.check("setPlugPower")
        if let err = shouldFailSetPlugPower { throw err }
        lock.withLock {
            plugPowerCalls.append(on)
        }
        onSetPlugPower?(on)
    }

    func readHardwareMode(deadline: RecoveryDeadline) async throws -> HardwareModeObservation {
        try deadline.check("readHardwareMode")
        if let err = shouldFailReadHardwareMode { throw err }
        return lock.withLock { hardwareMode }
    }

    func setHardwareMode(_ mode: MsiHardwareDualMode, expectedIdentity: String, deadline: RecoveryDeadline) async throws {
        try deadline.check("setHardwareMode")
        if let err = shouldFailSetHardwareMode { throw err }
        lock.withLock {
            hardwareModeCalls.append(mode)
        }
        onSetHardwareMode?(mode)
    }
}

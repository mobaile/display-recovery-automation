import XCTest
@testable import DisplayRecoveryCore

final class RecoveryCoordinatorTests: XCTestCase {
    private let oldFingerprint = DisplayFingerprint(vendor: "ANT", model: "ANT27VU", serial: "old")
    private let newFingerprint = DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M", serial: "new")

    func testNormalRecoveryRunsInOrderAndRestoresMode() async throws {
        let io = FakeRecoveryIO(
            snapshots: [DisplaySnapshot(displayID: 10, fingerprint: oldFingerprint, mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 60))],
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 144)
        )
        let coordinator = RecoveryCoordinator(io: io, configuration: configuration())

        await coordinator.triggerManualRecovery()
        let status = await waitForTerminal(coordinator)

        XCTAssertEqual(status.state, .completed)
        XCTAssertNil(status.lastError)
        let calls = await io.calls
        XCTAssertEqual(calls, ["plug:false", "safe", "plug:true", "restore:3840x2160@144.0"])
        let finalMode = await io.mode
        XCTAssertEqual(finalMode, DisplayModeSignature(width: 3840, height: 2160, refreshRate: 144))
    }

    func testRepeatedDisplayEventsDoNotStartTwoRecoveries() async throws {
        let io = FakeRecoveryIO(
            snapshots: [DisplaySnapshot(displayID: 10, fingerprint: oldFingerprint)],
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 144)
        )
        let coordinator = RecoveryCoordinator(io: io, configuration: configuration(automatic: true))

        await coordinator.notifyDisplaysChanged()
        await coordinator.notifyDisplaysChanged()
        let status = await waitForTerminal(coordinator)

        XCTAssertEqual(status.state, .completed)
        let calls = await io.calls
        XCTAssertEqual(calls.filter { $0 == "plug:false" }.count, 1)
    }

    func testAmbiguousPowerDisplayDoesNotStartRecovery() async throws {
        let io = FakeRecoveryIO(
            snapshots: [
                DisplaySnapshot(displayID: 10, fingerprint: oldFingerprint),
                DisplaySnapshot(displayID: 11, fingerprint: oldFingerprint)
            ],
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 144)
        )
        let coordinator = RecoveryCoordinator(io: io, configuration: configuration(automatic: true))

        await coordinator.notifyDisplaysChanged()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let status = await coordinator.status()

        XCTAssertFalse(status.recoveryInProgress)
        XCTAssertEqual(status.state, .idle)
        let calls = await io.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testMissingNewDisplayRollsBackPowerAndFails() async throws {
        let io = FakeRecoveryIO(
            snapshots: [DisplaySnapshot(displayID: 10, fingerprint: oldFingerprint)],
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 144),
            revealNewDisplayAfterPowerOff: false
        )
        let coordinator = RecoveryCoordinator(io: io, configuration: configuration())

        await coordinator.triggerManualRecovery()
        let status = await waitForTerminal(coordinator)

        XCTAssertEqual(status.state, .failed)
        XCTAssertTrue(status.lastError?.contains("新显示器") == true)
        let calls = await io.calls
        XCTAssertEqual(calls.filter { $0 == "plug:true" }.count, 1)
    }

    func testCannotReadOriginalModeFailsBeforePowerCycle() async throws {
        let io = FakeRecoveryIO(
            snapshots: [DisplaySnapshot(displayID: 10, fingerprint: oldFingerprint)],
            mode: nil
        )
        let coordinator = RecoveryCoordinator(io: io, configuration: configuration())

        await coordinator.triggerManualRecovery()
        let status = await waitForTerminal(coordinator)

        XCTAssertEqual(status.state, .failed)
        XCTAssertTrue(status.lastError?.contains("HID") == true)
        let calls = await io.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSafeModeFailureRollsBackPower() async throws {
        let io = FakeRecoveryIO(
            snapshots: [DisplaySnapshot(displayID: 10, fingerprint: oldFingerprint)],
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 144),
            failSafeMode: true
        )
        let coordinator = RecoveryCoordinator(io: io, configuration: configuration())

        await coordinator.triggerManualRecovery()
        let status = await waitForTerminal(coordinator)

        XCTAssertEqual(status.state, .failed)
        XCTAssertTrue(status.lastError?.contains("HID") == true)
        let calls = await io.calls
        XCTAssertEqual(calls, ["plug:false", "safe", "plug:true"])
        let plugPower = await io.plugPower
        XCTAssertTrue(plugPower)
    }

    func testUnsupportedSafeModeTimesOutAndRollsBackPower() async throws {
        let io = FakeRecoveryIO(
            snapshots: [DisplaySnapshot(displayID: 10, fingerprint: oldFingerprint)],
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 144),
            safeModeAvailable: false
        )
        let coordinator = RecoveryCoordinator(io: io, configuration: configuration())

        await coordinator.triggerManualRecovery()
        let status = await waitForTerminal(coordinator)

        XCTAssertEqual(status.state, .failed)
        XCTAssertTrue(status.lastError?.contains("1920×1080") == true)
        let calls = await io.calls
        XCTAssertEqual(calls, ["plug:false", "safe", "plug:true"])
    }

    func testOldDisplayFailureLeavesPlugOnAndReportsFailure() async throws {
        let io = FakeRecoveryIO(
            snapshots: [DisplaySnapshot(displayID: 10, fingerprint: oldFingerprint)],
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 144),
            revealOldDisplayAfterPowerOn: false
        )
        let coordinator = RecoveryCoordinator(io: io, configuration: configuration())

        await coordinator.triggerManualRecovery()
        let status = await waitForTerminal(coordinator)

        XCTAssertEqual(status.state, .failed)
        XCTAssertTrue(status.lastError?.contains("老显示器") == true)
        let calls = await io.calls
        XCTAssertEqual(calls.filter { $0 == "plug:true" }.count, 1)
        let plugPower = await io.plugPower
        XCTAssertTrue(plugPower)
    }

    func testRestoreFailureKeepsSafeModeAndPowerOn() async throws {
        let io = FakeRecoveryIO(
            snapshots: [DisplaySnapshot(displayID: 10, fingerprint: oldFingerprint)],
            mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 144),
            failRestoreMode: true
        )
        let coordinator = RecoveryCoordinator(io: io, configuration: configuration())

        await coordinator.triggerManualRecovery()
        let status = await waitForTerminal(coordinator)

        XCTAssertEqual(status.state, .failed)
        XCTAssertTrue(status.lastError?.contains("模式") == true)
        let finalMode = await io.mode
        XCTAssertEqual(finalMode, DisplayModeSignature(width: 1920, height: 1080, refreshRate: 320))
        let plugPower = await io.plugPower
        XCTAssertTrue(plugPower)
    }

    private func configuration(automatic: Bool = false) -> RecoveryConfiguration {
        RecoveryConfiguration(
            roles: DisplayRoleConfiguration(powerControlled: oldFingerprint, modeSwitch: newFingerprint),
            recoveryCooldown: 0,
            pollInterval: 0.01,
            timeouts: RecoveryTimeouts(powerOff: 0.2, newDisplayOnline: 0.2, safeMode: 0.2, powerOn: 0.2, oldDisplayOnline: 0.2, restoreMode: 0.2),
            automaticRecoveryEnabled: automatic
        )
    }

    private func waitForTerminal(_ coordinator: RecoveryCoordinator) async -> RecoveryStatus {
        for _ in 0..<150 {
            let status = await coordinator.status()
            if !status.recoveryInProgress && (status.state == .completed || status.state == .failed) {
                return status
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await coordinator.status()
    }
}

private actor FakeRecoveryIO: RecoveryIO {
    private(set) var snapshots: [DisplaySnapshot]
    private(set) var plugPower = true
    private(set) var mode: DisplayModeSignature?
    private(set) var calls: [String] = []
    private let revealNewDisplayAfterPowerOff: Bool
    private let revealOldDisplayAfterPowerOn: Bool
    private let failSafeMode: Bool
    private let failRestoreMode: Bool
    private let safeModeAvailable: Bool

    init(
        snapshots: [DisplaySnapshot],
        mode: DisplayModeSignature?,
        revealNewDisplayAfterPowerOff: Bool = true,
        revealOldDisplayAfterPowerOn: Bool = true,
        failSafeMode: Bool = false,
        failRestoreMode: Bool = false,
        safeModeAvailable: Bool = true
    ) {
        self.snapshots = snapshots
        self.mode = mode
        self.revealNewDisplayAfterPowerOff = revealNewDisplayAfterPowerOff
        self.revealOldDisplayAfterPowerOn = revealOldDisplayAfterPowerOn
        self.failSafeMode = failSafeMode
        self.failRestoreMode = failRestoreMode
        self.safeModeAvailable = safeModeAvailable
    }

    func displaySnapshots() async -> [DisplaySnapshot] { snapshots }

    func setPlugPower(_ on: Bool) async throws {
        plugPower = on
        calls.append("plug:\(on)")
        if on, revealOldDisplayAfterPowerOn {
            let old = DisplaySnapshot(displayID: 10, fingerprint: DisplayFingerprint(vendor: "ANT", model: "ANT27VU", serial: "old"), mode: DisplayModeSignature(width: 3840, height: 2160, refreshRate: 60))
            if !snapshots.contains(where: { $0.fingerprint.model == old.fingerprint.model }) {
                snapshots.append(old)
            }
        } else if revealNewDisplayAfterPowerOff {
            let new = DisplaySnapshot(displayID: 20, fingerprint: DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M", serial: "new"), mode: mode)
            snapshots.removeAll { $0.fingerprint.model == "ANT27VU" }
            if !snapshots.contains(where: { $0.fingerprint.model == new.fingerprint.model }) {
                snapshots.append(new)
            }
        }
    }

    func readPlugPower() async throws -> Bool { plugPower }

    func readModeSwitchMode() async throws -> DisplayModeSignature? { mode }

    func setModeSwitchSafeMode() async throws {
        calls.append("safe")
        if failSafeMode {
            throw RecoveryError.monitorUnavailable
        }
        guard safeModeAvailable else { return }
        mode = DisplayModeSignature(width: 1920, height: 1080, refreshRate: 320)
        snapshots = snapshots.map { snapshot in
            var copy = snapshot
            if snapshot.fingerprint.model == "MPG 274U E16M" { copy.mode = mode }
            return copy
        }
    }

    func restoreModeSwitchMode(_ target: DisplayModeSignature) async throws {
        calls.append("restore:\(target.width)x\(target.height)@\(target.refreshRate.rounded())")
        if failRestoreMode {
            throw RecoveryError.modeNotAvailable(target)
        }
        mode = target
        snapshots = snapshots.map { snapshot in
            var copy = snapshot
            if snapshot.fingerprint.model == "MPG 274U E16M" { copy.mode = target }
            return copy
        }
    }
}

import Foundation
import XCTest
@testable import DisplayRecoveryCore

private let antFingerprint = DisplayFingerprint(vendor: "ANT", model: "ANT27VU", serial: "ant")
private let msiFingerprint = DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M", serial: "msi")
private let uhd = DisplayModeSignature(width: 3840, height: 2160, refreshRate: 120)
private let fhd = DisplayModeSignature(width: 1920, height: 1080, refreshRate: 320)
private func ant() -> DisplaySnapshot { DisplaySnapshot(displayID: 10, fingerprint: antFingerprint, mode: uhd) }
private func msi(_ mode: DisplayModeSignature? = uhd) -> DisplaySnapshot { DisplaySnapshot(displayID: 20, fingerprint: msiFingerprint, mode: mode) }
private func configuration(automatic: Bool = true) -> RecoveryConfiguration {
    RecoveryConfiguration(roles: DisplayRoleConfiguration(powerControlled: antFingerprint, modeSwitch: msiFingerprint),
        recoveryCooldown: 0, pollInterval: 0.5,
        timeouts: RecoveryTimeouts(powerOff: 15, newDisplayOnline: 15, safeMode: 20, powerOn: 15, oldDisplayOnline: 30, restoreMode: 30, dualDisplayStabilize: 10, singleDisplayObserve: 5),
        automaticRecoveryEnabled: automatic)
}
private var target: RecoveryTarget { RecoveryTarget(roles: configuration().roles, controlIdentity: "plug-fixture") }

final class RecoveryCoordinatorTests: XCTestCase {
    func testEveryControlActionKeepsMinimumIntervalDespiteImmediateReplies() async throws {
        let h = Harness(snapshots: [ant()])
        await h.io.setRevealANTOnPower(false)
        let outcome = await h.coordinator.triggerManualRecovery()
        XCTAssertEqual(outcome, .success)
        let calls = await h.io.writes
        let times = await h.io.writeTimes
        XCTAssertEqual(calls, ["power:false", "power:true", "mode:FHD", "mode:UHD"])
        XCTAssertEqual(times.count, 4)
        guard times.count == 4 else { return }
        XCTAssertGreaterThanOrEqual(times[1] - times[0], 10)
        XCTAssertGreaterThanOrEqual(times[2] - times[1], 15)
        XCTAssertGreaterThanOrEqual(times[3] - times[2], 15)
        XCTAssertGreaterThanOrEqual(h.clock.monotonicNow - times[3], 15)
    }

    func testAlreadyUHDStillGetsModeObservationWindowBeforeSuccess() async {
        let h = Harness(snapshots: [ant(), msi()])
        let outcome = await h.coordinator.triggerManualRecovery()
        XCTAssertEqual(outcome, .success)
        XCTAssertGreaterThanOrEqual(h.clock.monotonicNow, 15)
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty, "已是 UHD 时不应重复写入模式")
    }

    func testMSIReturnsAtFourteenSecondsWhileANTEnumerationRemains() async {
        let h = Harness(snapshots: [ant()])
        await h.io.setHardwareUnavailable(true)
        await h.io.configurePowerOff(retainANT: true, msiDelay: 14, restoresHID: true)
        let result = await h.coordinator.triggerManualRecovery()
        let calls = await h.io.writes
        let times = await h.io.writeTimes
        XCTAssertEqual(result, .success)
        XCTAssertEqual(calls, ["power:false", "power:true"])
        XCTAssertEqual(times.last.map { $0 - times[0] }, 14)
    }

    func testMSIOnlyReturnsAfterPowerOnAndGetsFullSettlingWindow() async {
        let h = Harness(snapshots: [ant()])
        await h.io.setHardwareUnavailable(true)
        await h.io.configurePowerOff(retainANT: true, msiDelay: nil, restoresHID: true)
        await h.io.setMSIDelayAfterPowerOn(12)
        let result = await h.coordinator.triggerManualRecovery()
        let times = await h.io.writeTimes
        XCTAssertEqual(result, .success)
        XCTAssertEqual(times.count, 2)
        XCTAssertEqual(times.last.map { $0 - times[0] }, 15)
    }

    func testMissingMSIAfterBothWindowsRestoresPowerAndDoesNotClaimSuccess() async throws {
        let h = Harness(snapshots: [ant()])
        await h.io.setHardwareUnavailable(true)
        await h.io.configurePowerOff(retainANT: true, msiDelay: nil)
        let result = await h.coordinator.triggerManualRecovery()
        let calls = await h.io.writes
        let times = await h.io.writeTimes
        let saved = try await h.store.load()
        XCTAssertNotEqual(result, .success)
        XCTAssertEqual(calls, ["power:false", "power:true"])
        XCTAssertEqual(times.last.map { $0 - times[0] }, 15)
        XCTAssertFalse(saved?.powerPendingRestore ?? true)
        XCTAssertTrue(saved?.modePending4K == true)
        XCTAssertFalse(saved?.modeCleanupUsed ?? true)
    }

    func testPendingCleanupWaitsForTemporaryHIDOutage() async throws {
        let tx = RecoveryTransaction(attemptCount: 1, modePending4K: true, target: target, msiHIDIdentity: "msi-usb-fixture")
        let h = Harness(snapshots: [ant(), msi(fhd)], hardware: .fhd, transaction: tx)
        await h.io.setHIDAvailableAt(27)
        let result = await h.coordinator.triggerManualRecovery()
        let calls = await h.io.writes
        let times = await h.io.writeTimes
        XCTAssertEqual(result, .success)
        XCTAssertEqual(calls, ["mode:UHD"])
        XCTAssertEqual(times.first, 27)
    }

    func testUnavailableHIDDoesNotFalselyReportUsedCleanupBudget() async throws {
        let tx = RecoveryTransaction(attemptCount: 1, modePending4K: true, target: target)
        let h = Harness(snapshots: [ant(), msi()], transaction: tx)
        await h.io.setHardwareUnavailable(true)
        let result = await h.coordinator.triggerManualRecovery()
        let saved = try await h.store.load()
        guard case .stopped(let reason) = result else { return XCTFail("应保留未完成责任") }
        XCTAssertTrue(reason.contains("额度未使用"))
        XCTAssertFalse(reason.contains("额度已使用"))
        XCTAssertFalse(saved?.modeCleanupUsed ?? true)
        XCTAssertEqual(h.clock.monotonicNow, 30, "接续观察 15 秒，加 HID 就绪窗口 15 秒")
    }

    func testManualPendingANTRecoveryPreservesTransactionAndTarget() async throws {
        let tx = RecoveryTransaction(attemptCount: 3, isStopped: true, modePending4K: true, target: target,
                                     msiHIDIdentity: "msi-usb-fixture")
        let h = Harness(snapshots: [ant()], transaction: tx)
        await h.io.setHardwareUnavailable(true)
        await h.io.configurePowerOff(retainANT: true, msiDelay: 12, restoresHID: true)
        let result = await h.coordinator.triggerManualRecovery()
        let saved = try await h.store.load()
        let calls = await h.io.writes
        XCTAssertEqual(result, .success)
        XCTAssertEqual(calls, ["power:false", "power:true"])
        XCTAssertEqual(saved?.id, tx.id)
        XCTAssertEqual(saved?.target, tx.target)
        XCTAssertEqual(saved?.msiHIDIdentity, tx.msiHIDIdentity)
        XCTAssertFalse(saved?.hasPendingCleanup ?? true)
        XCTAssertEqual(saved?.attemptCount, 0)
    }

    func testAutomaticPendingANTDoesNotRestartPowerCycle() async {
        let tx = RecoveryTransaction(attemptCount: 1, modePending4K: true, target: target)
        let h = Harness(snapshots: [ant()], transaction: tx)
        await h.io.setHardwareUnavailable(true)
        _ = await h.coordinator.evaluateAndRecover()
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }

    func testLostModeAcknowledgementStillKeepsIntervalBeforeCleanup() async throws {
        let h = Harness()
        await h.io.setFailAfterFHDWrite(true)
        let result = await h.coordinator.triggerManualRecovery()
        let calls = await h.io.writes
        let times = await h.io.writeTimes
        XCTAssertNotEqual(result, .success)
        XCTAssertEqual(calls, ["mode:FHD", "mode:UHD"])
        XCTAssertGreaterThanOrEqual(times.last.map { $0 - times[0] } ?? 0, 15)
    }

    func testModeReenumerationDelayDoesNotConsumeMinimumHoldTime() async {
        let h = Harness()
        await h.io.setModeHIDOutage(12)
        let result = await h.coordinator.triggerManualRecovery()
        let times = await h.io.writeTimes
        XCTAssertEqual(result, .success)
        XCTAssertGreaterThanOrEqual(times.last.map { $0 - times[0] } ?? 0, 27)
        XCTAssertGreaterThanOrEqual(h.clock.monotonicNow - (times.last ?? 0), 27)
    }

    func testCancellationAfterPowerOffKeepsTenSecondsBeforeRestore() async throws {
        let h = Harness(snapshots: [ant()])
        await h.io.setCancelAfterPowerOff(true)
        let result = await h.coordinator.triggerManualRecovery()
        let calls = await h.io.writes
        let times = await h.io.writeTimes
        guard case .cancelled = result else { return XCTFail("必须报告取消") }
        XCTAssertEqual(calls, ["power:false", "power:true"])
        XCTAssertGreaterThanOrEqual(times.last.map { $0 - times[0] } ?? 0, 10)
        let saved = try await h.store.load()
        XCTAssertFalse(saved?.hasPendingCleanup ?? true)
    }
    func testFailedCompletionCommitCannotEraseThirdAttempt() async throws {
        let h = Harness(transaction: RecoveryTransaction(attemptCount: 2))
        await h.store.setFailStage(.completed)
        await h.poll(12)
        let tx = try await h.store.load()
        XCTAssertEqual(tx?.attemptCount, 3)
        XCTAssertTrue(tx?.isStopped == true)
        XCTAssertEqual(tx?.stage, .stopped)
    }

    func testConcurrentStartupReadersShareInitializationWithoutOverwritingRecovery() async throws {
        let h = Harness(transaction: RecoveryTransaction(attemptCount: 3, isStopped: true))
        let gate = TestGate()
        await h.store.setLoadGate(gate)
        let status = Task { await h.coordinator.status() }
        while !(await gate.entered) { await Task.yield() }
        let recovery = Task { await h.coordinator.triggerManualRecovery() }
        let secondStatus = Task { await h.coordinator.status() }
        await gate.release()
        _ = await status.value
        _ = await secondStatus.value
        let result = await recovery.value
        XCTAssertEqual(result, .success)
        let loads = await h.store.loadCount
        XCTAssertEqual(loads, 2, "一次初始化，取得全局锁后再读取一次")
        let tx = try await h.store.load()
        XCTAssertFalse(tx?.isStopped ?? true)
        XCTAssertEqual(tx?.stage, .completed)
    }
    func testMSIOnlyReturnsTo4KAndPersistsRealStages() async throws {
        let h = Harness()
        let outcome = await h.coordinator.triggerManualRecovery()
        XCTAssertEqual(outcome, .success)
        let calls = await h.io.writes
        XCTAssertEqual(calls, ["mode:FHD", "mode:UHD"])
        let tx = try await h.store.load()
        XCTAssertEqual(tx?.stage, .completed)
        XCTAssertFalse(tx?.hasPendingCleanup ?? true)
        let history = await h.store.savedStages
        XCTAssertTrue(history.contains(.msiSwitch1080P))
        XCTAssertTrue(history.contains(.stabilizing4K))
        XCTAssertEqual(tx?.msiHIDIdentity, "msi-usb-fixture")
    }
    func testANTReturningOnlyAfterUHDStillGetsFullStableVerification() async throws {
        let h = Harness()
        await h.io.setRevealANTOnFHD(false)
        await h.io.setRevealANTOnUHD(true)
        let result = await h.coordinator.triggerManualRecovery()
        XCTAssertEqual(result, .success)
        let calls = await h.io.writes
        let tx = try await h.store.load()
        let stages = await h.store.savedStages
        XCTAssertEqual(calls, ["mode:FHD", "mode:UHD"])
        XCTAssertTrue(stages.contains(.stabilizing4K))
        XCTAssertGreaterThanOrEqual(h.clock.monotonicNow, 12, "等待超时后仍须完整验证 10 秒")
        XCTAssertEqual(tx?.stage, .completed)
        XCTAssertFalse(tx?.hasPendingCleanup ?? true)
    }
    func testANTStillAbsentAfterUHDRemainsFailureWithoutRepeatedModeWrites() async throws {
        let h = Harness()
        await h.io.setRevealANTOnFHD(false)
        let result = await h.coordinator.triggerManualRecovery()
        XCTAssertNotEqual(result, .success)
        let calls = await h.io.writes
        let tx = try await h.store.load()
        XCTAssertEqual(calls, ["mode:FHD", "mode:UHD"])
        XCTAssertEqual(tx?.attemptCount, 1)
        XCTAssertEqual(tx?.stage, .failed)
        XCTAssertFalse(tx?.modePending4K ?? true)
    }
    func testANTNaturalReturnAtFHDStillRestores4K() async {
        let h = Harness(snapshots: [ant()], hardware: .fhd)
        let outcome = await h.coordinator.triggerManualRecovery()
        XCTAssertEqual(outcome, .success)
        let calls = await h.io.writes
        XCTAssertEqual(calls, ["power:false", "power:true", "mode:UHD"])
    }
    func testANTNaturalReturnAtUHDDoesNotSendFHD() async {
        let h = Harness(snapshots: [ant()])
        let outcome = await h.coordinator.triggerManualRecovery()
        XCTAssertEqual(outcome, .success)
        let calls = await h.io.writes
        XCTAssertEqual(calls, ["power:false", "power:true"])
    }
    func testANTFallbackRemainsOneAttempt() async throws {
        let h = Harness(snapshots: [ant()])
        await h.io.setRevealANTOnPower(false)
        let outcome = await h.coordinator.triggerManualRecovery()
        XCTAssertEqual(outcome, .success)
        let calls = await h.io.writes
        XCTAssertEqual(calls, ["power:false", "power:true", "mode:FHD", "mode:UHD"])
        let attempts = await h.store.attempts
        XCTAssertEqual(attempts.max(), 1)
    }
    func testHardwareFHDWithSystem4KMustNotSkipUHD() async {
        let h = Harness(snapshots: [ant(), msi()], hardware: .fhd)
        let outcome = await h.coordinator.triggerManualRecovery()
        XCTAssertEqual(outcome, .success)
        let hardware = await h.io.hardware
        let calls = await h.io.writes
        XCTAssertEqual(hardware, .uhd)
        XCTAssertEqual(calls, ["mode:UHD"])
    }
    func testMissingSystemModeCannotPass4KVerification() async throws {
        let h = Harness(snapshots: [ant(), msi(nil)])
        let outcome = await h.coordinator.triggerManualRecovery()
        XCTAssertNotEqual(outcome, .success)
        let tx = try await h.store.load()
        XCTAssertTrue(tx?.modePending4K == true)
        XCTAssertTrue(tx?.isStopped == true)
    }
    func testStaleObservationCannotStartRecovery() async {
        let h = Harness()
        await h.io.setObservationAge(20)
        let result = await h.coordinator.triggerManualRecovery()
        if case .skipped = result {} else { XCTFail("过期观测必须阻止介入") }
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
    func testANTLossDuring4KStabilityIsFailure() async {
        let h = Harness()
        await h.io.setDropANTOnUHD(true)
        let outcome = await h.coordinator.triggerManualRecovery()
        XCTAssertNotEqual(outcome, .success)
        let hardware = await h.io.hardware
        XCTAssertEqual(hardware, .uhd)
    }
    func testHealthyManualFHDRemainsUntouched() async {
        let h = Harness(snapshots: [ant(), msi(fhd)], hardware: .fhd)
        await h.poll(25)
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
    func testManualANTPowerOffRemainsUntouched() async {
        let h = Harness(snapshots: [msi(fhd)], hardware: .fhd, power: false)
        await h.poll(25)
        let calls = await h.io.writes
        let tx = try? await h.store.load()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(tx?.attemptCount ?? 0, 0)
    }
    func testUnknownPowerIsNotTreatedAsOn() async {
        let h = Harness()
        await h.io.setPowerReadFailure(true)
        await h.poll(25)
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
    func testSingleDisplayChangingSidesRestartsStabilityWindow() async {
        let h = Harness(snapshots: [ant()])
        await h.poll(8)
        await h.io.replace([msi()])
        _ = await h.coordinator.evaluateAndRecover()
        var calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
        await h.poll(8, startup: false)
        calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty, "换边后的 4 秒不能介入")
        await h.poll(4, startup: false)
        calls = await h.io.writes
        XCTAssertTrue(calls.contains("mode:FHD"))
    }
    func testAmbiguityFailsBeforeAnyCleanupWrite() async {
        var duplicate = msi(fhd); duplicate.displayID = 21
        let h = Harness(snapshots: [ant(), msi(fhd), duplicate], hardware: .fhd)
        _ = await h.coordinator.triggerManualRecovery()
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
    func testUnknownEnumerationDoesNotMeanANTAbsent() async {
        let h = Harness(snapshots: [ant()])
        await h.io.setEnumerationFailure(true)
        _ = await h.coordinator.triggerManualRecovery()
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
    func testSleepingDisplayDoesNotTriggerPowerCycle() async {
        var sleeping = ant(); sleeping.isAsleep = true
        let h = Harness(snapshots: [sleeping])
        await h.poll(25)
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
    func testPendingPowerOnlyResumesWithoutRepeatingPowerOffOrFHD() async throws {
        let tx = RecoveryTransaction(attemptCount: 1, powerPendingRestore: true, target: target)
        let h = Harness(snapshots: [msi(fhd)], hardware: .fhd, power: false, transaction: tx, automatic: false)
        let outcome = await h.coordinator.evaluateAndRecover()
        XCTAssertEqual(outcome, .success)
        let calls = await h.io.writes
        XCTAssertEqual(calls, ["power:true", "mode:UHD"])
        let saved = try await h.store.load()
        XCTAssertFalse(saved?.hasPendingCleanup ?? true)
    }
    func testRestartWithPending4KOnlyPerformsUHD() async {
        let tx = RecoveryTransaction(attemptCount: 1, modePending4K: true, target: target, msiHIDIdentity: "msi-usb-fixture")
        let h = Harness(snapshots: [ant(), msi(fhd)], hardware: .fhd, transaction: tx)
        let result = await h.coordinator.evaluateAndRecover()
        XCTAssertEqual(result, .success)
        let calls = await h.io.writes
        XCTAssertEqual(calls, ["mode:UHD"])
    }
    func testUsedCleanupBudgetDoesNotRenewAcrossRestart() async throws {
        let tx = RecoveryTransaction(attemptCount: 3, isStopped: true, modePending4K: true, target: target,
            msiHIDIdentity: "msi-usb-fixture", modeCleanupUsed: true)
        let h = Harness(snapshots: [ant(), msi(fhd)], hardware: .fhd, transaction: tx)
        _ = await h.coordinator.evaluateAndRecover()
        let restarted = h.newCoordinator()
        _ = await restarted.evaluateAndRecover()
        let calls = await h.io.writes
        let saved = try await h.store.load()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(saved?.modeCleanupUsed == true)
        XCTAssertEqual(saved?.attemptCount, 3)
    }
    func testChangedTargetBlocksOldCleanup() async {
        let oldTarget = RecoveryTarget(roles: configuration().roles, controlIdentity: "different-plug")
        let tx = RecoveryTransaction(attemptCount: 1, powerPendingRestore: true, target: oldTarget)
        let h = Harness(transaction: tx)
        let result = await h.coordinator.triggerManualRecovery()
        if case .stopped = result {} else { XCTFail("目标变化必须停止") }
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
    func testLegacyPendingTransactionWithoutBindingIsNotGuessed() async {
        let h = Harness(transaction: RecoveryTransaction(attemptCount: 1, powerPendingRestore: true))
        _ = await h.coordinator.evaluateAndRecover()
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
    func testJournalWriteFailurePreventsAllHardwareWrites() async {
        let h = Harness()
        await h.store.setFailAllSaves(true)
        let result = await h.coordinator.triggerManualRecovery()
        XCTAssertNotEqual(result, .success)
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
    func testJournalReadFailureDoesNotCreateEmptyTransaction() async {
        let h = Harness()
        await h.store.setFailLoad(true)
        _ = await h.coordinator.triggerManualRecovery()
        let calls = await h.io.writes
        let saves = await h.store.savedStages
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(saves.isEmpty)
    }
    func testPersistenceFailureAfterFHDStillRunsIndependentUHDGuard() async throws {
        let h = Harness()
        await h.store.setFailStage(.waitingDualOnline)
        let result = await h.coordinator.triggerManualRecovery()
        XCTAssertNotEqual(result, .success)
        let calls = await h.io.writes
        XCTAssertEqual(calls, ["mode:FHD", "mode:UHD"])
        let saved = try await h.store.load()
        XCTAssertFalse(saved?.modePending4K ?? true)
    }
    func testThirdFailureStopsAndRestartKeepsCount() async throws {
        let h = Harness(transaction: RecoveryTransaction(attemptCount: 2))
        await h.io.setRevealANTOnFHD(false)
        await h.poll(12)
        var tx = try await h.store.load()
        XCTAssertEqual(tx?.attemptCount, 3)
        XCTAssertTrue(tx?.isStopped == true)
        await h.io.clearWrites()
        let restarted = h.newCoordinator()
        h.clock.advance(20)
        _ = await restarted.evaluateAndRecover()
        tx = try await h.store.load()
        let calls = await h.io.writes
        XCTAssertEqual(tx?.attemptCount, 3)
        XCTAssertTrue(calls.isEmpty)
    }
    func testOneHealthySnapshotDoesNotClearFailures() async throws {
        let h = Harness(snapshots: [ant(), msi()], transaction: RecoveryTransaction(attemptCount: 2))
        await h.poll(1)
        let tx = try await h.store.load()
        XCTAssertEqual(tx?.attemptCount, 2)
    }
    func testStableHealthy4KClearsStoppedLatch() async throws {
        let h = Harness(snapshots: [ant(), msi()], transaction: RecoveryTransaction(attemptCount: 3, isStopped: true))
        await h.poll(25)
        let tx = try await h.store.load()
        XCTAssertFalse(tx?.isStopped ?? true)
        XCTAssertEqual(tx?.attemptCount, 0)
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
    func testCallerCancellationBeforeWriteDoesNotStartRecovery() async {
        let h = Harness()
        let gate = TestGate(); await h.io.setGate(gate)
        let task = Task { await h.coordinator.triggerManualRecovery() }
        while !(await gate.entered) { await Task.yield() }
        task.cancel(); await gate.release()
        let outcome = await task.value
        if case .cancelled = outcome {} else { XCTFail("必须报告取消") }
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
    func testCancellationAfterFHDStillRestoresUHD() async throws {
        let h = Harness()
        await h.io.setCancelAfterFHD(true)
        let outcome = await h.coordinator.triggerManualRecovery()
        if case .cancelled = outcome {} else { XCTFail("必须报告取消") }
        let calls = await h.io.writes
        let tx = try await h.store.load()
        XCTAssertEqual(calls, ["mode:FHD", "mode:UHD"])
        let times = await h.io.writeTimes
        XCTAssertGreaterThanOrEqual(times.last.map { $0 - times[0] } ?? 0, 15)
        XCTAssertFalse(tx?.hasPendingCleanup ?? true)
    }
    func testPowerCleanupFailureDoesNotSuppressUHD() async throws {
        let h = Harness(snapshots: [ant()], hardware: .fhd)
        await h.io.setFailPowerOn(true)
        let outcome = await h.coordinator.triggerManualRecovery()
        XCTAssertNotEqual(outcome, .success)
        let calls = await h.io.writes
        let tx = try await h.store.load()
        XCTAssertTrue(calls.contains("mode:UHD"))
        XCTAssertTrue(tx?.powerPendingRestore == true)
        XCTAssertFalse(tx?.modePending4K ?? true)
        XCTAssertFalse(tx?.cleanupErrors.isEmpty ?? true)
    }
    func testExpiredIOCannotSatisfyPrecondition() async {
        let h = Harness()
        await h.io.setPowerReadDelay(20)
        _ = await h.coordinator.triggerManualRecovery()
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
    func testUnavailableHIDDoesNotConsumeAttemptOrChangeResolution() async throws {
        let h = Harness()
        await h.io.setHardwareUnavailable(true)
        _ = await h.coordinator.triggerManualRecovery()
        let calls = await h.io.writes
        let tx = try await h.store.load()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(tx?.attemptCount ?? 0, 0)
    }
    func testAutomaticRecoveryHonorsSharedTransactionLock() async {
        let h = Harness()
        XCTAssertTrue(h.transactionLock.tryLock())
        let automatic = await h.coordinator.evaluateAndRecover()
        let manual = await h.coordinator.triggerManualRecovery()
        XCTAssertEqual(automatic, .busy)
        XCTAssertEqual(manual, .busy)
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
        h.transactionLock.unlock()
    }
    func testTwoCoordinatorsCannotOverlapAndBusyCannotClearStop() async {
        let h = Harness(transaction: RecoveryTransaction(attemptCount: 2))
        let gate = TestGate(); await h.io.setGate(gate)
        let running = Task { await h.coordinator.triggerManualRecovery() }
        while !(await gate.entered) { await Task.yield() }
        let other = h.newCoordinator()
        let outcome = await other.triggerManualRecovery()
        let cleared = await h.coordinator.clearStop()
        let retired = await h.coordinator.retireForConfigurationChange()
        XCTAssertEqual(outcome, .busy)
        XCTAssertFalse(cleared)
        XCTAssertFalse(retired)
        await gate.release()
        _ = await running.value
    }
    func testDryRunDoesNotWriteHardwareOrResetAttemptCount() async throws {
        let h = Harness(transaction: RecoveryTransaction(attemptCount: 2))
        _ = await h.coordinator.previewRecovery()
        let calls = await h.io.writes
        let stages = await h.store.savedStages
        let tx = try await h.store.load()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(stages.isEmpty)
        XCTAssertEqual(tx?.attemptCount, 2)
    }
    func testWallClockChangesDoNotAdvanceSingleDisplayTimer() async {
        let h = Harness()
        await h.poll(2)
        h.clock.jumpWallClock(86400)
        _ = await h.coordinator.evaluateAndRecover()
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
    func testWakeStartsNewGracePeriod() async {
        let h = Harness()
        await h.poll(6)
        await h.coordinator.notifySystemWokeUp()
        await h.poll(16, startup: false)
        let calls = await h.io.writes
        XCTAssertTrue(calls.isEmpty)
    }
}

private final class TestClock: RecoveryClock, @unchecked Sendable {
    private let lock = NSLock()
    private var uptime: TimeInterval = 0
    private var wall: TimeInterval = 1_000_000
    var now: Date { lock.withLock { Date(timeIntervalSince1970: wall) } }
    var monotonicNow: TimeInterval { lock.withLock { uptime } }
    func advance(_ seconds: TimeInterval) { lock.withLock { uptime += seconds; wall += seconds } }
    func jumpWallClock(_ seconds: TimeInterval) { lock.withLock { wall += seconds } }
    func sleep(seconds: TimeInterval) async throws { try Task.checkCancellation(); advance(seconds); await Task.yield() }
}
private actor TestGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private actor TestStore: RecoveryTransactionStoreProtocol {
    private var loadGate: TestGate?
    private(set) var loadCount = 0
    func setLoadGate(_ gate: TestGate) { loadGate = gate }
    private var transaction: RecoveryTransaction?
    private var failLoad = false
    private var failAllSaves = false
    private var failStage: RecoveryStage?
    private(set) var savedStages: [RecoveryStage] = []
    private(set) var attempts: [Int] = []
    init(_ transaction: RecoveryTransaction?) { self.transaction = transaction }
    func setFailLoad(_ value: Bool) { failLoad = value }
    func setFailAllSaves(_ value: Bool) { failAllSaves = value }
    func setFailStage(_ stage: RecoveryStage) { failStage = stage }
    func load() async throws -> RecoveryTransaction? {
        loadCount += 1
        if let loadGate { await loadGate.wait() }
        if failLoad { throw RecoveryError.operationFailed("模拟事务文件损坏") }
        return transaction
    }
    func save(_ transaction: RecoveryTransaction) async throws {
        if failAllSaves || transaction.stage == failStage { throw RecoveryError.operationFailed("模拟落盘失败") }
        self.transaction = transaction
        savedStages.append(transaction.stage); attempts.append(transaction.attemptCount)
    }
    func clear() async throws { transaction = nil }
}
private actor TestIO: RecoveryIO {
    nonisolated let targetIdentity = "plug-fixture"
    let clock: TestClock
    private var snapshots: [DisplaySnapshot]
    private(set) var hardware: MsiHardwareDualMode
    private var power: Bool
    private(set) var writes: [String] = []
    private(set) var writeTimes: [TimeInterval] = []
    private var revealANTOnPower = true
    private var revealANTOnFHD = true
    private var revealANTOnUHD = false
    private var dropANTOnUHD = false
    private var failPowerOn = false
    private var powerReadFailure = false
    private var enumerationFailure = false
    private var hardwareUnavailable = false
    private var cancelAfterFHD = false
    private var observationAge: TimeInterval = 0
    private var powerReadDelay: TimeInterval = 0
    private var gate: TestGate?
    private var retainANTWhenOff = false
    private var msiDelayAfterPowerOff: TimeInterval? = 0
    private var msiDelayAfterPowerOn: TimeInterval?
    private var pendingMSIAt: TimeInterval?
    private var restoresHIDWithMSI = false
    private var hidAvailableAt: TimeInterval?
    private var modeHIDOutage: TimeInterval = 0
    private var failAfterFHDWrite = false
    private var cancelAfterPowerOff = false
    init(clock: TestClock, snapshots: [DisplaySnapshot], hardware: MsiHardwareDualMode, power: Bool) {
        self.clock = clock; self.snapshots = snapshots; self.hardware = hardware; self.power = power
    }
    func clearWrites() { writes = []; writeTimes = [] }
    func configurePowerOff(retainANT: Bool, msiDelay: TimeInterval?, restoresHID: Bool = false) {
        retainANTWhenOff = retainANT; msiDelayAfterPowerOff = msiDelay; restoresHIDWithMSI = restoresHID
    }
    func setMSIDelayAfterPowerOn(_ seconds: TimeInterval) { msiDelayAfterPowerOn = seconds }
    func setHIDAvailableAt(_ at: TimeInterval) { hardwareUnavailable = true; hidAvailableAt = at }
    func setModeHIDOutage(_ seconds: TimeInterval) { modeHIDOutage = seconds }
    func setFailAfterFHDWrite(_ value: Bool) { failAfterFHDWrite = value }
    func setCancelAfterPowerOff(_ value: Bool) { cancelAfterPowerOff = value }
    private func applyEvents() {
        if let at = pendingMSIAt, clock.monotonicNow >= at {
            snapshots.removeAll { $0.displayID == 20 }
            snapshots.append(msi(hardware == .fhd ? fhd : uhd))
            if restoresHIDWithMSI { hardwareUnavailable = false }
            pendingMSIAt = nil
        }
        if let at = hidAvailableAt, clock.monotonicNow >= at {
            hardwareUnavailable = false; hidAvailableAt = nil
        }
    }
    func replace(_ snapshots: [DisplaySnapshot]) { self.snapshots = snapshots }
    func setRevealANTOnPower(_ value: Bool) { revealANTOnPower = value }
    func setRevealANTOnFHD(_ value: Bool) { revealANTOnFHD = value }
    func setRevealANTOnUHD(_ value: Bool) { revealANTOnUHD = value }
    func setDropANTOnUHD(_ value: Bool) { dropANTOnUHD = value }
    func setFailPowerOn(_ value: Bool) { failPowerOn = value }
    func setPowerReadFailure(_ value: Bool) { powerReadFailure = value }
    func setEnumerationFailure(_ value: Bool) { enumerationFailure = value }
    func setHardwareUnavailable(_ value: Bool) { hardwareUnavailable = value }
    func setCancelAfterFHD(_ value: Bool) { cancelAfterFHD = value }
    func setObservationAge(_ value: TimeInterval) { observationAge = value }
    func setPowerReadDelay(_ value: TimeInterval) { powerReadDelay = value }
    func setGate(_ gate: TestGate) { self.gate = gate }
    func observeDisplays(deadline: RecoveryDeadline) async throws -> DisplayObservation {
        applyEvents()
        if enumerationFailure { throw RecoveryError.operationFailed("模拟枚举不可用") }
        return DisplayObservation(snapshots: snapshots, observedAt: clock.monotonicNow - observationAge)
    }
    func readPlugPower(deadline: RecoveryDeadline) async throws -> Bool {
        if let gate { await gate.wait() }
        if powerReadFailure { throw RecoveryError.plugUnavailable("模拟网络不可用") }
        clock.advance(powerReadDelay)
        return power
    }
    func setPlugPower(_ on: Bool, deadline: RecoveryDeadline) async throws {
        try deadline.check()
        writes.append("power:\(on)")
        writeTimes.append(clock.monotonicNow)
        if on && failPowerOn { throw RecoveryError.plugUnavailable("模拟供电恢复失败") }
        power = on
        if !on {
            snapshots = retainANTWhenOff ? [ant()] : []
            pendingMSIAt = msiDelayAfterPowerOff.map { clock.monotonicNow + $0 }
            if cancelAfterPowerOff { deadline.cancellation.cancel("模拟断电后取消") }
        } else {
            if revealANTOnPower && !snapshots.contains(where: { $0.displayID == 10 }) { snapshots.append(ant()) }
            if let delay = msiDelayAfterPowerOn { pendingMSIAt = clock.monotonicNow + delay }
        }
        applyEvents()
    }
    func readHardwareMode(deadline: RecoveryDeadline) async throws -> HardwareModeObservation {
        applyEvents()
        if hardwareUnavailable { throw RecoveryError.monitorUnavailable }
        return HardwareModeObservation(mode: hardware, identity: "msi-usb-fixture", observedAt: clock.monotonicNow)
    }
    func setHardwareMode(_ mode: MsiHardwareDualMode, expectedIdentity: String, deadline: RecoveryDeadline) async throws {
        try deadline.check()
        guard expectedIdentity == "msi-usb-fixture" else { throw RecoveryError.monitorUnavailable }
        writes.append("mode:\(mode.rawValue)")
        writeTimes.append(clock.monotonicNow)
        hardware = mode
        if modeHIDOutage > 0 { setHIDAvailableAt(clock.monotonicNow + modeHIDOutage) }
        snapshots = snapshots.map { snapshot in
            var result = snapshot
            if result.displayID == 20 { result.mode = mode == .uhd ? uhd : fhd }
            return result
        }
        if mode == .fhd && revealANTOnFHD && !snapshots.contains(where: { $0.displayID == 10 }) { snapshots.append(ant()) }
        if mode == .uhd && revealANTOnUHD && !snapshots.contains(where: { $0.displayID == 10 }) { snapshots.append(ant()) }
        if mode == .uhd && dropANTOnUHD { snapshots.removeAll { $0.displayID == 10 } }
        if mode == .fhd && cancelAfterFHD { deadline.cancellation.cancel("模拟切到 FHD 后取消") }
        if mode == .fhd && failAfterFHDWrite { throw RecoveryError.operationTimedOut("模拟已切模但应答丢失") }
    }
}
private struct Harness: Sendable {
    let clock: TestClock
    let io: TestIO
    let store: TestStore
    let transactionLock: InMemoryRecoveryTransactionLock
    let coordinator: RecoveryCoordinator
    let config: RecoveryConfiguration
    init(snapshots: [DisplaySnapshot] = [msi()], hardware: MsiHardwareDualMode = .uhd, power: Bool = true,
         transaction: RecoveryTransaction? = nil, automatic: Bool = true) {
        clock = TestClock(); io = TestIO(clock: clock, snapshots: snapshots, hardware: hardware, power: power)
        store = TestStore(transaction); transactionLock = InMemoryRecoveryTransactionLock(); config = configuration(automatic: automatic)
        coordinator = RecoveryCoordinator(io: io, configuration: config, clock: clock, transactionStore: store, transactionLock: transactionLock)
    }
    func newCoordinator() -> RecoveryCoordinator {
        RecoveryCoordinator(io: io, configuration: config, clock: clock, transactionStore: store, transactionLock: transactionLock)
    }
    func poll(_ count: Int, startup: Bool = true) async {
        if startup { clock.advance(11) }
        for _ in 0..<count {
            _ = await coordinator.evaluateAndRecover()
            clock.advance(0.5)
        }
    }
}

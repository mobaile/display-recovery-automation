import XCTest
@testable import DisplayRecoveryCore

final class ModelsTests: XCTestCase {
    func testModeSignatureFormattingAndTolerance() {
        let mode = DisplayModeSignature(width: 3840, height: 2160, refreshRate: 144)
        XCTAssertEqual(mode.shortDescription, "3840×2160 @ 144Hz")
        XCTAssertTrue(mode.approximatelyEquals(DisplayModeSignature(width: 3840, height: 2160, refreshRate: 144.5)))
        XCTAssertFalse(mode.approximatelyEquals(DisplayModeSignature(width: 3840, height: 2160, refreshRate: 146)))
        let unknownRefresh = DisplayModeSignature(width: 3840, height: 2160, refreshRate: 0)
        XCTAssertEqual(unknownRefresh.shortDescription, "3840×2160 @ Unknown")
        XCTAssertTrue(unknownRefresh.approximatelyEquals(mode))
        XCTAssertFalse(unknownRefresh.approximatelyEquals(DisplayModeSignature(width: 2560, height: 1440, refreshRate: 144)))
    }

    func testFingerprintMatchingUsesEmptyComponentsAsWildcards() {
        let configured = DisplayFingerprint(vendor: " MSI ", model: "MPG 274U E16M")
        let actual = DisplayFingerprint(vendor: "msi", model: "MPG 274U E16M", serial: "A1")
        XCTAssertTrue(configured.matches(actual))
        XCTAssertFalse(configured.matches(DisplayFingerprint(vendor: "ANT", model: "ANT27VU")))
        XCTAssertFalse(DisplayFingerprint(serial: "A1").matches(DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M")))
    }

    func testMSIMatchingDoesNotIgnoreConfiguredSerial() {
        let roles = DisplayRoleConfiguration(modeSwitch: DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M", serial: "expected"))
        let wrong = DisplaySnapshot(displayID: 2, fingerprint: DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M", serial: "different"))
        XCTAssertEqual(DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: roles, snapshots: [wrong]), .notFound)
    }

    func testRoleResolverExcludesBuiltinAndRejectsAmbiguity() {
        let roles = DisplayRoleConfiguration()
        let builtin = DisplaySnapshot(displayID: 1, fingerprint: roles.modeSwitch, isBuiltin: true)
        XCTAssertEqual(DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: roles, snapshots: [builtin]), .notFound)
        let a = DisplaySnapshot(displayID: 2, fingerprint: roles.modeSwitch)
        let b = DisplaySnapshot(displayID: 3, fingerprint: roles.modeSwitch)
        XCTAssertEqual(DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: roles, snapshots: [a, b]), .ambiguous([a, b]))
        let missing = DisplayRoleConfiguration(modeSwitch: DisplayFingerprint())
        XCTAssertEqual(DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: missing, snapshots: [a]), .unconfigured)
    }

    func testOnlyExplicitFullFingerprintAliasIsAccepted() {
        let alias = DisplayFingerprint(vendor: "MSI", model: "MPG 274U FHD", serial: "same-device")
        let roles = DisplayRoleConfiguration(modeSwitch: DisplayFingerprint(vendor: "MSI", model: "MPG 274U UHD", serial: "same-device"), modeSwitchAliases: [alias])
        let snapshot = DisplaySnapshot(displayID: 2, fingerprint: alias)
        XCTAssertEqual(DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: roles, snapshots: [snapshot]), .matched(snapshot))
    }

}

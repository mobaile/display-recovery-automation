import XCTest
@testable import DisplayRecoveryCore

final class ModelsTests: XCTestCase {
    func testModeSignatureFormattingAndTolerance() {
        let mode = DisplayModeSignature(width: 3840, height: 2160, refreshRate: 144)
        XCTAssertEqual(mode.shortDescription, "3840×2160 @ 144Hz")
        XCTAssertTrue(mode.approximatelyEquals(DisplayModeSignature(width: 3840, height: 2160, refreshRate: 144.5)))
        XCTAssertFalse(mode.approximatelyEquals(DisplayModeSignature(width: 3840, height: 2160, refreshRate: 146)))
        let unknownRefresh = DisplayModeSignature(width: 3840, height: 2160, refreshRate: 0)
        XCTAssertEqual(unknownRefresh.shortDescription, "3840×2160 @ 未知")
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

}

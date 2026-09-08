import AppKit
import CommonCrypto
import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics

import DisplayRecoveryCore

public final class MacDisplayProvider: @unchecked Sendable {
    private final class CallbackBox {
        let handler: @Sendable () -> Void

        init(handler: @escaping @Sendable () -> Void) {
            self.handler = handler
        }
    }

    private var callbackBox: CallbackBox?
    private let callback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo else { return }
        if flags.contains(.beginConfigurationFlag) {
            return
        }
        let box = Unmanaged<CallbackBox>.fromOpaque(userInfo).takeUnretainedValue()
        box.handler()
    }

    public init() {}

    deinit {
        stopObserving()
    }

    public func startObserving(_ handler: @escaping @Sendable () -> Void) {
        stopObserving()
        let box = CallbackBox(handler: handler)
        callbackBox = box
        _ = CGDisplayRegisterReconfigurationCallback(callback, Unmanaged.passUnretained(box).toOpaque())
    }

    public func stopObserving() {
        guard let callbackBox else { return }
        _ = CGDisplayRemoveReconfigurationCallback(callback, Unmanaged.passUnretained(callbackBox).toOpaque())
        self.callbackBox = nil
    }

    @MainActor public func snapshots() -> [DisplaySnapshot] {
        (try? checkedSnapshots()) ?? []
    }

    @MainActor public func checkedSnapshots() throws -> [DisplaySnapshot] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else {
            throw RecoveryError.operationFailed("CoreGraphics cannot read display count.")
        }
        if count == 0 { return [] }

        var displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        guard CGGetOnlineDisplayList(count, &displayIDs, &count) == .success else {
            throw RecoveryError.operationFailed("CoreGraphics display enumeration failed.")
        }

        return displayIDs.prefix(Int(count)).map(makeSnapshot(displayID:))
    }

    @MainActor public func snapshot(for displayID: CGDirectDisplayID) -> DisplaySnapshot {
        makeSnapshot(displayID: displayID)
    }

    @MainActor private func makeSnapshot(displayID: CGDirectDisplayID) -> DisplaySnapshot {
        let mode = CGDisplayCopyDisplayMode(displayID).map { mode in
            DisplayModeSignature(
                width: mode.pixelWidth,
                height: mode.pixelHeight,
                refreshRate: mode.refreshRate
            )
        }

        let info = displayInfo(displayID: displayID)
        let vendorNumber = CGDisplayVendorNumber(displayID)
        let productNumber = CGDisplayModelNumber(displayID)
        let serialNumber = CGDisplaySerialNumber(displayID)

        let appKitName = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }?.localizedName
        let productName = info.productName ?? appKitName
        let vendor = info.vendorName ?? vendorFromProductName(productName)
        let model = productName ?? "\(vendorNumber):\(productNumber)"
        let serial = info.serial ?? (serialNumber == 0 ? nil : String(serialNumber))
        let isBuiltin = CGDisplayIsBuiltin(displayID) != 0

        return DisplaySnapshot(
            displayID: displayID,
            fingerprint: DisplayFingerprint(vendor: vendor, model: model, serial: serial, edidHash: info.edidHash),
            mode: mode,
            online: true,
            isBuiltin: isBuiltin,
            connectionDescription: info.connectionDescription,
            isActive: CGDisplayIsActive(displayID) != 0,
            isAsleep: CGDisplayIsAsleep(displayID) != 0
        )
    }

    private struct DisplayInfo {
        var productName: String?
        var vendorName: String?
        var serial: String?
        var edidHash: String?
        var connectionDescription: String?
    }

    private func displayInfo(displayID: CGDirectDisplayID) -> DisplayInfo {
        // CGDisplayIOServicePort 被 macOS 10.15 后标记为 unavailable。通过
        // IODisplayConnect 服务枚举读取同一份 EDID 派生信息，兼容当前 SDK。
        let targetVendor = CGDisplayVendorNumber(displayID)
        let targetProduct = CGDisplayModelNumber(displayID)
        let targetSerial = CGDisplaySerialNumber(displayID)
        var candidates: [DisplayInfo] = []
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IODisplayConnect"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return DisplayInfo()
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let dictionary = IODisplayCreateInfoDictionary(
                service,
                UInt32(kIODisplayOnlyPreferredName)
            )?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            let info = makeDisplayInfo(from: dictionary)
            let vendorID = (dictionary["DisplayVendorID"] as? NSNumber)?.uint32Value
            let productID = (dictionary["DisplayProductID"] as? NSNumber)?.uint32Value
            if targetVendor != 0, targetProduct != 0,
               vendorID == targetVendor && productID == targetProduct {
                let serial = (dictionary["DisplaySerialNumber"] as? NSNumber)?.uint32Value
                if targetSerial != 0, serial != targetSerial { continue }
                candidates.append(info)
            }
        }
        return candidates.count == 1 ? candidates[0] : DisplayInfo()
    }

    private func makeDisplayInfo(from dictionary: [String: Any]) -> DisplayInfo {
        let edid = Self.parseEDID(dictionary["IODisplayEDID"] ?? dictionary["IODisplayEDIDOriginal"])
        let localizedName = (dictionary["DisplayProductName"] as? [String: String])?.values.first
        let fallbackName = dictionary["DisplayProductName"] as? String
        let productName = localizedName ?? fallbackName ?? edid?.name
        let vendorName = vendorFromProductName(productName) ?? edid?.manufacturer
        let serial = (dictionary["DisplaySerialString"] as? String)
            ?? (dictionary["DisplaySerialNumber"] as? NSNumber).map { $0.stringValue }
            ?? edid?.serial
        let edidHash = Self.edidHash(from: dictionary["IODisplayEDID"] ?? dictionary["IODisplayEDIDOriginal"])
        let vendorID = (dictionary["DisplayVendorID"] as? NSNumber)?.uint32Value
        let productID = (dictionary["DisplayProductID"] as? NSNumber)?.uint32Value
        let connection = [vendorID, productID]
            .compactMap { $0 }
            .map(String.init)
            .joined(separator: ":")

        return DisplayInfo(
            productName: productName,
            vendorName: vendorName,
            serial: serial,
            edidHash: edidHash,
            connectionDescription: connection.isEmpty ? nil : "EDID \(connection)"
        )
    }

    private struct ParsedEDID {
        let manufacturer: String?
        let name: String?
        let serial: String?
    }

    private static func parseEDID(_ value: Any?) -> ParsedEDID? {
        guard let data = value as? Data else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count >= 128 else { return nil }

        let manufacturerWord = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        let manufacturer = [10, 5, 0].compactMap { shift -> Character? in
            let code = Int((manufacturerWord >> UInt16(shift)) & 0x1F)
            guard (1...26).contains(code), let scalar = UnicodeScalar(64 + code) else { return nil }
            return Character(scalar)
        }
        let manufacturerName = manufacturer.count == 3 ? String(manufacturer) : nil

        var monitorName: String?
        var descriptorSerial: String?
        for offset in stride(from: 54, through: 108, by: 18) {
            guard bytes[offset] == 0, bytes[offset + 1] == 0, bytes[offset + 2] == 0 else { continue }
            let text = String(bytes: bytes[(offset + 5)..<(offset + 18)], encoding: .ascii)?
                .replacingOccurrences(of: "\0", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text, !text.isEmpty else { continue }
            switch bytes[offset + 3] {
            case 0xFC:
                monitorName = text
            case 0xFF:
                descriptorSerial = text
            default:
                continue
            }
        }

        let baseSerial = UInt32(bytes[12]) |
            UInt32(bytes[13]) << 8 |
            UInt32(bytes[14]) << 16 |
            UInt32(bytes[15]) << 24
        let serial = descriptorSerial ?? (baseSerial == 0 ? nil : String(baseSerial))
        return ParsedEDID(manufacturer: manufacturerName, name: monitorName, serial: serial)
    }

    private static func edidHash(from value: Any?) -> String? {
        guard let data = value as? Data, !data.isEmpty else { return nil }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(bytes.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func vendorFromProductName(_ productName: String?) -> String? {
        guard let productName else { return nil }
        let normalized = productName.uppercased()
        if normalized.contains("MSI") || normalized.contains("MPG") {
            return "MSI"
        }
        if normalized.contains("ANT") {
            return "ANT"
        }
        return nil
    }
}

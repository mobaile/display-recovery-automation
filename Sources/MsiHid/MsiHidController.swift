import Foundation
import IOKit.hid

import DisplayRecoveryCore

public enum MsiDualMode: String, Codable, Sendable {
    case uhd
    case fhd
    case unknown

    public var displayMode: DisplayModeSignature {
        switch self {
        case .uhd:
            // 002E0 只表示 UHD 双模式，实际刷新率由显示器当前枚举结果提供。
            return DisplayModeSignature(width: 3840, height: 2160, refreshRate: 0)
        case .fhd:
            return DisplayModeSignature(width: 1920, height: 1080, refreshRate: 320)
        case .unknown:
            return DisplayModeSignature(width: 0, height: 0, refreshRate: 0)
        }
    }
}

public struct MsiHidStatus: Sendable {
    public let connected: Bool
    public let mode: MsiDualMode
    public let rawMode: String
    public let rawConfirmation: String
    public let rawInputSource: String

    public init(
        connected: Bool,
        mode: MsiDualMode,
        rawMode: String,
        rawConfirmation: String,
        rawInputSource: String
    ) {
        self.connected = connected
        self.mode = mode
        self.rawMode = rawMode
        self.rawConfirmation = rawConfirmation
        self.rawInputSource = rawInputSource
    }
}

public final class MsiHidController: @unchecked Sendable {
    private enum Register {
        static let mode = "002E0"
        static let confirmation = "00190"
        static let inputSource = "00500"
    }

    public init() {}

    public func readStatus(retries: Int = 2) -> MsiHidStatus {
        var best: [String: String] = [:]

        for attempt in 0...max(0, retries) {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: 0.45)
            }

            let status = readOnce()
            if status.connected {
                best["connected"] = "1"
            } else if best["connected"] == nil {
                best["connected"] = "0"
            }

            for (key, value) in [
                (Register.mode, status.rawMode),
                (Register.confirmation, status.rawConfirmation),
                (Register.inputSource, status.rawInputSource)
            ] where value != "NO_RESPONSE" || best[key] == nil {
                best[key] = value
            }

            if best["connected"] == "1",
               best[Register.mode] != nil,
               best[Register.mode] != "NO_RESPONSE",
               best[Register.confirmation] != nil,
               best[Register.confirmation] != "NO_RESPONSE",
               best[Register.inputSource] != nil,
               best[Register.inputSource] != "NO_RESPONSE" {
                break
            }
        }

        let rawMode = best[Register.mode] ?? "NO_RESPONSE"
        let rawConfirmation = best[Register.confirmation] ?? "NO_RESPONSE"
        let rawInputSource = best[Register.inputSource] ?? "NO_RESPONSE"
        return MsiHidStatus(
            connected: best["connected"] == "1",
            mode: decodeMode(rawMode: rawMode, rawConfirmation: rawConfirmation),
            rawMode: rawMode,
            rawConfirmation: rawConfirmation,
            rawInputSource: rawInputSource
        )
    }

    @discardableResult
    public func setMode(_ mode: MsiDualMode) -> Bool {
        let value: String
        switch mode {
        case .uhd:
            value = "000"
        case .fhd:
            value = "001"
        case .unknown:
            return false
        }

        // 某些固件接受写入后不会返回确认报文；实际是否生效由恢复状态机
        // 继续读取显示器模式确认，这里只报告 IOHIDDeviceSetReport 的结果。
        for attempt in 0...2 {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: 0.2 * Double(attempt))
            }
            guard let session = HIDSession() else { continue }
            if session.write("5b002E0\(value)", settleSeconds: 0.35) {
                return true
            }
        }
        return false
    }

    private func readOnce() -> MsiHidStatus {
        guard let session = HIDSession() else {
            return MsiHidStatus(
                connected: false,
                mode: .unknown,
                rawMode: "NO_RESPONSE",
                rawConfirmation: "NO_RESPONSE",
                rawInputSource: "NO_RESPONSE"
            )
        }

        return MsiHidStatus(
            connected: true,
            mode: .unknown,
            rawMode: session.send("58002E0", waitSeconds: 0.25) ?? "NO_RESPONSE",
            rawConfirmation: session.send("5800190", waitSeconds: 0.25) ?? "NO_RESPONSE",
            rawInputSource: session.send("5800500", waitSeconds: 0.25) ?? "NO_RESPONSE"
        )
    }

    private func decodeMode(rawMode: String, rawConfirmation: String) -> MsiDualMode {
        if rawMode.hasSuffix("000") { return .uhd }
        if rawMode.hasSuffix("001") { return .fhd }
        if rawConfirmation.hasSuffix("001") { return .uhd }
        if rawConfirmation.hasSuffix("000") { return .fhd }
        return .unknown
    }
}

private final class HIDReportSink {
    private let lock = NSLock()
    private var storedReports: [[UInt8]] = []

    func clear() {
        lock.lock()
        storedReports.removeAll()
        lock.unlock()
    }

    func append(_ report: [UInt8]) {
        lock.lock()
        storedReports.append(report)
        lock.unlock()
    }

    var firstReport: [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return storedReports.first
    }
}

private final class HIDSession {
    private let reportID: CFIndex = 0x01
    private let reportLength = 64
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let sink = HIDReportSink()
    private let buffer: UnsafeMutablePointer<UInt8>

    init?() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: 0x1462,
            kIOHIDProductIDKey as String: 0x3FA4
        ] as CFDictionary)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let firstDevice = devices.first,
              IOHIDDeviceOpen(firstDevice, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }

        device = firstDevice
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportLength)
        buffer.initialize(repeating: 0, count: reportLength)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(sink).toOpaque())
        IOHIDDeviceRegisterInputReportCallback(device, buffer, reportLength, { context, _, _, _, _, report, length in
            guard let context else { return }
            let sink = Unmanaged<HIDReportSink>.fromOpaque(context).takeUnretainedValue()
            sink.append(Array(UnsafeBufferPointer(start: report, count: length)))
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deinitialize(count: reportLength)
        buffer.deallocate()
    }

    func send(_ asciiCommand: String, waitSeconds: Double) -> String? {
        guard write(asciiCommand) else { return nil }

        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, waitSeconds, false)
        guard let report = sink.firstReport,
              let terminator = report.firstIndex(of: 0x0D),
              terminator > 1 else {
            return nil
        }
        return String(bytes: report[1..<terminator], encoding: .utf8)
    }

    func write(_ asciiCommand: String, settleSeconds: Double = 0) -> Bool {
        sink.clear()
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.03, false)
        sink.clear()

        var output = [UInt8](repeating: 0, count: reportLength)
        output[0] = UInt8(reportID)
        let commandBytes = Array((asciiCommand + "\r").utf8)
        for (index, byte) in commandBytes.enumerated() where index + 1 < output.count {
            output[index + 1] = byte
        }

        let result = output.withUnsafeBytes {
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                reportID,
                $0.bindMemory(to: UInt8.self).baseAddress!,
                reportLength
            )
        }
        guard result == kIOReturnSuccess else { return false }
        if settleSeconds > 0 {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, settleSeconds, false)
        }
        return true
    }
}

import Foundation
import IOKit.hid
import DisplayRecoveryCore

public typealias MsiDualMode = MsiHardwareDualMode

public struct MsiHidStatus: Sendable {
    public let connected: Bool
    public let isAmbiguous: Bool
    public let mode: MsiHardwareDualMode
    public let rawMode: String
    public let rawConfirmation: String
    public let rawInputSource: String
    public let identity: String?
    public let observedAt: TimeInterval
    public init(connected: Bool, isAmbiguous: Bool = false, mode: MsiHardwareDualMode = .unknown,
                rawMode: String = "NO_RESPONSE", rawConfirmation: String = "NO_RESPONSE", rawInputSource: String = "NO_RESPONSE",
                identity: String? = nil, observedAt: TimeInterval = SystemRecoveryClock().monotonicNow) {
        self.connected = connected; self.isAmbiguous = isAmbiguous; self.mode = mode
        self.rawMode = rawMode; self.rawConfirmation = rawConfirmation; self.rawInputSource = rawInputSource
        self.identity = identity; self.observedAt = observedAt
    }
}

/// 已由现场记录验证的响应形式：5b + 五位寄存器 + 三位值。
public enum MsiHidProtocol {
    public static func value(in response: String, register: String) -> String? {
        let text = response.uppercased()
        guard text.count == 10, text.hasPrefix("5B" + register.uppercased()) else { return nil }
        let value = String(text.suffix(3))
        guard value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return value
    }
    public static func mode(from response: String) -> MsiHardwareDualMode {
        switch value(in: response, register: "002E0") {
        case "000": return .uhd
        case "001": return .fhd
        default: return .unknown
        }
    }
}

public final class MsiHidController: @unchecked Sendable {
    // 所有实例共用通道，UI 与恢复不能各自创建可并发写入的串行队列。
    private static let serialQueue = DispatchQueue(label: "local.codex.msihid.serial")
    private let cacheLock = NSLock()
    private var lastCachedStatus = MsiHidStatus(connected: false)
    public init() {}
    public func cachedStatus() -> MsiHidStatus { cacheLock.withLock { lastCachedStatus } }

    public func readStatus(retries: Int = 0) -> MsiHidStatus {
        Self.serialQueue.sync {
            (try? readOnce(deadline: RecoveryDeadline(seconds: 3))) ?? MsiHidStatus(connected: false)
        }
    }
    public func readStatus(deadline: RecoveryDeadline) async throws -> MsiHidStatus {
        try await perform { try self.readOnce(deadline: deadline) }
    }
    public func setMode(_ mode: MsiHardwareDualMode, expectedIdentity: String, deadline: RecoveryDeadline) async throws {
        try await perform {
            try deadline.check("MSI mode write")
            guard mode != .unknown, let session = HIDSession() else { throw RecoveryError.monitorUnavailable }
            guard !session.isAmbiguous, session.identity == expectedIdentity else {
                throw RecoveryError.ambiguousDisplay("MSI HID target mismatch")
            }
            try session.write("5b002E0" + (mode == .uhd ? "000" : "001"), deadline: deadline)
            // 仅代表指令已发出；确认由独立读回完成，不能编造成功缓存。
            self.cacheLock.withLock { self.lastCachedStatus = MsiHidStatus(connected: true, identity: session.identity) }
        }
    }
    private func readOnce(deadline: RecoveryDeadline) throws -> MsiHidStatus {
        try deadline.check("MSI HID read")
        guard let session = HIDSession() else {
            let status = MsiHidStatus(connected: false)
            cacheLock.withLock { lastCachedStatus = status }
            return status
        }
        if session.isAmbiguous {
            let status = MsiHidStatus(connected: false, isAmbiguous: true)
            cacheLock.withLock { lastCachedStatus = status }
            return status
        }
        let raw = try session.send("58002E0", expectedRegister: "002E0", deadline: deadline) ?? "NO_RESPONSE"
        let status = MsiHidStatus(connected: true, mode: MsiHidProtocol.mode(from: raw), rawMode: raw,
                                  identity: session.identity, observedAt: deadline.clock.monotonicNow)
        cacheLock.withLock { lastCachedStatus = status }
        return status
    }
    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.serialQueue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
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

    func reports() -> [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return storedReports
    }
}

private final class HIDSession {
    private let reportID: CFIndex = 0x01
    private let reportLength = 64
    private let manager: IOHIDManager
    private let device: IOHIDDevice?
    private let sink = HIDReportSink()
    private let buffer: UnsafeMutablePointer<UInt8>?
    public private(set) var isAmbiguous: Bool = false
    private(set) var identity: String?

    init?() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: 0x1462,
            kIOHIDProductIDKey as String: 0x3FA4
        ] as CFDictionary)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return nil
        }

        if devices.count > 1 {
            self.isAmbiguous = true
            self.device = nil
            self.buffer = nil
            return
        }

        guard let firstDevice = devices.first,
              IOHIDDeviceOpen(firstDevice, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }

        self.device = firstDevice
        let serial = IOHIDDeviceGetProperty(firstDevice, kIOHIDSerialNumberKey as CFString) as? String
        let location = IOHIDDeviceGetProperty(firstDevice, kIOHIDLocationIDKey as CFString) as? NSNumber
        if let serial, !serial.isEmpty { identity = "1462:3fa4:serial:" + serial }
        else if let location { identity = "1462:3fa4:location:" + location.stringValue }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: reportLength)
        buf.initialize(repeating: 0, count: reportLength)
        self.buffer = buf

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(sink).toOpaque())
        IOHIDDeviceRegisterInputReportCallback(firstDevice, buf, reportLength, { context, _, _, _, _, report, length in
            guard let context else { return }
            let sink = Unmanaged<HIDReportSink>.fromOpaque(context).takeUnretainedValue()
            sink.append(Array(UnsafeBufferPointer(start: report, count: length)))
        }, context)
        IOHIDDeviceScheduleWithRunLoop(firstDevice, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if let buffer {
            buffer.deinitialize(count: reportLength)
            buffer.deallocate()
        }
    }

    func send(_ asciiCommand: String, expectedRegister: String, deadline: RecoveryDeadline) throws -> String? {
        try write(asciiCommand, deadline: deadline)
        let end = min(deadline.expiresAt, deadline.clock.monotonicNow + 0.3)
        repeat {
            try deadline.check("Wait for MSI HID response")
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, min(0.01, deadline.remaining), false)
            for report in sink.reports() {
                guard report.first == UInt8(reportID), let terminator = report.firstIndex(of: 0x0D), terminator > 1,
                      let text = String(bytes: report[1..<terminator], encoding: .utf8),
                      MsiHidProtocol.value(in: text, register: expectedRegister) != nil else { continue }
                return text
            }
        } while deadline.clock.monotonicNow < end
        return nil
    }

    func write(_ asciiCommand: String, deadline: RecoveryDeadline) throws {
        guard let device else { throw RecoveryError.monitorUnavailable }
        try deadline.check("Send MSI HID report")
        sink.clear()
        // 清空上一请求的剩余输入，等待也计入同一个 deadline。
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, min(0.03, deadline.remaining), false)
        sink.clear()
        try deadline.check("Send MSI HID report")
        let request = HIDOutputRequest(command: asciiCommand, reportID: UInt8(reportID), length: reportLength)
        let context = Unmanaged.passRetained(request).toOpaque()
        // SDK 将此参数定义为毫秒；异步接口避免同步 SetReport 阻塞执行器。
        let result = IOHIDDeviceSetReportWithCallback(device, kIOHIDReportTypeOutput, reportID,
            request.bytes, reportLength, min(1000, deadline.remaining * 1000), { context, result, _, _, _, _, _ in
                guard let context else { return }
                let request = Unmanaged<HIDOutputRequest>.fromOpaque(context).takeRetainedValue()
                request.finish(result)
            }, context)
        guard result == kIOReturnSuccess else {
            Unmanaged<HIDOutputRequest>.fromOpaque(context).release()
            throw RecoveryError.operationFailed("HID report submission failed (\(result)).")
        }
        // 请求对象自行保有报告内存，超时后的迟到回调不会访问已释放的缓冲区。
        while request.result == nil {
            try deadline.check("MSI HID report transmission")
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, min(0.01, deadline.remaining), false)
        }
        guard request.result == kIOReturnSuccess else {
            throw RecoveryError.operationFailed("HID report transmission failed (\(request.result ?? kIOReturnError)).")
        }
        try deadline.check("MSI HID report transmission")
    }
}

private final class HIDOutputRequest {
    let bytes: UnsafeMutablePointer<UInt8>
    private let lock = NSLock()
    private var completion: IOReturn?
    var result: IOReturn? { lock.withLock { completion } }
    init(command: String, reportID: UInt8, length: Int) {
        bytes = .allocate(capacity: length)
        bytes.initialize(repeating: 0, count: length)
        bytes[0] = reportID
        for (i, byte) in (command + "\r").utf8.enumerated() where i + 1 < length { bytes[i + 1] = byte }
    }
    func finish(_ result: IOReturn) { lock.withLock { completion = result } }
    deinit { bytes.deallocate() }
}

import CommonCrypto
import Darwin
import Foundation

import DisplayRecoveryCore

public struct MiotDeviceInfo: Codable, Equatable, Sendable {
    public var model: String
    public var firmwareVersion: String?
    public var hardwareVersion: String?

    public init(model: String, firmwareVersion: String? = nil, hardwareVersion: String? = nil) {
        self.model = model
        self.firmwareVersion = firmwareVersion
        self.hardwareVersion = hardwareVersion
    }
}

public enum MiotLocalError: LocalizedError, Equatable, Sendable {
    case invalidHost
    case invalidToken
    case socketCreationFailed(String)
    case socketConnectionFailed(String)
    case sendFailed(String)
    case receiveTimedOut
    case malformedPacket
    case decryptionFailed
    case invalidResponse(String)
    case deviceError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "插座 IP 地址无效"
        case .invalidToken:
            return "插座 token 无效"
        case .socketCreationFailed(let reason):
            return "创建局域网连接失败：\(reason)"
        case .socketConnectionFailed(let reason):
            return "连接插座失败：\(reason)"
        case .sendFailed(let reason):
            return "发送插座命令失败：\(reason)"
        case .receiveTimedOut:
            return "插座响应超时"
        case .malformedPacket:
            return "插座返回了无法解析的数据包"
        case .decryptionFailed:
            return "插座响应解密失败"
        case .invalidResponse(let reason):
            return "插座返回无效结果：\(reason)"
        case .deviceError(let reason):
            return "插座拒绝命令：\(reason)"
        }
    }
}

public final class MiotLocalClient: @unchecked Sendable {
    public static let supportedModels: Set<String> = ["chuangmi.plug.212a01", "cuco.plug.v3"]
    private let host: String
    private let port: UInt16
    private let token: Data
    // 所有会话状态只在此队列访问，网络轮询在每个时间片检查截止时间和取消。
    private let queue = DispatchQueue(label: "local.codex.miot.serial")
    private var sequence: UInt32 = 1
    private var deviceID: UInt32?
    private var boundDeviceID: UInt32?
    private var deviceTimeBase: UInt32?
    private var localTimeBase: TimeInterval = 0
    private var validatedModel: String?

    public init(host: String, token: String, port: UInt16 = 54321) throws {
        guard Self.isIPv4(host) else { throw MiotLocalError.invalidHost }
        guard let data = Self.decodeToken(token) else { throw MiotLocalError.invalidToken }
        self.host = host; self.port = port; self.token = data
    }

    public func deviceInfo(deadline: RecoveryDeadline = RecoveryDeadline(seconds: 10)) async throws -> MiotDeviceInfo {
        try await perform(deadline) {
            try self.info(self.requestRead("miIO.info", params: [], deadline: deadline))
        }
    }
    public func validate(expectedModel: String, deadline: RecoveryDeadline = RecoveryDeadline(seconds: 10)) async throws -> MiotDeviceInfo {
        try await perform(deadline) { try self.validateLocked(expectedModel, deadline: deadline) }
    }
    public func getPower(deadline: RecoveryDeadline = RecoveryDeadline(seconds: 10)) async throws -> Bool {
        try await perform(deadline) { try self.power(self.requestRead("get_properties", params: [["siid": 2, "piid": 1]], deadline: deadline)) }
    }
    public func setPower(_ on: Bool, expectedModel: String? = nil, deadline: RecoveryDeadline = RecoveryDeadline(seconds: 10)) async throws {
        try await perform(deadline) {
            if let expectedModel { _ = try self.validateLocked(expectedModel, deadline: deadline) }
            do {
                // 控制命令最多发送一次；不确定是否执行时优先查询实际状态。
                let payload = try self.sendSynchronously(method: "set_properties", params: [["siid": 2, "piid": 1, "value": on]], deadline: deadline)
                guard Self.isSuccessfulSetPropertiesResult(payload["result"]) else {
                    throw MiotLocalError.invalidResponse("开关命令未返回有效成功状态")
                }
            } catch {
                let original = error
                try deadline.check("确认插座写入结果")
                self.resetSession()
                let actual = try? self.power(self.requestRead("get_properties", params: [["siid": 2, "piid": 1]], deadline: deadline))
                guard actual == on else { throw original }
            }
        }
    }

    private func perform<T: Sendable>(_ deadline: RecoveryDeadline, _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try deadline.check()
                        let value = try operation()
                        try deadline.check()
                        continuation.resume(returning: value)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { deadline.cancellation.cancel("插座操作已取消") }
    }
    private func validateLocked(_ expected: String, deadline: RecoveryDeadline) throws -> MiotDeviceInfo {
        try deadline.check()
        if validatedModel == expected, deviceID != nil { return MiotDeviceInfo(model: expected) }
        let info = try info(requestRead("miIO.info", params: [], deadline: deadline))
        guard info.model == expected else { throw RecoveryError.plugModelMismatch(expected: expected, actual: info.model) }
        validatedModel = info.model
        return info
    }
    private func info(_ payload: [String: Any]) throws -> MiotDeviceInfo {
        guard let result = firstResultDictionary(payload), let model = result["model"] as? String else {
            throw MiotLocalError.invalidResponse("缺少 model")
        }
        return MiotDeviceInfo(model: model, firmwareVersion: result["fw_ver"] as? String, hardwareVersion: result["hw_ver"] as? String)
    }
    private func power(_ payload: [String: Any]) throws -> Bool {
        guard let results = payload["result"] as? [[String: Any]], results.count == 1,
              let result = results.first, let code = result["code"] as? NSNumber, code.intValue == 0,
              let value = result["value"] as? Bool else { throw MiotLocalError.invalidResponse("开关状态缺失或读取失败") }
        return value
    }
    private static func isSuccessfulSetPropertiesResult(_ value: Any?) -> Bool {
        if let result = value as? [NSNumber] { return result.count == 1 && result[0].intValue == 0 }
        if let result = value as? [[String: Any]], result.count == 1, let code = result[0]["code"] as? NSNumber { return code.intValue == 0 }
        return false
    }
    private func resetSession() {
        deviceID = nil; deviceTimeBase = nil; validatedModel = nil
    }
    private func requestRead(_ method: String, params: Any, deadline: RecoveryDeadline) throws -> [String: Any] {
        for attempt in 0..<3 {
            do { return try sendSynchronously(method: method, params: params, deadline: deadline) }
            catch {
                try deadline.check()
                guard attempt < 2, let error = error as? MiotLocalError, error == .receiveTimedOut || error == .malformedPacket else { throw error }
                resetSession()
            }
        }
        throw MiotLocalError.receiveTimedOut
    }
    private func sendSynchronously(method: String, params: Any, deadline: RecoveryDeadline) throws -> [String: Any] {
        try deadline.check()
        if deviceID == nil {
            let hello = try sendPacket(Self.helloPacket(), deadline: deadline)
            guard hello.count == 32, hello.readUInt16BE(at: 0) == 0x2131 else { throw MiotLocalError.malformedPacket }
            let identity = hello.readUInt32BE(at: 8)
            if let boundDeviceID, boundDeviceID != identity { throw MiotLocalError.invalidResponse("插座设备身份发生变化") }
            boundDeviceID = identity; deviceID = identity
            deviceTimeBase = hello.readUInt32BE(at: 12); localTimeBase = deadline.clock.monotonicNow
        }
        let requestID = sequence
        sequence &+= 1
        var command: [String: Any] = ["id": requestID, "method": method, "params": params]
        if let params = params as? [[String: Any]], let deviceID {
            command["params"] = params.map { item in var item = item; item["did"] = String(deviceID); return item }
        }
        let json = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
        let packet = try makePacket(payload: json, deviceID: deviceID ?? 0, now: deadline.clock.monotonicNow)
        let response = try sendPacket(packet, deadline: deadline)
        let result = try decodeResponse(response)
        guard let responseID = result["id"] as? NSNumber, responseID.uint32Value == requestID else {
            throw MiotLocalError.invalidResponse("响应缺少匹配的请求编号")
        }
        guard response.readUInt32BE(at: 8) == deviceID else { throw MiotLocalError.invalidResponse("响应设备编号不匹配") }
        deviceTimeBase = response.readUInt32BE(at: 12); localTimeBase = deadline.clock.monotonicNow
        return result
    }
    private func sendPacket(_ packet: Data, deadline: RecoveryDeadline) throws -> Data {
        try deadline.check("插座 UDP 通信")
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw MiotLocalError.socketCreationFailed(String(cString: strerror(errno))) }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw MiotLocalError.socketCreationFailed(String(cString: strerror(errno))) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw MiotLocalError.invalidHost }
        let connected = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { throw MiotLocalError.socketConnectionFailed(String(cString: strerror(errno))) }
        try deadline.check("发送插座命令")
        let sent = packet.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == packet.count else { throw MiotLocalError.sendFailed(String(cString: strerror(errno))) }
        let responseDeadline = min(deadline.expiresAt, deadline.clock.monotonicNow + 3)
        while deadline.clock.monotonicNow < responseDeadline {
            try deadline.check("等待插座应答")
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, min(50, (responseDeadline - deadline.clock.monotonicNow) * 1000)))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw MiotLocalError.sendFailed(String(cString: strerror(errno)))
            }
            if ready == 0 { continue }
            var response = Data(count: 4096)
            let count = response.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw MiotLocalError.sendFailed(String(cString: strerror(errno)))
            }
            response.removeSubrange(count..<response.count)
            try deadline.check("等待插座应答")
            return response
        }
        throw MiotLocalError.receiveTimedOut
    }

    private func makePacket(payload: Data, deviceID: UInt32, now: TimeInterval) throws -> Data {
        let encrypted = try Self.encrypt(payload, token: token)
        let packetLength = 32 + encrypted.count
        guard packetLength <= Int(UInt16.max) else { throw MiotLocalError.malformedPacket }

        let elapsed = UInt32(max(0, now - localTimeBase))
        let timestamp = (deviceTimeBase ?? UInt32(Date().timeIntervalSince1970)) &+ elapsed

        var packet = Data()
        packet.appendUInt16BE(0x2131)
        packet.appendUInt16BE(UInt16(packetLength))
        packet.appendUInt32BE(0)
        packet.appendUInt32BE(deviceID)
        packet.appendUInt32BE(timestamp)
        packet.append(contentsOf: repeatElement(0, count: 16))
        packet.append(encrypted)

        var checksumInput = Data()
        checksumInput.append(packet.prefix(16))
        checksumInput.append(token)
        checksumInput.append(encrypted)
        let checksum = Self.md5(checksumInput)
        packet.replaceSubrange(16..<32, with: checksum)
        return packet
    }

    private func decodeResponse(_ packet: Data) throws -> [String: Any] {
        guard packet.count >= 32,
              packet.readUInt16BE(at: 0) == 0x2131,
              Int(packet.readUInt16BE(at: 2)) == packet.count else {
            throw MiotLocalError.malformedPacket
        }

        let payload = packet.subdata(in: 32..<packet.count)
        var checksumInput = Data()
        checksumInput.append(packet.prefix(16))
        checksumInput.append(token)
        checksumInput.append(payload)
        guard Self.md5(checksumInput) == packet.subdata(in: 16..<32) else {
            throw MiotLocalError.invalidResponse("校验和不匹配")
        }
        guard let decrypted = try? Self.decrypt(payload, token: token) else {
            throw MiotLocalError.decryptionFailed
        }
        guard let object = try? JSONSerialization.jsonObject(with: decrypted),
              let dictionary = object as? [String: Any] else {
            throw MiotLocalError.invalidResponse("JSON 无效")
        }
        if let error = dictionary["error"] as? [String: Any] {
            throw MiotLocalError.deviceError(error["message"] as? String ?? "未知错误")
        }
        return dictionary
    }

    private func firstResultDictionary(_ payload: [String: Any]) -> [String: Any]? {
        if let dict = payload["result"] as? [String: Any] {
            return dict
        }
        return (payload["result"] as? [[String: Any]])?.first
    }

    private static func helloPacket() -> Data {
        Data(hex: "21310020ffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
    }

    private static func decodeToken(_ token: String) -> Data? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count == 32 else { return nil }
        var data = Data()
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data.count == 16 ? data : nil
    }

    private static func isIPv4(_ host: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, host, &address) == 1
    }

    private static func md5(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_MD5(bytes.baseAddress, CC_LONG(bytes.count), &digest)
        }
        return Data(digest)
    }

    private static func encrypt(_ plaintext: Data, token: Data) throws -> Data {
        let key = md5(token)
        var ivInput = Data()
        ivInput.append(key)
        ivInput.append(token)
        let iv = md5(ivInput)
        return try crypt(operation: CCOperation(kCCEncrypt), input: plaintext, key: key, iv: iv)
    }

    private static func decrypt(_ ciphertext: Data, token: Data) throws -> Data {
        let key = md5(token)
        var ivInput = Data()
        ivInput.append(key)
        ivInput.append(token)
        let iv = md5(ivInput)
        return try crypt(operation: CCOperation(kCCDecrypt), input: ciphertext, key: key, iv: iv)
    }

    private static func crypt(operation: CCOperation, input: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var outputLength = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            input.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw MiotLocalError.decryptionFailed }
        output.removeSubrange(outputLength..<output.count)
        return output
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<next], radix: 16) {
                append(byte)
            }
            index = next
        }
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 |
            UInt32(self[offset + 1]) << 16 |
            UInt32(self[offset + 2]) << 8 |
            UInt32(self[offset + 3])
    }
}

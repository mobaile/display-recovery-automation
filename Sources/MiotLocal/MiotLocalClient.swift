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
    public static let supportedModels: Set<String> = [
        "chuangmi.plug.212a01",
        "cuco.plug.v3"
    ]

    private let host: String
    private let port: UInt16
    private let token: Data
    private let lock = NSLock()
    private var sequence: UInt32 = 1
    private var deviceID: UInt32?

    public init(host: String, token: String, port: UInt16 = 54321) throws {
        guard Self.isIPv4(host) else { throw MiotLocalError.invalidHost }
        guard let tokenData = Self.decodeToken(token) else { throw MiotLocalError.invalidToken }
        self.host = host
        self.port = port
        self.token = tokenData
    }

    public func deviceInfo() async throws -> MiotDeviceInfo {
        let payload = try await request(method: "miIO.info", params: [])
        guard let dictionary = firstResultDictionary(payload),
              let model = dictionary["model"] as? String else {
            throw MiotLocalError.invalidResponse("缺少 model")
        }
        return MiotDeviceInfo(
            model: model,
            firmwareVersion: dictionary["fw_ver"] as? String,
            hardwareVersion: dictionary["hw_ver"] as? String
        )
    }

    public func validate(expectedModel: String) async throws -> MiotDeviceInfo {
        let info = try await deviceInfo()
        guard info.model == expectedModel else {
            throw RecoveryError.plugModelMismatch(expected: expectedModel, actual: info.model)
        }
        return info
    }

    public func getPower() async throws -> Bool {
        let payload = try await request(
            method: "get_properties",
            params: [["siid": 2, "piid": 1]]
        )
        guard let result = payload["result"] as? [[String: Any]],
              let value = result.first?["value"] as? Bool else {
            throw MiotLocalError.invalidResponse("缺少开关状态")
        }
        return value
    }

    public func setPower(_ on: Bool) async throws {
        let payload = try await request(
            method: "set_properties",
            params: [["siid": 2, "piid": 1, "value": on]]
        )
        if let error = payload["error"] as? [String: Any] {
            throw MiotLocalError.deviceError(error["message"] as? String ?? "未知错误")
        }
        guard Self.isSuccessfulSetPropertiesResult(payload["result"]) else {
            throw MiotLocalError.invalidResponse("开关命令未返回成功状态")
        }
    }

    private static func isSuccessfulSetPropertiesResult(_ value: Any?) -> Bool {
        if let result = value as? [NSNumber],
           let code = result.first {
            return code.intValue == 0
        }
        if let result = value as? [[String: Any]],
           let code = result.first?["code"] as? NSNumber {
            return code.intValue == 0
        }
        return false
    }

    private func request(method: String, params: Any) async throws -> [String: Any] {
        var attempt = 0
        while true {
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let response = try self.sendSynchronously(method: method, params: params)
                            continuation.resume(returning: response)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                guard attempt < 2, Self.isRetryable(error) else { throw error }
                let delay = UInt64(150_000_000) << UInt64(attempt)
                try await Task.sleep(nanoseconds: delay)
                attempt += 1
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case MiotLocalError.receiveTimedOut,
             MiotLocalError.socketCreationFailed,
             MiotLocalError.socketConnectionFailed,
             MiotLocalError.sendFailed:
            return true
        default:
            return false
        }
    }

    private func sendSynchronously(method: String, params: Any) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        if deviceID == nil {
            let hello = try sendPacket(Self.helloPacket())
            guard hello.count >= 32,
                  hello[0] == 0x21,
                  hello[1] == 0x31 else {
                throw MiotLocalError.malformedPacket
            }
            deviceID = hello.readUInt32BE(at: 8)
        }

        let command: [String: Any] = [
            "id": sequence,
            "method": method,
            "params": params
        ]
        sequence &+= 1
        let json = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys])
        let packet = try makePacket(payload: json, deviceID: deviceID ?? 0)
        let response = try sendPacket(packet)
        return try decodeResponse(response)
    }

    private func sendPacket(_ packet: Data) throws -> Data {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw MiotLocalError.socketCreationFailed(String(cString: strerror(errno)))
        }
        defer { close(socketFD) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw MiotLocalError.invalidHost
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw MiotLocalError.socketConnectionFailed(String(cString: strerror(errno)))
        }

        let sent = packet.withUnsafeBytes { buffer in
            Darwin.send(socketFD, buffer.baseAddress, buffer.count, 0)
        }
        guard sent == packet.count else {
            throw MiotLocalError.sendFailed(String(cString: strerror(errno)))
        }

        var response = Data(count: 4096)
        let received = response.withUnsafeMutableBytes { buffer in
            Darwin.recv(socketFD, buffer.baseAddress, buffer.count, 0)
        }
        if received < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw MiotLocalError.receiveTimedOut
            }
            throw MiotLocalError.sendFailed(String(cString: strerror(errno)))
        }
        response.removeSubrange(received..<response.count)
        return response
    }

    private func makePacket(payload: Data, deviceID: UInt32) throws -> Data {
        let encrypted = try Self.encrypt(payload, token: token)
        let packetLength = 32 + encrypted.count
        guard packetLength <= Int(UInt16.max) else { throw MiotLocalError.malformedPacket }

        var packet = Data()
        packet.appendUInt16BE(0x2131)
        packet.appendUInt16BE(UInt16(packetLength))
        packet.appendUInt32BE(0)
        packet.appendUInt32BE(deviceID)
        packet.appendUInt32BE(UInt32(Date().timeIntervalSince1970))
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
        (payload["result"] as? [[String: Any]])?.first
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
        ivInput.append(md5(key))
        ivInput.append(token)
        let iv = md5(ivInput)
        return try crypt(operation: CCOperation(kCCEncrypt), input: plaintext, key: key, iv: iv)
    }

    private static func decrypt(_ ciphertext: Data, token: Data) throws -> Data {
        let key = md5(token)
        var ivInput = Data()
        ivInput.append(md5(key))
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

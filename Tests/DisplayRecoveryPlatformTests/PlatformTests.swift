import CommonCrypto
import Darwin
import XCTest
@testable import DisplayRecoveryCore
@testable import DisplayRecoveryMac
@testable import MiotLocal

final class PlatformTests: XCTestCase {
    func testConfigurationRoundTripsWithoutToken() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("display-recovery-automation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let configuration = AppConfiguration(
            recovery: RecoveryConfiguration(
                roles: DisplayRoleConfiguration(
                    powerControlled: DisplayFingerprint(vendor: "ANT", model: "ANT27VU", serial: "old"),
                    modeSwitch: DisplayFingerprint(vendor: "MSI", model: "MPG 274U E16M", serial: "new")
                ),
                automaticRecoveryEnabled: true
            ),
            plug: PlugConfiguration(model: "chuangmi.plug.212a01", host: "192.168.1.20")
        )
        let store = ConfigurationStore(url: url)
        try store.save(configuration)
        XCTAssertEqual(store.load(), configuration)
        let data = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("token"))
    }

    func testMiotClientValidatesHostAndTokenBeforeNetwork() {
        XCTAssertThrowsError(try MiotLocalClient(host: "not-an-ip", token: String(repeating: "0", count: 32))) { error in
            XCTAssertEqual(error as? MiotLocalError, .invalidHost)
        }
        XCTAssertThrowsError(try MiotLocalClient(host: "192.168.1.20", token: "bad-token")) { error in
            XCTAssertEqual(error as? MiotLocalError, .invalidToken)
        }
        XCTAssertTrue(MiotLocalClient.supportedModels.contains("chuangmi.plug.212a01"))
        XCTAssertTrue(MiotLocalClient.supportedModels.contains("cuco.plug.v3"))
    }

    func testRedactedLogRemovesIPv4Addresses() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("display-recovery-automation-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let logs = RecoveryLogStore(url: url)
        logs.append("连接 192.168.1.20 失败")
        let contents = logs.redactedContents()
        XCTAssertTrue(contents.contains("<IP>"))
        XCTAssertFalse(contents.contains("192.168.1.20"))
    }

    func testDisplayProviderCanEnumerateWithoutThrowing() {
        let snapshots = MacDisplayProvider().snapshots()
        XCTAssertEqual(Set(snapshots.map(\.displayID)).count, snapshots.count)
        XCTAssertTrue(snapshots.allSatisfy(\.online))
    }

    func testMiotClientRoundTripsAgainstLocalSimulator() async throws {
        let token = String(repeating: "ab", count: 16)
        let simulator = try MiotSimulator(token: token, model: "chuangmi.plug.212a01")
        simulator.start()
        defer { simulator.stop() }

        let client = try MiotLocalClient(host: "127.0.0.1", token: token, port: simulator.port)
        let info = try await client.validate(expectedModel: "chuangmi.plug.212a01")
        XCTAssertEqual(info.model, "chuangmi.plug.212a01")
        let initialPower = try await client.getPower()
        XCTAssertTrue(initialPower)
        try await client.setPower(false)
        let finalPower = try await client.getPower()
        XCTAssertFalse(finalPower)
    }
}

/// 只绑定 127.0.0.1 的最小 miIO/MIoT 模拟器，不访问真实局域网设备。
private final class MiotSimulator: @unchecked Sendable {
    private let socketFD: Int32
    private let token: Data
    private let model: String
    private let stateLock = NSLock()
    private var running = false
    private var power = true
    let port: UInt16

    init(token: String, model: String) throws {
        guard let tokenData = Self.decodeToken(token) else {
            throw NSError(domain: "MiotSimulator", code: 1, userInfo: [NSLocalizedDescriptionKey: "token 无效"])
        }
        let socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw NSError(domain: "MiotSimulator", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建 UDP socket"])
        }
        self.socketFD = socketFD
        self.token = tokenData
        self.model = model

        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(socketFD)
            throw NSError(domain: "MiotSimulator", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法设置回环地址"])
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socketFD)
            throw NSError(domain: "MiotSimulator", code: 4, userInfo: [NSLocalizedDescriptionKey: "无法绑定 UDP 端口"])
        }

        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &addressLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(socketFD)
            throw NSError(domain: "MiotSimulator", code: 5, userInfo: [NSLocalizedDescriptionKey: "无法读取 UDP 端口"])
        }
        self.port = UInt16(bigEndian: boundAddress.sin_port)
    }

    deinit {
        stop()
    }

    func start() {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            return
        }
        running = true
        stateLock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runLoop()
        }
    }

    func stop() {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        running = false
        stateLock.unlock()
        Darwin.close(socketFD)
    }

    private func isRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func runLoop() {
        let deviceID: UInt32 = 0x1234_5678
        while isRunning() {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var clientAddress = sockaddr_storage()
            var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &clientAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(socketFD, bytes.baseAddress, bytes.count, 0, $0, &addressLength)
                    }
                }
            }
            guard received >= 0 else { continue }
            let packet = Data(buffer.prefix(Int(received)))
            guard let response = makeResponse(for: packet, deviceID: deviceID) else { continue }
            response.withUnsafeBytes { bytes in
                withUnsafePointer(to: &clientAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = Darwin.sendto(socketFD, bytes.baseAddress, bytes.count, 0, $0, addressLength)
                    }
                }
            }
        }
    }

    private func makeResponse(for packet: Data, deviceID: UInt32) -> Data? {
        guard packet.count >= 32,
              packet.readUInt16BE(at: 0) == 0x2131 else {
            return nil
        }
        if packet.count == 32 {
            return Self.helloResponse(deviceID: deviceID)
        }

        let encrypted = packet.subdata(in: 32..<packet.count)
        guard let decrypted = try? Self.crypt(operation: CCOperation(kCCDecrypt), input: encrypted, token: token),
              let object = try? JSONSerialization.jsonObject(with: decrypted),
              let command = object as? [String: Any],
              let method = command["method"] as? String,
              let requestID = command["id"] as? NSNumber else {
            return nil
        }

        let result: [String: Any]
        switch method {
        case "miIO.info":
            result = [
                "id": requestID,
                "result": [["model": model, "fw_ver": "test", "hw_ver": "test"]]
            ]
        case "get_properties":
            stateLock.lock()
            let currentPower = power
            stateLock.unlock()
            result = [
                "id": requestID,
                "result": [["code": 0, "value": currentPower]]
            ]
        case "set_properties":
            if let params = command["params"] as? [[String: Any]],
               let first = params.first,
               let value = first["value"] as? Bool {
                stateLock.lock()
                power = value
                stateLock.unlock()
            }
            // miIO/MIoT 固件常见返回格式是 [0]；客户端同时兼容
            // 另一种 [{"code": 0}] 形式。
            result = ["id": requestID, "result": [0]]
        default:
            result = [
                "id": requestID,
                "error": ["code": -1, "message": "unsupported"]
            ]
        }

        guard let json = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
              let encryptedResponse = try? Self.crypt(operation: CCOperation(kCCEncrypt), input: json, token: token) else {
            return nil
        }
        var response = Data()
        response.appendUInt16BE(0x2131)
        response.appendUInt16BE(UInt16(32 + encryptedResponse.count))
        response.appendUInt32BE(0)
        response.appendUInt32BE(deviceID)
        response.appendUInt32BE(UInt32(Date().timeIntervalSince1970))
        response.append(contentsOf: repeatElement(0, count: 16))
        response.append(encryptedResponse)

        var checksumInput = Data()
        checksumInput.append(response.prefix(16))
        checksumInput.append(token)
        checksumInput.append(encryptedResponse)
        response.replaceSubrange(16..<32, with: Self.md5(checksumInput))
        return response
    }

    private static func helloResponse(deviceID: UInt32) -> Data {
        var packet = Data(repeating: 0, count: 32)
        packet[0] = 0x21
        packet[1] = 0x31
        packet[2] = 0
        packet[3] = 0x20
        packet.replaceUInt32BE(deviceID, at: 8)
        packet.replaceUInt32BE(UInt32(Date().timeIntervalSince1970), at: 12)
        return packet
    }

    private static func decodeToken(_ token: String) -> Data? {
        guard token.count == 32 else { return nil }
        var data = Data()
        var index = token.startIndex
        while index < token.endIndex {
            let next = token.index(index, offsetBy: 2)
            guard let byte = UInt8(token[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data.count == 16 ? data : nil
    }

    private static func md5(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_MD5(bytes.baseAddress, CC_LONG(bytes.count), &digest)
        }
        return Data(digest)
    }

    private static func crypt(operation: CCOperation, input: Data, token: Data) throws -> Data {
        let key = md5(token)
        var ivInput = Data()
        ivInput.append(md5(key))
        ivInput.append(token)
        let iv = md5(ivInput)

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
        guard status == kCCSuccess else {
            throw NSError(domain: "MiotSimulator", code: 6, userInfo: [NSLocalizedDescriptionKey: "AES 失败"])
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }
}

private extension Data {
    func readUInt16BE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
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

    mutating func replaceUInt32BE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8((value >> 24) & 0xFF)
        self[offset + 1] = UInt8((value >> 16) & 0xFF)
        self[offset + 2] = UInt8((value >> 8) & 0xFF)
        self[offset + 3] = UInt8(value & 0xFF)
    }
}

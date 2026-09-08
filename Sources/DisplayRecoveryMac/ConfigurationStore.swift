import Foundation
import Security

import DisplayRecoveryCore

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var version: Int
    public var recovery: RecoveryConfiguration
    public var plug: PlugConfiguration

    public init(
        version: Int = 1,
        recovery: RecoveryConfiguration = RecoveryConfiguration(),
        plug: PlugConfiguration = PlugConfiguration()
    ) {
        self.version = version
        self.recovery = recovery
        self.plug = plug
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard self.version == 1 else { throw ConfigurationStoreError.corruptedConfiguration("不支持的配置版本") }
        self.recovery = try container.decodeIfPresent(RecoveryConfiguration.self, forKey: .recovery) ?? RecoveryConfiguration()
        self.plug = try container.decodeIfPresent(PlugConfiguration.self, forKey: .plug) ?? PlugConfiguration()
    }
}

public enum ConfigurationStoreError: LocalizedError, Equatable, Sendable {
    case corruptedConfiguration(String)
    case migrationFailed(String)
    case tokenInvalid(String)

    public var errorDescription: String? {
        switch self {
        case .corruptedConfiguration(let reason):
            return "配置文件已损坏：\(reason)"
        case .migrationFailed(let reason):
            return "迁移失败：\(reason)"
        case .tokenInvalid(let reason):
            return "Token 无效：\(reason)"
        }
    }
}

public final class ConfigurationStore: @unchecked Sendable {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.url = appSupport
                .appendingPathComponent("DisplayRecoveryAutomation", isDirectory: true)
                .appendingPathComponent("config.json")
        }

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppConfiguration()
        }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(AppConfiguration.self, from: data)
        } catch {
            throw ConfigurationStoreError.corruptedConfiguration(error.localizedDescription)
        }
    }

    public func loadOrRecover() -> (configuration: AppConfiguration, error: Error?) {
        do {
            let cfg = try load()
            return (cfg, nil)
        } catch {
            // 备份损坏配置，保留默认以保证界面能起，但明确上报错误
            let backupUrl = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).bak")
            try? FileManager.default.copyItem(at: url, to: backupUrl)
            return (AppConfiguration(), error)
        }
    }

    public func save(_ configuration: AppConfiguration) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(configuration)
        try AtomicPrivateFile.write(data, to: url)
    }
}

public struct AppSecrets: Codable, Equatable, Sendable {
    public var miotToken: String?

    public init(miotToken: String? = nil) {
        self.miotToken = miotToken
    }
}

public final class SecretsStore: @unchecked Sendable {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.url = appSupport
                .appendingPathComponent("DisplayRecoveryAutomation", isDirectory: true)
                .appendingPathComponent("secrets.json")
        }

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func readToken() -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: url),
              let secrets = try? decoder.decode(AppSecrets.self, from: data),
              let token = secrets.miotToken,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func saveToken(_ token: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveTokenLocked(token)
    }

    private func saveTokenLocked(_ token: String) throws {
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanToken.count == 32, cleanToken.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw ConfigurationStoreError.tokenInvalid("需要 32 位十六进制 Token")
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let secrets = AppSecrets(miotToken: token.trimmingCharacters(in: .whitespacesAndNewlines))
        let data = try encoder.encode(secrets)
        try AtomicPrivateFile.write(data, to: url)
    }

    public func deleteToken() throws {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// 独立的 Keychain 迁移方法：显式执行，成功落盘并校验后才清理 Keychain
    @discardableResult
    public func migrateFromKeychainExplicitly() throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let legacyToken = try KeychainStore().readToken(),
              !legacyToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let cleanToken = legacyToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanToken.count == 32, cleanToken.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw ConfigurationStoreError.tokenInvalid("Keychain 中的 Token 格式无效（非 32 位十六进制）")
        }

        try saveTokenLocked(cleanToken)

        // 读回验证落盘
        guard let verifiedData = try? Data(contentsOf: url),
              let verified = try? decoder.decode(AppSecrets.self, from: verifiedData),
              verified.miotToken == cleanToken else {
            throw ConfigurationStoreError.migrationFailed("写入本地 secrets.json 读回校验失败，已中止删除 Keychain")
        }

        // 导入不等于授权删除原凭据；保留 Keychain 中的原件。
        return cleanToken
    }
}

public enum KeychainStoreError: LocalizedError, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain 操作失败（\(status)）"
        case .invalidData:
            return "Keychain 数据格式无效"
        }
    }
}

public final class KeychainStore: @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "local.codex.display-recovery-automation",
        account: String = "miot-token"
    ) {
        self.service = service
        self.account = account
    }

    public func readToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return token
    }

    public func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    public func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }
}

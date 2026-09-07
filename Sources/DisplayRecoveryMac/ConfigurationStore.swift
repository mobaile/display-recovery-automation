import Foundation
import Security

import DisplayRecoveryCore

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var recovery: RecoveryConfiguration
    public var plug: PlugConfiguration

    public init(
        recovery: RecoveryConfiguration = RecoveryConfiguration(),
        plug: PlugConfiguration = PlugConfiguration()
    ) {
        self.recovery = recovery
        self.plug = plug
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

    public func load() -> AppConfiguration {
        guard let data = try? Data(contentsOf: url),
              let configuration = try? decoder.decode(AppConfiguration.self, from: data) else {
            return AppConfiguration()
        }
        return configuration
    }

    public func save(_ configuration: AppConfiguration) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: [.atomic])
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

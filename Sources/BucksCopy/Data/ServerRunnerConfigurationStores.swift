import Foundation
import Security

final class InMemoryServerRunnerConfigurationStore: ServerRunnerConfigurationStore {
    private var configuration: ServerRunnerConfiguration?

    func save(_ configuration: ServerRunnerConfiguration) throws {
        self.configuration = configuration
    }

    func load() throws -> ServerRunnerConfiguration? {
        configuration
    }

    func delete() throws {
        configuration = nil
    }
}

final class KeychainServerRunnerConfigurationStore: ServerRunnerConfigurationStore {
    private let service = "com.buckscopy.server.runner"
    private let account = "default"

    func save(_ configuration: ServerRunnerConfiguration) throws {
        guard let data = try? JSONEncoder().encode(configuration) else {
            throw KeychainCredentialStoreError.encodeFailed
        }

        let query = baseQuery()
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
    }

    func load() throws -> ServerRunnerConfiguration? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let configuration = try? JSONDecoder().decode(ServerRunnerConfiguration.self, from: data) else {
            throw KeychainCredentialStoreError.decodeFailed
        }
        return configuration
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

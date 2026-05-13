import Foundation
import Security

enum KeychainCredentialStoreError: Error {
    case encodeFailed
    case decodeFailed
    case unexpectedStatus(OSStatus)
}

final class KeychainCredentialStore: CredentialStore {
    private let service = "com.buckscopy.bitget.credentials"
    private let account = "default"

    func save(_ credential: APIKeyCredential) throws {
        guard let data = try? JSONEncoder().encode(StoredCredential(credential)) else {
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

    func load() throws -> APIKeyCredential? {
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
              let stored = try? JSONDecoder().decode(StoredCredential.self, from: data) else {
            throw KeychainCredentialStoreError.decodeFailed
        }
        return stored.credential
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

private struct StoredCredential: Codable {
    let apiKey: String
    let secretKey: String
    let passphrase: String

    init(_ credential: APIKeyCredential) {
        apiKey = credential.apiKey
        secretKey = credential.secretKey
        passphrase = credential.passphrase
    }

    var credential: APIKeyCredential {
        APIKeyCredential(apiKey: apiKey, secretKey: secretKey, passphrase: passphrase)
    }
}

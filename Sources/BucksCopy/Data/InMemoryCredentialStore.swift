import Foundation

final class InMemoryCredentialStore: CredentialStore {
    private var credential: APIKeyCredential?

    func save(_ credential: APIKeyCredential) throws {
        self.credential = credential
    }

    func load() throws -> APIKeyCredential? {
        credential
    }

    func delete() throws {
        credential = nil
    }
}

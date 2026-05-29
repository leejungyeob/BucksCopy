import XCTest
@testable import BucksCopy

final class CredentialTests: XCTestCase {
    func testCredentialRedactionDoesNotExposeRawSecretValues() throws {
        let credential = APIKeyCredential(
            apiKey: "abcd1234wxyz",
            secretKey: "very-secret",
            passphrase: "passphrase"
        )

        XCTAssertEqual(credential.redactedIdentifier, "abcd...wxyz")
        XCTAssertFalse(credential.redactedIdentifier.contains(credential.secretKey))
        XCTAssertFalse(credential.redactedIdentifier.contains(credential.passphrase))
    }

    func testInMemoryCredentialStoreRoundTripAndDelete() throws {
        let store = InMemoryCredentialStore()
        let credential = APIKeyCredential(
            apiKey: "key",
            secretKey: "secret",
            passphrase: "pass"
        )

        try store.save(credential)
        XCTAssertEqual(try store.load(), credential)

        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testServerRunnerConfigurationRedactsToken() {
        let configuration = ServerRunnerConfiguration(
            endpoint: "http://127.0.0.1:8787",
            authToken: "abcd1234efgh5678"
        )

        XCTAssertTrue(configuration.hasAuthToken)
        XCTAssertEqual(configuration.redactedAuthToken, "abcd...5678")
        XCTAssertFalse(configuration.redactedAuthToken?.contains("1234efgh") ?? true)
    }

    func testInMemoryServerRunnerConfigurationStoreRoundTripAndDelete() throws {
        let store = InMemoryServerRunnerConfigurationStore()
        let configuration = ServerRunnerConfiguration(
            endpoint: "http://127.0.0.1:8787",
            authToken: "token"
        )

        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)

        try store.delete()
        XCTAssertNil(try store.load())
    }
}

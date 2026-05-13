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
}

import XCTest
@testable import ZoneCaptureCore

final class SecretsTests: XCTestCase {
    func testFakeStoreRoundTrip() throws {
        let store = FakeSecretStore()
        try store.setSecret("sk-test-1", account: "OPENAI_API_KEY")
        XCTAssertEqual(try store.getSecret(account: "OPENAI_API_KEY"), "sk-test-1")
        try store.deleteSecret(account: "OPENAI_API_KEY")
        XCTAssertNil(try store.getSecret(account: "OPENAI_API_KEY"))
    }

    func testKeychainRoundTrip() throws {
        let service = "com.grokink.zonecapture.test.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service)
        try store.deleteSecret(account: "ACCT")
        try store.setSecret("value-1", account: "ACCT")
        XCTAssertEqual(try store.getSecret(account: "ACCT"), "value-1")
        try store.setSecret("value-2", account: "ACCT")
        XCTAssertEqual(try store.getSecret(account: "ACCT"), "value-2")
        try store.deleteSecret(account: "ACCT")
        XCTAssertNil(try store.getSecret(account: "ACCT"))
    }
}

final class FakeSecretStore: SecretStore {
    private var dict: [String: String] = [:]
    func setSecret(_ value: String, account: String) throws { dict[account] = value }
    func getSecret(account: String) throws -> String? { dict[account] }
    func deleteSecret(account: String) throws { dict.removeValue(forKey: account) }
}

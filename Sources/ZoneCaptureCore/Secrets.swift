import Foundation
import Security

public protocol SecretStore: AnyObject {
    func setSecret(_ value: String, account: String) throws
    func getSecret(account: String) throws -> String?
    func deleteSecret(account: String) throws
}

public enum SecretsError: Error, CustomStringConvertible {
    case unexpectedStatus(OSStatus, String)

    public var description: String {
        if case .unexpectedStatus(let s, let op) = self {
            return "keychain \(op) failed: OSStatus \(s)"
        }
        return "keychain error"
    }
}

/// Stores secrets in the user's macOS Keychain (login keychain). No CLI,
/// no third-party vault — replaces the `op` 1Password CLI for this app.
public final class KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "com.grokink.zonecapture") {
        self.service = service
    }

    public func setSecret(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretsError.unexpectedStatus(addStatus, "add")
            }
        } else if updateStatus != errSecSuccess {
            throw SecretsError.unexpectedStatus(updateStatus, "update")
        }
    }

    public func getSecret(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecretsError.unexpectedStatus(status, "get")
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteSecret(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw SecretsError.unexpectedStatus(status, "delete")
        }
    }
}

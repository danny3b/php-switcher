import Foundation
import Security

struct DatabaseCredentialAccount: Equatable, Hashable {
    let port: Int
    let user: String

    init?(port: String, user: String) {
        guard let number = Int(port), (1...65535).contains(number),
              !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.port = number
        self.user = user
    }

    var keychainAccount: String { "127.0.0.1:\(port)/\(user)" }
}

struct DatabaseCredential: Equatable {
    let account: DatabaseCredentialAccount
    let password: String
}

protocol DatabasePasswordStoring {
    func password(for account: DatabaseCredentialAccount) throws -> String?
    func save(_ credential: DatabaseCredential) throws
    func removePassword(for account: DatabaseCredentialAccount) throws
}

struct DatabaseKeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}

/// Use the local macOS login keychain, which supports the app's ad hoc signing.
/// Leave Keychain access control intact; never grant access to arbitrary apps.
struct DatabaseKeychain: DatabasePasswordStoring {
    private let service = "pl.daniel.php-switcher.mysql"

    private func query(for account: DatabaseCredentialAccount) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account.keychainAccount,
         kSecUseDataProtectionKeychain as String: false]
    }

    func password(for account: DatabaseCredentialAccount) throws -> String? {
        var query = query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DatabaseKeychainError(status: status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw DatabaseKeychainError(status: errSecDecode)
        }
        return password
    }

    func save(_ credential: DatabaseCredential) throws {
        let query = query(for: credential.account)
        let attributes = [kSecValueData as String: Data(credential.password.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = attributes[kSecValueData as String]
            item[kSecAttrLabel as String] = "DevŻbik MySQL — " + credential.account.keychainAccount
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw DatabaseKeychainError(status: status) }
    }

    func removePassword(for account: DatabaseCredentialAccount) throws {
        let status = SecItemDelete(query(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DatabaseKeychainError(status: status)
        }
    }
}

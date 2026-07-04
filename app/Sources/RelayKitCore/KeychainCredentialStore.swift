import Foundation
import Security

public enum KeychainCredentialStore {
    private static let account = "RelayKit"

    public static func save(value: String, service: String) throws {
        let trimmedService = service.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedService.isEmpty else {
            throw ProviderConfigError.invalid("Keychain item name is required.")
        }
        guard !value.isEmpty else {
            throw ProviderConfigError.invalid("Keychain credential value is required.")
        }
        let data = Data(value.utf8)
        let query = baseQuery(service: trimmedService)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw ProviderConfigError.invalid("Keychain update failed: \(status)")
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw ProviderConfigError.invalid("Keychain save failed: \(addStatus)")
        }
    }

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

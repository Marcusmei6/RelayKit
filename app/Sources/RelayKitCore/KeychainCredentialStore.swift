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

    public static func load(service: String) throws -> String {
        guard let value = try loadIfPresent(service: service) else {
            throw ProviderConfigError.invalid("Keychain credential unavailable.")
        }
        return value
    }

    public static func loadIfPresent(service: String) throws -> String? {
        let trimmedService = service.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedService.isEmpty else {
            throw ProviderConfigError.invalid("Keychain item name is required.")
        }
        var query = baseQuery(service: trimmedService, includeAccount: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        switch try lookup(query: query) {
        case .value(let value):
            return value
        case .missing:
            break
        }
        query = baseQuery(service: trimmedService, includeAccount: false)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        switch try lookup(query: query) {
        case .value(let value):
            return value
        case .missing:
            return nil
        }
    }

    public static func delete(service: String) throws {
        let trimmedService = service.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedService.isEmpty else {
            throw ProviderConfigError.invalid("Keychain item name is required.")
        }
        let status = SecItemDelete(baseQuery(service: trimmedService) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderConfigError.invalid("Keychain delete failed: \(status)")
        }
    }

    private enum LookupResult {
        case value(String)
        case missing
    }

    private static func lookup(query: [String: Any]) throws -> LookupResult {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .missing
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw ProviderConfigError.invalid("Keychain credential lookup failed: \(status)")
        }
        return .value(value)
    }

    private static func baseQuery(service: String, includeAccount: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if includeAccount {
            query[kSecAttrAccount as String] = account
        }
        return query
    }
}

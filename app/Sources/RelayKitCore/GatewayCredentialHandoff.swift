import Foundation

public enum GatewayCredentialHandoff {
    private static let payloadVersion = 1
    private static let maximumPayloadBytes = 1 << 20

    public static func encode(
        configData: Data,
        loadCredential: (String) throws -> String
    ) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: configData)
        guard let root = object as? [String: Any] else {
            throw ProviderConfigError.invalid("Provider config must be a JSON object.")
        }

        var references = Set<String>()
        if let providers = root["providers"] as? [[String: Any]] {
            for provider in providers {
                collectKeychainReference(from: provider["credential_ref"], into: &references)
            }
        }
        if let official = root["official_passthrough"] as? [String: Any] {
            collectKeychainReference(from: official["credential_ref"], into: &references)
        }

        var credentials: [String: String] = [:]
        for reference in references.sorted() {
            guard let value = try? loadCredential(reference), !value.isEmpty else {
                continue
            }
            credentials[reference] = value
        }

        let payload: [String: Any] = [
            "version": payloadVersion,
            "credentials": credentials,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count <= maximumPayloadBytes else {
            throw ProviderConfigError.invalid("Gateway credential handoff is too large.")
        }
        return data
    }

    private static func collectKeychainReference(from value: Any?, into references: inout Set<String>) {
        guard let reference = value as? [String: Any],
              reference["kind"] as? String == "keychain",
              let name = reference["value"] as? String else {
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            references.insert(trimmed)
        }
    }
}

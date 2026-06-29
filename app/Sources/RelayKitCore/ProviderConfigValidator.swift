import Foundation

public enum ProviderConfigError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}

public enum ProviderConfigValidator {
    public static func validate(_ json: Any) throws {
        try rejectCredentials(in: json)
        guard let root = json as? [String: Any],
              let providers = root["providers"] as? [[String: Any]],
              !providers.isEmpty else {
            throw ProviderConfigError.invalid("providers array is required")
        }
        for provider in providers {
            let id = provider["id"] as? String ?? ""
            let name = provider["name"] as? String ?? ""
            let baseURL = provider["base_url"] as? String ?? ""
            let apiFormat = provider["api_format"] as? String ?? ""
            guard !id.isEmpty, !name.isEmpty, !baseURL.isEmpty, !apiFormat.isEmpty else {
                throw ProviderConfigError.invalid("provider id, name, base_url, and api_format are required")
            }
            guard apiFormat == "openai_chat" || apiFormat == "anthropic_messages" else {
                throw ProviderConfigError.invalid("unsupported api_format: \(apiFormat)")
            }
            if let parts = URLComponents(string: baseURL),
               parts.user != nil || parts.password != nil || parts.query != nil || parts.fragment != nil {
                throw ProviderConfigError.invalid("base_url must not contain credentials or query values")
            }
            guard let models = provider["models"] as? [[String: Any]], !models.isEmpty else {
                throw ProviderConfigError.invalid("models array is required for provider \(id)")
            }
            for model in models {
                if (model["id"] as? String ?? "").isEmpty {
                    throw ProviderConfigError.invalid("model id is required for provider \(id)")
                }
            }
        }
    }

    private static func rejectCredentials(in value: Any) throws {
        let forbiddenKeys = Set(["api_key", "apikey", "token", "secret", "credential", "credentials", "authorization", "cookie", "password", "bearer_token", "access_token", "refresh_token"])
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if forbiddenKeys.contains(key.lowercased()) {
                    throw ProviderConfigError.invalid("credential field is not allowed: \(key)")
                }
                try rejectCredentials(in: child)
            }
        } else if let array = value as? [Any] {
            for child in array {
                try rejectCredentials(in: child)
            }
        } else if let text = value as? String {
            let lower = text.lowercased()
            let credentialMarkers = ["bearer ", "sk-", "api_key=", "token=", "access_token=", "refresh_token=", "password=", "secret=", "authorization="]
            if credentialMarkers.contains(where: lower.contains) {
                throw ProviderConfigError.invalid("credential-looking value is not allowed")
            }
        }
    }
}

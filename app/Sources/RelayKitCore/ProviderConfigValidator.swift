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
            if let authEnv = provider["auth_env"] as? String,
               !authEnv.isEmpty,
               !isEnvironmentVariableName(authEnv) {
                throw ProviderConfigError.invalid("auth_env must be an environment variable name")
            }
            if let credentialRef = provider["credential_ref"] {
                try validateCredentialRef(credentialRef)
            }
            if let capabilities = provider["capabilities"] {
                try validateCapabilities(capabilities)
            }
            if let routing = provider["routing"] {
                try validateRouting(routing)
            }
            if let catalog = provider["catalog"] {
                try validateCatalog(catalog)
            }
            guard let models = provider["models"] as? [[String: Any]], !models.isEmpty else {
                throw ProviderConfigError.invalid("models array is required for provider \(id)")
            }
            for model in models {
                if (model["id"] as? String ?? "").isEmpty {
                    throw ProviderConfigError.invalid("model id is required for provider \(id)")
                }
                if let upstreamModel = model["upstream_model"] as? String,
                   containsCredentialMarker(upstreamModel) {
                    throw ProviderConfigError.invalid("upstream_model must not contain credential-looking values")
                }
            }
        }
    }

    private static func isEnvironmentVariableName(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard let first = scalars.first,
              first.value == 95 || isASCIILetter(first) else {
            return false
        }
        return scalars.allSatisfy { $0.value == 95 || isASCIILetter($0) || isASCIIDigit($0) }
    }

    private static func validateCredentialRef(_ value: Any) throws {
        guard let ref = value as? [String: Any],
              let kind = ref["kind"] as? String,
              let refValue = ref["value"] as? String,
              !kind.isEmpty,
              !refValue.isEmpty else {
            throw ProviderConfigError.invalid("credential_ref kind and value are required")
        }
        if containsCredentialMarker(refValue) {
            throw ProviderConfigError.invalid("credential_ref must not contain credential-looking values")
        }
        if let header = ref["header"] as? String,
           !header.isEmpty,
           !isSafeHeaderName(header) {
            throw ProviderConfigError.invalid("credential_ref header must be a safe HTTP header name")
        }
        switch kind {
        case "env":
            if !isEnvironmentVariableName(refValue) {
                throw ProviderConfigError.invalid("credential_ref env value must be an environment variable name")
            }
        case "keychain":
            if !isSafeReferenceName(refValue) {
                throw ProviderConfigError.invalid("credential_ref keychain value must be a local item reference")
            }
        case "key_file":
            if !(refValue.hasPrefix("~/") || refValue.hasPrefix("/")) || refValue.contains("\n") || refValue.contains("\r") {
                throw ProviderConfigError.invalid("credential_ref key_file value must be an absolute or home-relative path")
            }
        default:
            throw ProviderConfigError.invalid("unsupported credential_ref kind: \(kind)")
        }
    }

    private static func validateCapabilities(_ value: Any) throws {
        guard let capabilities = value as? [String: Any] else {
            throw ProviderConfigError.invalid("capabilities must be an object")
        }
        let allowed = Set(["streaming", "tools", "usage", "reasoning"])
        for (key, child) in capabilities {
            if !allowed.contains(key) {
                throw ProviderConfigError.invalid("unsupported capability: \(key)")
            }
            if !(child is Bool) {
                throw ProviderConfigError.invalid("capability \(key) must be a boolean")
            }
        }
    }

    private static func validateRouting(_ value: Any) throws {
        guard let routing = value as? [String: Any] else {
            throw ProviderConfigError.invalid("routing must be an object")
        }
        if let source = routing["source"] as? String, !source.isEmpty, !isSafeSlug(source) {
            throw ProviderConfigError.invalid("routing source must be a public-safe slug")
        }
        if let prefix = routing["model_prefix"] as? String,
           !prefix.isEmpty,
           (!prefix.hasSuffix("/") || !isSafeSlug(String(prefix.dropLast()))) {
            throw ProviderConfigError.invalid("routing model_prefix must be a public-safe slug ending in /")
        }
        if let priority = routing["priority"], !(priority is Int) {
            throw ProviderConfigError.invalid("routing priority must be a number")
        }
        if let priority = routing["priority"] as? Int, priority < 0 {
            throw ProviderConfigError.invalid("routing priority must be non-negative")
        }
        if let status = routing["status"] as? String,
           !status.isEmpty,
           status != "enabled",
           status != "disabled" {
            throw ProviderConfigError.invalid("unsupported routing status: \(status)")
        }
        if let visible = routing["visible"], !(visible is Bool) {
            throw ProviderConfigError.invalid("routing visible must be a boolean")
        }
    }

    private static func validateCatalog(_ value: Any) throws {
        guard let catalog = value as? [String: Any] else {
            throw ProviderConfigError.invalid("catalog must be an object")
        }
        if let modelsURL = catalog["models_url"] as? String,
           !modelsURL.isEmpty {
            guard let parts = URLComponents(string: modelsURL),
                  parts.scheme == "http" || parts.scheme == "https",
                  parts.host != nil,
                  parts.user == nil,
                  parts.password == nil,
                  parts.query == nil,
                  parts.fragment == nil else {
                throw ProviderConfigError.invalid("catalog models_url must be an http(s) URL without credentials, query, or fragment")
            }
        }
        if let keyHeader = catalog["key_header"] as? String,
           !keyHeader.isEmpty,
           !isSafeReferenceName(keyHeader) {
            throw ProviderConfigError.invalid("catalog key_header must be a safe header reference")
        }
    }

    private static func isSafeSlug(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard let first = scalars.first,
              isASCIILowercaseLetter(first) else {
            return false
        }
        return scalars.allSatisfy { isASCIILowercaseLetter($0) || isASCIIDigit($0) || $0.value == 45 }
    }

    private static func isSafeReferenceName(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.contains("\n"),
              !value.contains("\r") else {
            return false
        }
        let allowed = CharacterSet.uppercaseLetters
            .union(.lowercaseLetters)
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "._:@/-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isSafeHeaderName(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        let allowed = CharacterSet.uppercaseLetters
            .union(.lowercaseLetters)
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
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
            if containsCredentialMarker(text) {
                throw ProviderConfigError.invalid("credential-looking value is not allowed")
            }
        }
    }

    private static func containsCredentialMarker(_ value: String) -> Bool {
        let lower = value.lowercased()
        let credentialMarkers = ["bearer ", "sk-", "api_key=", "token=", "access_token=", "refresh_token=", "password=", "secret=", "authorization="]
        return credentialMarkers.contains(where: lower.contains)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILowercaseLetter(scalar) || (scalar.value >= 65 && scalar.value <= 90)
    }

    private static func isASCIILowercaseLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 97 && scalar.value <= 122
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }
}

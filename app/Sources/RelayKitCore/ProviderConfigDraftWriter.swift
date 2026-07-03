import Foundation

public struct ProviderConfigDraft {
    public let providerId: String
    public let providerName: String
    public let baseURL: String
    public let apiFormat: String
    public let authEnv: String
    public let modelId: String
    public let modelDisplayName: String
    public let contextWindow: Int?

    public init(
        providerId: String,
        providerName: String,
        baseURL: String,
        apiFormat: String,
        authEnv: String,
        modelId: String,
        modelDisplayName: String,
        contextWindow: Int?
    ) {
        self.providerId = providerId
        self.providerName = providerName
        self.baseURL = baseURL
        self.apiFormat = apiFormat
        self.authEnv = authEnv
        self.modelId = modelId
        self.modelDisplayName = modelDisplayName
        self.contextWindow = contextWindow
    }
}

public enum ProviderConfigDraftWriter {
    public static func addProvider(_ draft: ProviderConfigDraft, to existingData: Data) throws -> Data {
        let json = try JSONSerialization.jsonObject(with: existingData)
        guard var root = json as? [String: Any],
              var providers = root["providers"] as? [[String: Any]] else {
            throw ProviderConfigError.invalid("providers array is required")
        }

        var model: [String: Any] = ["id": clean(draft.modelId)]
        if !clean(draft.modelDisplayName).isEmpty {
            model["display_name"] = clean(draft.modelDisplayName)
        }
        if let contextWindow = draft.contextWindow, contextWindow > 0 {
            model["context_window"] = contextWindow
        }

        var provider: [String: Any] = [
            "id": clean(draft.providerId),
            "name": clean(draft.providerName),
            "base_url": clean(draft.baseURL),
            "api_format": clean(draft.apiFormat),
            "models": [model],
        ]
        if !clean(draft.authEnv).isEmpty {
            provider["credential_ref"] = [
                "kind": "env",
                "value": clean(draft.authEnv),
            ]
        }

        providers.append(provider)
        root["providers"] = providers
        try ProviderConfigValidator.validate(root)
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

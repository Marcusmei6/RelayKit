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
    public let source: String
    public let modelPrefix: String
    public let modelsURL: String
    public let credentialKind: String
    public let credentialReference: String
    public let keyHeader: String
    public let upstreamModel: String
    public let streaming: Bool?
    public let tools: Bool?
    public let usage: Bool?
    public let reasoning: Bool?
    public let priority: Int?
    public let visible: Bool?

    public init(
        providerId: String,
        providerName: String,
        baseURL: String,
        apiFormat: String,
        authEnv: String,
        modelId: String,
        modelDisplayName: String,
        contextWindow: Int?,
        source: String = "",
        modelPrefix: String = "",
        modelsURL: String = "",
        credentialKind: String = "env",
        credentialReference: String = "",
        keyHeader: String = "",
        upstreamModel: String = "",
        streaming: Bool? = nil,
        tools: Bool? = nil,
        usage: Bool? = nil,
        reasoning: Bool? = nil,
        priority: Int? = nil,
        visible: Bool? = nil
    ) {
        self.providerId = providerId
        self.providerName = providerName
        self.baseURL = baseURL
        self.apiFormat = apiFormat
        self.authEnv = authEnv
        self.modelId = modelId
        self.modelDisplayName = modelDisplayName
        self.contextWindow = contextWindow
        self.source = source
        self.modelPrefix = modelPrefix
        self.modelsURL = modelsURL
        self.credentialKind = credentialKind
        self.credentialReference = credentialReference
        self.keyHeader = keyHeader
        self.upstreamModel = upstreamModel
        self.streaming = streaming
        self.tools = tools
        self.usage = usage
        self.reasoning = reasoning
        self.priority = priority
        self.visible = visible
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
        if !clean(draft.upstreamModel).isEmpty {
            model["upstream_model"] = clean(draft.upstreamModel)
        }

        var provider: [String: Any] = [
            "id": clean(draft.providerId),
            "name": clean(draft.providerName),
            "base_url": clean(draft.baseURL),
            "api_format": clean(draft.apiFormat),
            "models": [model],
        ]
        let credentialReference = clean(draft.credentialReference).isEmpty ? clean(draft.authEnv) : clean(draft.credentialReference)
        let credentialKind = clean(draft.credentialKind).isEmpty ? "env" : clean(draft.credentialKind)
        let metadataOnlyCredential = !credentialReference.isEmpty && credentialKind != "env"
        if !credentialReference.isEmpty {
            provider["credential_ref"] = [
                "kind": credentialKind,
                "value": credentialReference,
            ]
        }
        var capabilities: [String: Any] = [:]
        if let streaming = draft.streaming {
            capabilities["streaming"] = streaming
        }
        if let tools = draft.tools {
            capabilities["tools"] = tools
        }
        if let usage = draft.usage {
            capabilities["usage"] = usage
        }
        if let reasoning = draft.reasoning {
            capabilities["reasoning"] = reasoning
        }
        if !capabilities.isEmpty {
            provider["capabilities"] = capabilities
        }
        var routing: [String: Any] = [:]
        if !clean(draft.source).isEmpty {
            routing["source"] = clean(draft.source)
        }
        if !clean(draft.modelPrefix).isEmpty {
            routing["model_prefix"] = clean(draft.modelPrefix)
        }
        if let priority = draft.priority {
            routing["priority"] = priority
        }
        if let visible = draft.visible {
            routing["visible"] = metadataOnlyCredential ? false : visible
        }
        if !routing.isEmpty {
            routing["status"] = metadataOnlyCredential ? "disabled" : "enabled"
            provider["routing"] = routing
        }
        var catalog: [String: Any] = [:]
        if !clean(draft.modelsURL).isEmpty {
            catalog["models_url"] = clean(draft.modelsURL)
        }
        if !clean(draft.keyHeader).isEmpty {
            catalog["key_header"] = clean(draft.keyHeader)
        }
        if !catalog.isEmpty {
            provider["catalog"] = catalog
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

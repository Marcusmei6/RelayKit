import Foundation

public enum CodexModelCatalogError: LocalizedError {
    case invalidOfficialCatalog
    case invalidGatewayModels
    case missingOfficialTemplate
    case duplicateGatewayModel(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOfficialCatalog:
            "Codex Desktop returned an invalid bundled model catalog."
        case .invalidGatewayModels:
            "RelayKit gateway returned invalid model metadata."
        case .missingOfficialTemplate:
            "Codex Desktop bundled catalog has no model template."
        case .duplicateGatewayModel(let id):
            "RelayKit gateway returned duplicate healthy model \(id)."
        }
    }
}

public enum CodexModelCatalog {
    public static func merge(officialCatalog: Data, gatewayModels: Data, includeOfficialModels: Bool) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: officialCatalog) as? [String: Any],
              let official = root["models"] as? [[String: Any]],
              let template = official.first else {
            throw CodexModelCatalogError.invalidOfficialCatalog
        }
        guard let gatewayRoot = try JSONSerialization.jsonObject(with: gatewayModels) as? [String: Any],
              let models = gatewayRoot["data"] as? [[String: Any]] else {
            throw CodexModelCatalogError.invalidGatewayModels
        }

        let officialIDs = includeOfficialModels ? Set(official.compactMap { $0["slug"] as? String }) : []
        let hiddenIDs = Set(
            ((gatewayRoot["model_health"] as? [String: Any])?["hidden"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String }
        )
        var addedIDs = Set<String>()
        var merged = includeOfficialModels ? official : []
        for gatewayModel in models {
            guard let id = clean(gatewayModel["id"] as? String), !hiddenIDs.contains(id) else { continue }
            guard addedIDs.insert(id).inserted else {
                throw CodexModelCatalogError.duplicateGatewayModel(id)
            }
            guard !officialIDs.contains(id) else { continue }
            var model = template
            model["slug"] = id
            model["display_name"] = clean(gatewayModel["display_name"] as? String) ?? id
            model["description"] = "RelayKit local route."
            model["source"] = "relaykit"
            model["owned_by"] = clean(gatewayModel["owned_by"] as? String) ?? "relaykit"
            model["visibility"] = "list"
            model["priority"] = 100
            model["upstream_model"] = clean(gatewayModel["upstream_model"] as? String) ?? id
            model["protocol"] = "responses"
            model["transport"] = "local_relaykit"
            model["status"] = "ready"
            model["object"] = "model"
            model["supported_in_api"] = true
            model["upgrade"] = NSNull()
            model["availability_nux"] = NSNull()
            model["additional_speed_tiers"] = []
            model["service_tiers"] = []
            merged.append(model)
        }
        root["models"] = merged
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

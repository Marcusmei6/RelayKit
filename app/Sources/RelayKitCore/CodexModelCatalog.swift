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
    public static func gatewayModelsNeedRetry(_ data: Data) throws -> Bool {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let health = root["model_health"] as? [String: Any],
              let probed = health["probed"] as? Bool,
              let unhealthy = health["unhealthy"] as? Int else {
            throw CodexModelCatalogError.invalidGatewayModels
        }
        return !probed || unhealthy > 0
    }

    public static func merge(officialCatalog: Data, gatewayModels: Data, includeOfficialModels: Bool) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: officialCatalog) as? [String: Any],
              let official = root["models"] as? [[String: Any]],
              !official.isEmpty else {
            throw CodexModelCatalogError.invalidOfficialCatalog
        }
        guard let gatewayRoot = try JSONSerialization.jsonObject(with: gatewayModels) as? [String: Any],
              let models = gatewayRoot["data"] as? [[String: Any]] else {
            throw CodexModelCatalogError.invalidGatewayModels
        }

        let compatibleOfficial = official.map { source in
            var model = source
            if model["supports_reasoning_summaries"] == nil {
                model["supports_reasoning_summaries"] = true
            }
            return model
        }
        let template = compatibleOfficial[0]
        let officialIDs = includeOfficialModels ? Set(official.compactMap { $0["slug"] as? String }) : []
        let health = GatewayHealthProjection(root: gatewayRoot["model_health"] as? [String: Any])
        var addedIDs = Set<String>()
        var merged = includeOfficialModels ? compatibleOfficial : []
        for gatewayModel in models {
            guard let id = clean(gatewayModel["id"] as? String), !health.hidden.contains(id) else { continue }
            guard addedIDs.insert(id).inserted else {
                throw CodexModelCatalogError.duplicateGatewayModel(id)
            }
            guard !officialIDs.contains(id) else { continue }
            var model = template
            model["slug"] = id
            model["display_name"] = clean(gatewayModel["display_name"] as? String) ?? id
            let availability = health.availability(for: id)
            model["description"] = availability.description
            model["source"] = "relaykit"
            model["owned_by"] = clean(gatewayModel["owned_by"] as? String) ?? "relaykit"
            model["visibility"] = "list"
            model["priority"] = 100
            model["upstream_model"] = clean(gatewayModel["upstream_model"] as? String) ?? id
            model["protocol"] = "responses"
            model["transport"] = "local_relaykit"
            model["status"] = "ready"
            model["relaykit_availability"] = availability.value
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

private struct GatewayHealthProjection {
    struct Availability {
        let value: String
        let description: String
    }

    let configured: Set<String>
    let discovered: Set<String>
    let routeReachable: Set<String>
    let temporarilyUnavailable: Set<String>
    let hidden: Set<String>
    let nonStaleLastKnownGood: Set<String>

    init(root: [String: Any]?) {
        configured = Self.ids(root?["configured"])
        discovered = Self.ids(root?["discovered"])
        routeReachable = Self.ids(root?["route_reachable"])
        temporarilyUnavailable = Self.ids(root?["temporarily_unavailable"])
        hidden = Self.ids(root?["hidden"])
        nonStaleLastKnownGood = Set(
            (root?["last_known_good"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let id = entry["id"] as? String,
                      !(entry["stale"] as? Bool ?? true),
                      entry["timestamp"] as? String != nil,
                      entry["config_fingerprint"] as? String != nil else {
                    return nil
                }
                return id
            }
        )
    }

    func availability(for id: String) -> Availability {
        if routeReachable.contains(id) {
            return Availability(value: "route_reachable", description: "RelayKit local route.")
        }
        if nonStaleLastKnownGood.contains(id) {
            return Availability(value: "last_known_good", description: "RelayKit local route; last known good availability.")
        }
        if temporarilyUnavailable.contains(id) {
            return Availability(value: "temporarily_unavailable", description: "RelayKit local route; availability is temporarily unavailable.")
        }
        if discovered.contains(id) {
            return Availability(value: "configured", description: "RelayKit local route; reachability is not verified.")
        }
        if configured.contains(id) {
            return Availability(value: "configured", description: "RelayKit local route; availability is not verified.")
        }
        return Availability(value: "route_reachable", description: "RelayKit local route.")
    }

    private static func ids(_ value: Any?) -> Set<String> {
        Set((value as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
    }
}

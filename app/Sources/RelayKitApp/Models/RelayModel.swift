struct RelayModel: Identifiable, Decodable {
    let id: String
    let ownedBy: String

    private enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
    }
}

struct ModelListResponse: Decodable {
    let data: [RelayModel]
    let modelHealth: GatewayModelHealth?

    private enum CodingKeys: String, CodingKey {
        case data
        case modelHealth = "model_health"
    }
}

struct GatewayModelHealth: Decodable, Equatable {
    let probed: Bool
    let healthy: Int
    let unhealthy: Int
    let hidden: [GatewayHiddenModel]

    static let empty = GatewayModelHealth(probed: false, healthy: 0, unhealthy: 0, hidden: [])

    init(probed: Bool, healthy: Int, unhealthy: Int, hidden: [GatewayHiddenModel]) {
        self.probed = probed
        self.healthy = healthy
        self.unhealthy = unhealthy
        self.hidden = hidden
    }
}

struct GatewayHiddenModel: Identifiable, Decodable, Equatable {
    let id: String
    let reason: String
}

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
}

struct UsageSummary: Identifiable, Decodable {
    let day: String
    let providerId: String
    let model: String
    let requests: Int
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let durationMs: Int

    var id: String {
        "\(day)-\(providerId)-\(model)"
    }

    private enum CodingKeys: String, CodingKey {
        case day
        case providerId = "provider_id"
        case model
        case requests
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case durationMs = "duration_ms"
    }
}

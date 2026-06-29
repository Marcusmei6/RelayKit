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

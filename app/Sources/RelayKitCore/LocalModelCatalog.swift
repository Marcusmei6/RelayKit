import Foundation

public struct LocalModelCatalog: Sendable {
    public struct Model: Decodable, Identifiable, Sendable {
        public let id: String
        public let source: String
        public let displayName: String?
        public let contextWindow: Int?

        private enum CodingKeys: String, CodingKey {
            case id
            case source
            case ownedBy = "owned_by"
            case displayName = "display_name"
            case contextWindow = "context_window"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            let decodedSource = try container.decodeIfPresent(String.self, forKey: .source)
            let decodedOwner = try container.decodeIfPresent(String.self, forKey: .ownedBy)
            source = decodedSource ?? decodedOwner ?? "unknown"
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        }
    }

    public struct SourceGroup: Equatable, Sendable {
        public let source: String
        public let count: Int
        public let publicLabel: String
        public let modelIds: [String]

        public var firstModelId: String {
            modelIds.first ?? ""
        }
    }

    private struct Response: Decodable {
        let data: [Model]
    }

    public let models: [Model]
    public let sourceGroups: [SourceGroup]

    public var modelCount: Int {
        models.count
    }

    public var redactedEvidence: [String: Any] {
        [
            "model_count": modelCount,
            "source_group_count": sourceGroups.count,
            "model_ids_redacted": true,
            "sources_redacted": true,
        ]
    }

    public static func decode(_ data: Data) throws -> LocalModelCatalog {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return LocalModelCatalog(models: response.data)
    }

    public init(models: [Model]) {
        self.models = models
        let grouped = Dictionary(grouping: models) { $0.source }
        sourceGroups = grouped
            .map { (source: $0.key, models: $0.value) }
            .sorted { lhs, rhs in lhs.source < rhs.source }
            .enumerated()
            .map { index, group in
                SourceGroup(
                    source: group.source,
                    count: group.models.count,
                    publicLabel: "source-\(index + 1)",
                    modelIds: group.models.map(\.id).sorted()
                )
            }
    }
}

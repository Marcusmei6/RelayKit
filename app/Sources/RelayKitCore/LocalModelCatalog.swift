import Foundation

public struct LocalModelCatalog: Sendable {
    public struct Model: Decodable, Identifiable, Sendable {
        public let id: String
        public let source: String
        public let displayName: String?
        public let apiProtocol: String?
        public let transport: String?
        public let bridgeHost: String?
        public let upstreamModel: String?
        public let status: String?
        public let visibility: String?
        public let contextWindow: Int?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case source
            case ownedBy = "owned_by"
            case apiProtocol = "protocol"
            case transport
            case bridgeHost = "bridge_host"
            case upstreamModel = "upstream_model"
            case displayName = "display_name"
            case status
            case visibility
            case contextWindow = "context_window"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            let decodedSource = try container.decodeIfPresent(String.self, forKey: .source)
            let decodedOwner = try container.decodeIfPresent(String.self, forKey: .ownedBy)
            source = decodedSource ?? decodedOwner ?? "unknown"
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
                ?? container.decodeIfPresent(String.self, forKey: .name)
            apiProtocol = try container.decodeIfPresent(String.self, forKey: .apiProtocol)
            transport = try container.decodeIfPresent(String.self, forKey: .transport)
            bridgeHost = try container.decodeIfPresent(String.self, forKey: .bridgeHost)
            upstreamModel = try container.decodeIfPresent(String.self, forKey: .upstreamModel)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
            contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        }
    }

    public struct ModelSummary: Equatable, Sendable {
        public let id: String
        public let displayName: String?
        public let upstreamModel: String?
        public let contextWindow: Int?
        public let status: String?
        public let visibility: String?
    }

    public struct SourceGroup: Equatable, Sendable {
        public let source: String
        public let count: Int
        public let publicLabel: String
        public let modelIds: [String]
        public let modelSummaries: [ModelSummary]
        public let protocolSummary: String
        public let transportSummary: String
        public let bridgeHost: String?

        public var firstModelId: String {
            modelIds.first ?? ""
        }

        public var executionBaseURL: String {
            guard let bridgeHost, !bridgeHost.isEmpty else {
                return ""
            }
            return "http://\(bridgeHost)/v1"
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
                let protocols = Set(group.models.compactMap { LocalModelCatalog.clean($0.apiProtocol) }.filter { !$0.isEmpty })
                let transports = Set(group.models.compactMap { LocalModelCatalog.clean($0.transport) }.filter { !$0.isEmpty })
                let bridgeHosts = Set(group.models.compactMap { LocalModelCatalog.clean($0.bridgeHost) }.filter { !$0.isEmpty })
                return SourceGroup(
                    source: group.source,
                    count: group.models.count,
                    publicLabel: "source-\(index + 1)",
                    modelIds: group.models.map(\.id).sorted(),
                    modelSummaries: group.models
                        .sorted { $0.id < $1.id }
                        .map {
                            ModelSummary(
                                id: $0.id,
                                displayName: $0.displayName,
                                upstreamModel: $0.upstreamModel,
                                contextWindow: $0.contextWindow,
                                status: $0.status,
                                visibility: $0.visibility
                            )
                        },
                    protocolSummary: LocalModelCatalog.summarize(protocols),
                    transportSummary: LocalModelCatalog.summarize(transports),
                    bridgeHost: bridgeHosts.count == 1 ? bridgeHosts.first : nil
                )
            }
    }

    private static func clean(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func summarize(_ values: Set<String>) -> String {
        if values.count == 1, let value = values.first {
            return value
        }
        return values.isEmpty ? "unknown" : "mixed"
    }
}

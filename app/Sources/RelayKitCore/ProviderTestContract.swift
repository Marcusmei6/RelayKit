import Foundation

public struct ProviderTestRequest: Codable, Equatable, Sendable {
    public let providerID: String
    public let modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }

    private enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case modelID = "model_id"
    }
}

public enum ProviderTestStatus: String, Decodable, Equatable, Sendable {
    case ok
    case failed
}

public enum ProviderTestFailureType: String, Decodable, Equatable, Sendable {
    case authFailed = "auth_failed"
    case networkFailed = "network_failed"
    case responsesUnavailable = "responses_unavailable"
    case unknownModel = "unknown_model"
    case unsupportedProviderFormat = "unsupported_provider_format"
}

public enum ProviderTestConnectionKind: String, Equatable, Sendable {
    case connected
    case authFailed = "auth_failed"
    case networkFailed = "network_failed"
    case responsesUnavailable = "responses_unavailable"
}

public struct ProviderTestResponse: Decodable, Equatable, Sendable {
    public struct ErrorDetail: Decodable, Equatable, Sendable {
        public let type: ProviderTestFailureType
    }

    public let providerID: String
    public let modelID: String
    public let status: ProviderTestStatus
    public let error: ErrorDetail?

    public var connectionKind: ProviderTestConnectionKind {
        guard status == .failed else {
            return .connected
        }
        switch error?.type {
        case .authFailed:
            return .authFailed
        case .networkFailed:
            return .networkFailed
        case .responsesUnavailable, .unknownModel, .unsupportedProviderFormat, nil:
            return .responsesUnavailable
        }
    }

    private enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case modelID = "model_id"
        case status
        case error
    }
}

public enum ProviderTestSaveAction: Equatable, Sendable {
    case add
    case update(originalProviderID: String)

    public static func resolve(providerID: String, persistedProviderIDs: Set<String>) -> ProviderTestSaveAction {
        persistedProviderIDs.contains(providerID)
            ? .update(originalProviderID: providerID)
            : .add
    }
}

import Foundation
import RelayKitCore

enum GatewayClientError: LocalizedError {
    case badResponse
    case gatewayUnavailable

    var errorDescription: String? {
        switch self {
        case .badResponse:
            "RelayKit gateway returned an invalid response"
        case .gatewayUnavailable:
            "RelayKit gateway did not start"
        }
    }
}

struct GatewayClient {
    let baseURL: URL

    init(endpoint: RelayKitRuntimeEndpoint) {
        baseURL = endpoint.httpBaseURL
    }

    func health() async throws -> String {
        let (_, response) = try await URLSession.shared.data(from: baseURL.appending(path: "healthz"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return "ok"
    }

    func models() async throws -> [RelayModel] {
        try await modelList().data
    }

    func modelList() async throws -> ModelListResponse {
        try JSONDecoder().decode(ModelListResponse.self, from: try await modelListData())
    }

    func modelListData() async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: "v1/models"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func testProvider(providerID: String, modelID: String) async throws -> ProviderTestResponse {
        var request = URLRequest(url: baseURL.appending(path: "_relaykit/provider-test"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ProviderTestRequest(providerID: providerID, modelID: modelID)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayClientError.badResponse
        }
        if let result = try? JSONDecoder().decode(ProviderTestResponse.self, from: data) {
            return result
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        throw GatewayClientError.badResponse
    }
}

import Foundation

struct GatewayClient {
    var baseURL = URL(string: "http://127.0.0.1:19777")!

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
        let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: "v1/models"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ModelListResponse.self, from: data)
    }
}

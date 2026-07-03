import Foundation
import RelayKitCore

struct LocalCatalogClient {
    var modelsURL = URL(string: "http://127.0.0.1:18787/v1/models")!

    func catalog() async throws -> LocalModelCatalog {
        let (data, response) = try await URLSession.shared.data(from: modelsURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try LocalModelCatalog.decode(data)
    }
}

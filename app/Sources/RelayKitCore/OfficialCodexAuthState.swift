import Foundation

public enum OfficialCodexAuthState {
    private struct AuthFile: Decodable {
        let authMode: String
        let tokens: Tokens

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case tokens
        }
    }

    private struct Tokens: Decodable {
        let accessToken: String
        let accountID: String
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
            case refreshToken = "refresh_token"
        }
    }

    public static func isConnected(data: Data) -> Bool {
        guard let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
              auth.authMode == "chatgpt" else {
            return false
        }
        return [auth.tokens.accessToken, auth.tokens.accountID, auth.tokens.refreshToken]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

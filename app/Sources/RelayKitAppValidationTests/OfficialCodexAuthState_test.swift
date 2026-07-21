import Foundation
import RelayKitCore

func expectOfficialCodexAuthState() throws {
    let valid = Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"RELAYKIT_FAKE_SENTINEL_ACCESS","account_id":"RELAYKIT_FAKE_SENTINEL_ACCOUNT","refresh_token":"RELAYKIT_FAKE_SENTINEL_REFRESH"}}"#.utf8)
    if !OfficialCodexAuthState.isConnected(data: valid) {
        fatalError("complete isolated Codex auth must be connected")
    }
    for invalid in [
        Data(#"{"auth_mode":"api_key","tokens":{"access_token":"RELAYKIT_FAKE_SENTINEL_ACCESS","account_id":"RELAYKIT_FAKE_SENTINEL_ACCOUNT","refresh_token":"RELAYKIT_FAKE_SENTINEL_REFRESH"}}"#.utf8),
        Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"","account_id":"RELAYKIT_FAKE_SENTINEL_ACCOUNT","refresh_token":"RELAYKIT_FAKE_SENTINEL_REFRESH"}}"#.utf8),
        Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"RELAYKIT_FAKE_SENTINEL_ACCESS","account_id":"","refresh_token":"RELAYKIT_FAKE_SENTINEL_REFRESH"}}"#.utf8),
        Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"RELAYKIT_FAKE_SENTINEL_ACCESS","account_id":"RELAYKIT_FAKE_SENTINEL_ACCOUNT","refresh_token":""}}"#.utf8),
        Data("not-json".utf8),
    ] {
        if OfficialCodexAuthState.isConnected(data: invalid) {
            fatalError("incomplete isolated Codex auth must not be connected")
        }
    }
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("relaykit-official-auth-state-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let authURL = temporaryRoot.appendingPathComponent("auth.json")
    if OfficialCodexAuthState.isConnected(at: authURL) {
        fatalError("missing isolated Codex auth file must not be connected")
    }
    try valid.write(to: authURL)
    if !OfficialCodexAuthState.isConnected(at: authURL) {
        fatalError("ordinary launch must synchronously read a complete isolated Codex auth file")
    }
}

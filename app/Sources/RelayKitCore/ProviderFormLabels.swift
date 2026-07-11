import Foundation

public enum ProviderFormLabels {
    public struct UpstreamProtocolOption: Equatable, Sendable {
        public let id: String
        public let label: String
        public let isEnabled: Bool

        public init(id: String, label: String, isEnabled: Bool) {
            self.id = id
            self.label = label
            self.isEnabled = isEnabled
        }
    }

    public static let codexRoute = "Codex route: Responses"
    public static let savedKeyMask = "••••••••••••"
    public static let upstreamProtocolOptions = [
        UpstreamProtocolOption(id: "anthropic_messages", label: "Anthropic Messages", isEnabled: true),
        UpstreamProtocolOption(id: "openai_chat", label: "OpenAI Chat Completions", isEnabled: true),
        UpstreamProtocolOption(id: "openai_responses", label: "OpenAI Responses (planned)", isEnabled: false),
    ]
    public static let ordinaryAdvancedLabels = [
        "Upstream protocol",
        "Custom models URL",
        "Custom auth header",
        "Upstream model override",
    ]
    public static let hiddenOrdinaryAdvancedLabels = [
        "Provider ID",
        "Keychain ref",
        "Source",
        "Display prefix",
        "Context window",
        "Raw protocol string",
        "Display name",
    ]
    public static let officialChannelStatusLabels = [
        "Not connected",
        "Device login pending",
        "Login available",
        "Route verified",
    ]
    public static let officialChannelActionLabels = [
        "Connect Official",
        "Check status",
        "Disconnect",
    ]
    public static let gatewayStoppedGuidance = "Gateway is stopped · test a provider connection or start it in Settings"

    public static func providerAddedMessage(storedKey: Bool, backupCreated: Bool) -> String {
        let base = storedKey ? "Stored Keychain credential; added provider" : "Added provider"
        return backupCreated ? base + "; backup created" : base
    }

    public static func providerUpdatedMessage(backupCreated: Bool) -> String {
        backupCreated ? "Saved provider; backup created" : "Saved provider"
    }

    public static func providerConfigSavedMessage(backupCreated: Bool) -> String {
        backupCreated ? "Saved provider config; backup created" : "Saved provider config"
    }

    public static func upstreamProtocol(apiFormat: String) -> String {
        apiFormat == "anthropic_messages" ? "Upstream: Anthropic" : "Upstream: OpenAI Chat"
    }

    public static func apiKeyStatus(hasReference: Bool, credentialKind: String) -> String {
        guard hasReference else {
            return "No API key saved"
        }
        if credentialKind.isEmpty || credentialKind == "keychain" {
            return "API key saved in Keychain"
        }
        return "Credential reference already configured"
    }

    public static func apiKeyPlaceholder(hasReference: Bool) -> String {
        "Paste API key"
    }

    public static func apiKeyReplaceButtonVisible(hasReference: Bool) -> Bool {
        false
    }

    public static func apiKeyEyeLabel(showingKey: Bool) -> String {
        showingKey ? "Hide API key" : "Show API key"
    }

    public static let keyUnavailableStatus = "Key unavailable, paste a new key"

    public static func sanitizedOfficialAuthURL(from output: String) -> String {
        let clean = output
            .replacingOccurrences(of: #"\x1B\]8;;.*?(\u0007|\x1B\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"%1B(?:%5B[0-9;]*m)?"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\u001B", with: "")
            .replacingOccurrences(of: "\\u{001B}", with: "")
            .filter { !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
        let pattern = #"https://[^\s<>"']+"#
        guard let range = clean.range(of: pattern, options: .regularExpression) else { return "" }
        let candidate = clean[range].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}'\""))
        guard let url = URL(string: String(candidate)),
              url.scheme == "https",
              url.host == "auth.openai.com",
              url.path == "/codex/device" else {
            return ""
        }
        return "https://auth.openai.com/codex/device"
    }

    public static func officialStatusTitle(status: String) -> String {
        switch status {
        case "device login pending": return "Device login pending"
        case "login available": return "Login available"
        case "route verified": return "Route verified"
        default: return "Not connected"
        }
    }

    public static func officialRowSubtitle(status: String) -> String {
        switch status {
        case "route verified": return "已连接 · Route verified"
        case "login available": return "已连接 · Login available"
        case "device login pending": return "认证中 · Device login"
        default: return "未接入 · Device login"
        }
    }

    public static func officialIsConnected(status: String) -> Bool {
        status == "login available" || status == "route verified"
    }

    public static func officialPrimaryActionLabel(status: String) -> String {
        switch status {
        case "route verified": return "Route verified"
        case "login available": return "Logged in"
        default: return officialChannelActionLabels[0]
        }
    }

    public static func officialPrimaryActionDisabled(status: String, inProgress: Bool) -> Bool {
        inProgress || officialIsConnected(status: status)
    }

    public static func connectionStatusLabel(kind: String, listedCount: Int, reachableCount: Int, unavailableCount: Int, latencyMS: Int?) -> String {
        let latency = latencyMS.map { " · \($0) ms" } ?? ""
        switch kind {
        case "connected":
            return "List reachable · \(listedCount) listed · \(reachableCount) reachable · \(unavailableCount) unavailable\(latency)"
        case "reachable":
            return "Reachable\(latency)"
        case "auth_failed":
            return "Authentication failed · check API key"
        case "model_list_unavailable":
            return "Model list unavailable · check models URL or model ID\(latency)"
        case "network_failed":
            return "Network failed · check API base URL"
        default:
            return "Not tested"
        }
    }

    public static func providerHealthSummary(saved: Int, available: Int, hidden: Int) -> String {
        "\(saved) saved / \(available) available / \(hidden) hidden"
    }

    public static func providerHiddenReason(modelId: String, reason: String) -> String {
        "\(modelId) · \(reason)"
    }

    public static func providerConnectionKind(
        httpStatus: Int?,
        contentType: String = "",
        bodyPrefix: String = "",
        modelCount: Int = 0,
        networkFailed: Bool = false
    ) -> String {
        if networkFailed || httpStatus == nil {
            return "network_failed"
        }
        if httpStatus == 401 || httpStatus == 403 {
            return "auth_failed"
        }
        let lowerContentType = contentType.lowercased()
        let looksHTML = lowerContentType.contains("text/html")
            || bodyPrefix.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
        if (200..<300).contains(httpStatus ?? 0), !looksHTML, modelCount > 0 {
            return "connected"
        }
        return "model_list_unavailable"
    }
}

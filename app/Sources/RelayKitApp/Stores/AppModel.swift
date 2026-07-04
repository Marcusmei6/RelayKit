import Foundation
import RelayKitCore

@MainActor
final class AppModel: ObservableObject {
    @Published var providerConfigPath: String {
        didSet {
            UserDefaults.standard.set(providerConfigPath, forKey: "providerConfigPath")
            refreshConfiguredProviders()
        }
    }
    @Published var codexTargetPath: String {
        didSet {
            UserDefaults.standard.set(codexTargetPath, forKey: "codexTargetPath")
            refreshCodexConnectionStatus()
        }
    }
    @Published var gatewayBinaryPath = RelayKitPaths.gatewayBinaryPath()
    @Published var usageLogPath = AppModel.defaultUsageLogPath()
    @Published var codexSourcePath = RelayKitPaths.codexConfigSourcePath()
    @Published var codexConnectionStatus = "target not set"
    @Published var gatewayStatus = "stopped"
    @Published var models: [RelayModel] = []
    @Published var localCatalog: LocalModelCatalog?
    @Published var localCatalogStatus = "not scanned"
    @Published var localCatalogAuthState = "credential reference needed"
    @Published var usageSummaries: [UsageSummary] = []
    @Published var providerConfigText = ""
    @Published var configuredProviders: [ConfiguredProviderEntry] = []
    @Published var message = ""
    @Published var appearanceMode: AppAppearanceMode {
        didSet {
            settingsStore.appearanceMode = appearanceMode
        }
    }
    @Published var launchAtLoginRequested: Bool {
        didSet {
            settingsStore.launchAtLoginRequested = launchAtLoginRequested
        }
    }
    @Published var launchAtLoginStatus = "not registered"

    private let gateway = GatewayProcess()
    private let client = GatewayClient()
    private let catalogClient = LocalCatalogClient()
    private let settingsStore = AppSettingsStore()
    private let loginItemService = LoginItemService()

    init() {
        let savedPath = UserDefaults.standard.string(forKey: "providerConfigPath")
        providerConfigPath = savedPath == "../examples/providers.example.json" ? RelayKitPaths.providerConfigPath() : savedPath ?? RelayKitPaths.providerConfigPath()
        codexTargetPath = UserDefaults.standard.string(forKey: "codexTargetPath") ?? ""
        appearanceMode = settingsStore.appearanceMode
        launchAtLoginRequested = settingsStore.launchAtLoginRequested
        refreshCodexConnectionStatus()
        refreshLaunchAtLoginStatus()
        refreshConfiguredProviders()
    }

    func startGateway() {
        do {
            try gateway.start(binaryPath: gatewayBinaryPath, configPath: providerConfigPath)
            gatewayStatus = "running"
            message = "Gateway started on 127.0.0.1:19777"
        } catch {
            gatewayStatus = "error"
            message = error.localizedDescription
        }
    }

    func stopGateway() {
        gateway.stop()
        gatewayStatus = "stopped"
        message = "Gateway stopped"
    }

    func restartGateway() {
        stopGateway()
        startGateway()
    }

    func refreshHealth() async {
        do {
            gatewayStatus = try await client.health()
            message = "Gateway health ok"
        } catch {
            gatewayStatus = gateway.isRunning ? "starting/error" : "stopped"
            message = error.localizedDescription
        }
    }

    func refreshModels() async {
        do {
            models = try await client.models()
            message = "Loaded \(models.count) model(s)"
        } catch {
            message = error.localizedDescription
        }
    }

    func refreshLocalCatalog() async {
        do {
            localCatalog = try await catalogClient.catalog()
            let modelCount = localCatalog?.modelCount ?? 0
            let sourceCount = localCatalog?.sourceGroups.count ?? 0
            localCatalogStatus = "catalog available: \(modelCount) model(s), \(sourceCount) source(s)"
            localCatalogAuthState = "auth required for execution"
            message = "Loaded local catalog from agent-local-gateway"
        } catch {
            localCatalog = nil
            localCatalogStatus = "agent-local-gateway unavailable"
            localCatalogAuthState = "catalog unavailable"
            message = error.localizedDescription
        }
    }

    func loadProviderConfig() {
        do {
            let text = try String(contentsOfFile: providerConfigPath, encoding: .utf8)
            let json = try JSONSerialization.jsonObject(with: Data(text.utf8))
            try ProviderConfigValidator.validate(json)
            providerConfigText = text
            refreshConfiguredProviders(from: Data(text.utf8))
            message = "Loaded provider config"
        } catch {
            message = error.localizedDescription
        }
    }

    func saveProviderConfig() {
        do {
            let data = Data(providerConfigText.utf8)
            let json = try JSONSerialization.jsonObject(with: data)
            try ProviderConfigValidator.validate(json)
            let pretty = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            var backupPath: String?
            if FileManager.default.fileExists(atPath: providerConfigPath) {
                let backup = providerConfigPath + ".bak." + UUID().uuidString
                try FileManager.default.copyItem(atPath: providerConfigPath, toPath: backup)
                backupPath = backup
            }
            try pretty.write(to: URL(fileURLWithPath: providerConfigPath), options: .atomic)
            providerConfigText = String(data: pretty, encoding: .utf8) ?? providerConfigText
            refreshConfiguredProviders(from: pretty)
            if let backupPath {
                message = "Saved provider config; backup: \(backupPath)"
            } else {
                message = "Saved provider config"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func addProvider(_ draft: ProviderConfigDraft, keychainCredential: String = "") -> Bool {
        do {
            let existing: Data
            if FileManager.default.fileExists(atPath: providerConfigPath) {
                existing = try Data(contentsOf: URL(fileURLWithPath: providerConfigPath))
            } else if providerConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing = Data(#"{"providers":[]}"#.utf8)
            } else {
                existing = Data(providerConfigText.utf8)
            }
            let pretty = try ProviderConfigDraftWriter.addProvider(draft, to: existing)
            if draft.credentialKind == "keychain" && !keychainCredential.isEmpty {
                try KeychainCredentialStore.save(value: keychainCredential, service: draft.credentialReference)
            }
            var backupPath: String?
            if FileManager.default.fileExists(atPath: providerConfigPath) {
                let backup = providerConfigPath + ".bak." + UUID().uuidString
                try FileManager.default.copyItem(atPath: providerConfigPath, toPath: backup)
                backupPath = backup
            }
            try pretty.write(to: URL(fileURLWithPath: providerConfigPath), options: .atomic)
            providerConfigText = String(data: pretty, encoding: .utf8) ?? ""
            refreshConfiguredProviders(from: pretty)
            if let backupPath {
                message = draft.credentialKind == "keychain" && !keychainCredential.isEmpty
                    ? "Stored Keychain credential; added provider; backup: \(backupPath)"
                    : "Added provider; backup: \(backupPath)"
            } else {
                message = draft.credentialKind == "keychain" && !keychainCredential.isEmpty
                    ? "Stored Keychain credential; added provider"
                    : "Added provider"
            }
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func updateProvider(_ originalProviderId: String, draft: ProviderConfigDraft, keychainCredential: String = "") -> Bool {
        do {
            let existing = try providerConfigData()
            let json = try JSONSerialization.jsonObject(with: existing)
            guard var root = json as? [String: Any],
                  let providers = root["providers"] as? [[String: Any]] else {
                throw ProviderConfigError.invalid("providers array is required")
            }
            root["providers"] = providers.filter { ($0["id"] as? String ?? "") != originalProviderId }
            let filtered = try JSONSerialization.data(withJSONObject: root)
            let pretty = try ProviderConfigDraftWriter.addProvider(draft, to: filtered)
            if draft.credentialKind == "keychain" && !keychainCredential.isEmpty {
                try KeychainCredentialStore.save(value: keychainCredential, service: draft.credentialReference)
            }
            var backupPath: String?
            if FileManager.default.fileExists(atPath: providerConfigPath) {
                let backup = providerConfigPath + ".bak." + UUID().uuidString
                try FileManager.default.copyItem(atPath: providerConfigPath, toPath: backup)
                backupPath = backup
            }
            try pretty.write(to: URL(fileURLWithPath: providerConfigPath), options: .atomic)
            providerConfigText = String(data: pretty, encoding: .utf8) ?? ""
            refreshConfiguredProviders(from: pretty)
            message = backupPath.map { "Saved provider; backup: \($0)" } ?? "Saved provider"
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func refreshUsageSummary() async {
        do {
            let output = try gateway.summarizeUsage(binaryPath: gatewayBinaryPath, usageLogPath: usageLogPath)
            usageSummaries = try JSONDecoder().decode([UsageSummary].self, from: Data(output.utf8))
            message = "Loaded \(usageSummaries.count) usage row(s)"
        } catch {
            message = error.localizedDescription
        }
    }

    func activateCodexConfig() async {
        guard !codexTargetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "Codex target path is required"
            return
        }
        do {
            let output = try gateway.activateCodexConfig(
                binaryPath: gatewayBinaryPath,
                source: codexSourcePath,
                target: codexTargetPath
            )
            message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            refreshCodexConnectionStatus()
        } catch {
            message = error.localizedDescription
        }
    }

    var codexConnectionIsConfigured: Bool {
        codexConnectionStatus == "configured"
    }

    var gatewayIsRunning: Bool {
        gateway.isRunning
    }

    var gatewayProcessIdentifier: Int32? {
        gateway.processIdentifier
    }

    func refreshCodexConnectionStatus() {
        let path = codexTargetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            codexConnectionStatus = "target not set"
            return
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            codexConnectionStatus = "target missing"
            return
        }
        if text.contains("base_url = \"http://127.0.0.1:19777/v1\"") &&
            text.contains("wire_api = \"responses\"") {
            codexConnectionStatus = "configured"
        } else {
            codexConnectionStatus = "not RelayKit"
        }
    }

    func setAppearanceMode(_ mode: AppAppearanceMode) {
        appearanceMode = mode
        message = "Appearance set to \(mode.rawValue)"
    }

    func refreshLaunchAtLoginStatus() {
        let status = loginItemService.status
        launchAtLoginStatus = status.rawValue
        launchAtLoginRequested = status.isRequested
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItemService.setEnabled(enabled)
            refreshLaunchAtLoginStatus()
            message = enabled ? "Launch at login requested" : "Launch at login disabled"
        } catch {
            refreshLaunchAtLoginStatus()
            message = "Launch at login failed: \(error.localizedDescription)"
        }
    }

    private static func defaultUsageLogPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RelayKit/usage.jsonl")
            .path
    }

    private func providerConfigData() throws -> Data {
        if FileManager.default.fileExists(atPath: providerConfigPath) {
            return try Data(contentsOf: URL(fileURLWithPath: providerConfigPath))
        }
        if !providerConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Data(providerConfigText.utf8)
        }
        return Data(#"{"providers":[]}"#.utf8)
    }

    private func refreshConfiguredProviders() {
        guard let data = try? providerConfigData() else {
            configuredProviders = []
            return
        }
        refreshConfiguredProviders(from: data)
    }

    private func refreshConfiguredProviders(from data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let providers = root["providers"] as? [[String: Any]] else {
            configuredProviders = []
            return
        }
        configuredProviders = providers.compactMap(ConfiguredProviderEntry.init(provider:))
    }

}

struct ConfiguredProviderEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let baseURL: String
    let apiFormat: String
    let credentialKind: String
    let credentialReference: String
    let keyHeader: String
    let modelId: String
    let upstreamModel: String
    let modelsURL: String
    let source: String
    let modelPrefix: String
    let contextWindow: Int?

    init?(provider: [String: Any]) {
        guard let id = provider["id"] as? String,
              let name = provider["name"] as? String,
              let baseURL = provider["base_url"] as? String,
              let apiFormat = provider["api_format"] as? String,
              let models = provider["models"] as? [[String: Any]],
              let model = models.first,
              let modelId = model["id"] as? String else {
            return nil
        }
        let credentialRef = provider["credential_ref"] as? [String: Any]
        let catalog = provider["catalog"] as? [String: Any]
        let routing = provider["routing"] as? [String: Any]
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiFormat = apiFormat
        self.credentialKind = credentialRef?["kind"] as? String ?? "env"
        self.credentialReference = credentialRef?["value"] as? String ?? provider["auth_env"] as? String ?? ""
        self.keyHeader = credentialRef?["header"] as? String ?? catalog?["key_header"] as? String ?? "Authorization"
        self.modelId = modelId
        self.upstreamModel = model["upstream_model"] as? String ?? ""
        self.modelsURL = catalog?["models_url"] as? String ?? ""
        self.source = routing?["source"] as? String ?? ""
        self.modelPrefix = routing?["model_prefix"] as? String ?? ""
        self.contextWindow = model["context_window"] as? Int
    }
}

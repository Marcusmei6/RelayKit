import Foundation
import RelayKitCore

@MainActor
final class AppModel: ObservableObject {
    @Published var providerConfigPath: String {
        didSet {
            UserDefaults.standard.set(providerConfigPath, forKey: "providerConfigPath")
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
            if let backupPath {
                message = "Saved provider config; backup: \(backupPath)"
            } else {
                message = "Saved provider config"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func addProvider(_ draft: ProviderConfigDraft) -> Bool {
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
            var backupPath: String?
            if FileManager.default.fileExists(atPath: providerConfigPath) {
                let backup = providerConfigPath + ".bak." + UUID().uuidString
                try FileManager.default.copyItem(atPath: providerConfigPath, toPath: backup)
                backupPath = backup
            }
            try pretty.write(to: URL(fileURLWithPath: providerConfigPath), options: .atomic)
            providerConfigText = String(data: pretty, encoding: .utf8) ?? ""
            if let backupPath {
                message = "Added provider; backup: \(backupPath)"
            } else {
                message = "Added provider"
            }
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

}

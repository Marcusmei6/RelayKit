import Foundation
import RelayKitCore

@MainActor
final class AppModel: ObservableObject {
    @Published var providerConfigPath: String {
        didSet {
            UserDefaults.standard.set(providerConfigPath, forKey: "providerConfigPath")
        }
    }
    @Published var gatewayBinaryPath = RelayKitPaths.gatewayBinaryPath()
    @Published var usageLogPath = AppModel.defaultUsageLogPath()
    @Published var codexSourcePath = "../examples/codex.config.example.toml"
    @Published var codexTargetPath = ""
    @Published var gatewayStatus = "stopped"
    @Published var models: [RelayModel] = []
    @Published var usageSummaries: [UsageSummary] = []
    @Published var providerConfigText = ""
    @Published var message = ""

    private let gateway = GatewayProcess()
    private let client = GatewayClient()

    init() {
        providerConfigPath = UserDefaults.standard.string(forKey: "providerConfigPath") ?? "../examples/providers.example.json"
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
                let backup = providerConfigPath + ".bak." + String(Int(Date().timeIntervalSince1970))
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
        } catch {
            message = error.localizedDescription
        }
    }

    private static func defaultUsageLogPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RelayKit/usage.jsonl")
            .path
    }

}

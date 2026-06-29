import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var providerConfigPath = "../examples/providers.example.json"
    @Published var gatewayBinaryPath = "../gateway/bin/relaykit-gateway"
    @Published var codexSourcePath = "../examples/codex.config.example.toml"
    @Published var codexTargetPath = ""
    @Published var gatewayStatus = "stopped"
    @Published var models: [RelayModel] = []
    @Published var message = ""

    private let gateway = GatewayProcess()
    private let client = GatewayClient()

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
}

import Foundation
import RelayKitCore

@MainActor
enum BundledGatewayVerifier {
    static func run(arguments: [String]) -> Int32 {
        let configPath = value(after: "--provider-config", in: arguments) ?? RelayKitPaths.exampleProviderConfigPath()
        var gateway: GatewayProcess?
        do {
            let endpoint = try RelayKitRuntimeEndpoint.resolve()
            let managedGateway = GatewayProcess(endpoint: endpoint)
            gateway = managedGateway
            let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let credentialHandoff = try GatewayCredentialHandoff.encode(configData: configData) { reference in
                try KeychainCredentialStore.load(service: reference)
            }
            try managedGateway.start(
                binaryPath: RelayKitPaths.gatewayBinaryPath(),
                configPath: configPath,
                credentialHandoff: credentialHandoff
            )
            defer { managedGateway.stop() }
            let health = try fetch(endpoint.httpBaseURL.appending(path: "healthz"))
            guard String(data: health, encoding: .utf8)?.contains(#""status":"ok""#) == true else {
                throw GatewayProcessError.commandFailed("health response missing ok status")
            }
            let models = try fetch(endpoint.codexBaseURL.appending(path: "models"))
            guard String(data: models, encoding: .utf8)?.contains(#""data""#) == true else {
                throw GatewayProcessError.commandFailed("models response missing data")
            }
            print("Bundled gateway verification passed")
            return 0
        } catch {
            gateway?.stop()
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func fetch(_ url: URL) throws -> Data {
        return try Data(contentsOf: url)
    }
}

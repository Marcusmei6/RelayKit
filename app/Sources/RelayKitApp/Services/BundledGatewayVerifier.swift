import Foundation
import RelayKitCore

enum BundledGatewayVerifier {
    static func run(arguments: [String]) -> Int32 {
        let gateway = GatewayProcess()
        let configPath = value(after: "--provider-config", in: arguments) ?? RelayKitPaths.exampleProviderConfigPath()
        do {
            let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let credentialHandoff = try GatewayCredentialHandoff.encode(configData: configData) { reference in
                try KeychainCredentialStore.load(service: reference)
            }
            try gateway.start(
                binaryPath: RelayKitPaths.gatewayBinaryPath(),
                configPath: configPath,
                credentialHandoff: credentialHandoff
            )
            defer { gateway.stop() }
            let health = try fetch("http://127.0.0.1:19777/healthz")
            guard String(data: health, encoding: .utf8)?.contains(#""status":"ok""#) == true else {
                throw GatewayProcessError.commandFailed("health response missing ok status")
            }
            let models = try fetch("http://127.0.0.1:19777/v1/models")
            guard String(data: models, encoding: .utf8)?.contains(#""data""#) == true else {
                throw GatewayProcessError.commandFailed("models response missing data")
            }
            print("Bundled gateway verification passed")
            return 0
        } catch {
            gateway.stop()
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

    private static func fetch(_ url: String) throws -> Data {
        guard let url = URL(string: url) else {
            throw GatewayProcessError.commandFailed("invalid URL: \(url)")
        }
        return try Data(contentsOf: url)
    }
}

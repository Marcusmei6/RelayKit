import Foundation

public enum RelayKitPaths {
    public static func gatewayBinaryPath(bundle: Bundle = .main) -> String {
        let bundled = bundle.bundleURL
            .appendingPathComponent("Contents/MacOS/relay")
            .path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return "../gateway/bin/relay"
    }

    public static func providerConfigPath(bundle: Bundle = .main) -> String {
        userProviderConfigPath()
    }

    public static func resolvedProviderConfigPath(savedPath: String?, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String {
        guard let savedPath, !savedPath.isEmpty else {
            return providerConfigPath()
        }
        if savedPath == exampleProviderConfigPath() || savedPath == "../examples/providers.example.json" {
            return providerConfigPath()
        }
        if isRelayKitTemporaryProviderConfigPath(savedPath) {
            return providerConfigPath()
        }
        if isRelayKitGeneratedProviderConfigPath(savedPath) {
            return providerConfigPath()
        }
        if savedPath.hasPrefix("/tmp/") && !fileExists(savedPath) {
            return providerConfigPath()
        }
        return savedPath
    }

    public static func recoveredStaleTemporaryProviderConfig(savedPath: String?, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Bool {
        guard let savedPath else {
            return false
        }
        return resolvedProviderConfigPath(savedPath: savedPath, fileExists: fileExists) != savedPath
    }

    private static func isRelayKitTemporaryProviderConfigPath(_ path: String) -> Bool {
        path.hasPrefix("/tmp/relaykit-") || path.hasPrefix("/private/tmp/relaykit-")
    }

    private static func isRelayKitGeneratedProviderConfigPath(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        for index in components.indices where components[index] == "RelayKit" {
            if index + 1 < components.count, components[index + 1] == "dist" {
                return true
            }
        }
        for index in components.indices where components[index] == "Application Support" {
            if index + 2 < components.count,
               components[index + 1] == "RelayKit",
               components[index + 2] == "DesktopProof" {
                return true
            }
        }
        return false
    }

    public static func userProviderConfigPath() -> String {
        applicationSupportDirectory()
            .appendingPathComponent("providers.json")
            .path
    }

    public static func gatewayRuntimeConfigPath() -> String {
        applicationSupportDirectory()
            .appendingPathComponent("gateway-runtime.json")
            .path
    }

    public static func codexCatalogPath() -> String {
        applicationSupportDirectory()
            .appendingPathComponent("codex-model-catalog.json")
            .path
    }

    public static func codexConfigStatePath() -> String {
        applicationSupportDirectory()
            .appendingPathComponent("codex-config-state.json")
            .path
    }

    public static func defaultCodexConfigPath(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        homeDirectory.appendingPathComponent(".codex/config.toml").path
    }

    public static func applicationSupportDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/RelayKit", isDirectory: true)
            .standardizedFileURL
    }

    public static func officialProofRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let relayKitRoot = homeDirectory
            .appendingPathComponent("Library/Application Support/RelayKit", isDirectory: true)
            .standardizedFileURL
        if let override = environment["RELAYKIT_OFFICIAL_PROOF_ROOT"],
           (override as NSString).isAbsolutePath {
            let candidate = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            if candidate.path.hasPrefix(relayKitRoot.path + "/") {
                return candidate.path
            }
        }
        return relayKitRoot.appendingPathComponent("OfficialProof", isDirectory: true).path
    }

    public static func officialCodexHomePath() -> String {
        URL(fileURLWithPath: officialProofRoot())
            .appendingPathComponent("codex-home", isDirectory: true)
            .path
    }

    public static func officialCredentialRefPath() -> String {
        URL(fileURLWithPath: officialProofRoot())
            .appendingPathComponent("official-credential.json")
            .path
    }

    public static func officialRouteEvidencePath() -> String {
        URL(fileURLWithPath: officialProofRoot())
            .appendingPathComponent("evidence.json")
            .path
    }

    public static func officialHomePath() -> String {
        URL(fileURLWithPath: officialProofRoot())
            .appendingPathComponent("home", isDirectory: true)
            .path
    }

    public static func exampleProviderConfigPath(bundle: Bundle = .main) -> String {
        let bundled = bundle.bundleURL
            .appendingPathComponent("Contents/Resources/providers.example.json")
            .path
        if FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return "../examples/providers.example.json"
    }

    public static func codexConfigSourcePath(bundle: Bundle = .main) -> String {
        let bundled = bundle.bundleURL
            .appendingPathComponent("Contents/Resources/codex.config.example.toml")
            .path
        if FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return "../examples/codex.config.example.toml"
    }
}

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

    public static func userProviderConfigPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RelayKit/providers.json")
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

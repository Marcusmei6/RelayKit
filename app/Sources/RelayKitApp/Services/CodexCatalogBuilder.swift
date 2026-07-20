import AppKit
import Foundation
import RelayKitCore

enum CodexCatalogBuilder {
    struct Catalog {
        let data: Data
        let binaryPath: String
    }

    static func catalog(accountProjection: Bool) throws -> Catalog {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            throw CodexCatalogBuilderError.desktopUnavailable
        }
        let binary = appURL.appendingPathComponent("Contents/Resources/codex")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw CodexCatalogBuilderError.bundledCLIUnavailable
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = binary
        process.arguments = accountProjection ? ["debug", "models"] : ["debug", "models", "--bundled"]
        if accountProjection {
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = RelayKitPaths.officialHomePath()
            environment["CODEX_HOME"] = RelayKitPaths.officialCodexHomePath()
            environment["CFFIXED_USER_HOME"] = RelayKitPaths.officialHomePath()
            process.environment = environment
        }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CodexCatalogBuilderError.commandFailed
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]],
              !models.isEmpty else {
            throw CodexCatalogBuilderError.invalidCatalog
        }
        return Catalog(data: data, binaryPath: binary.path)
    }
}

private enum CodexCatalogBuilderError: LocalizedError {
    case desktopUnavailable
    case bundledCLIUnavailable
    case commandFailed
    case invalidCatalog

    var errorDescription: String? {
        switch self {
        case .desktopUnavailable:
            "Codex Desktop is required to build the RelayKit model catalog."
        case .bundledCLIUnavailable:
            "Codex Desktop bundled CLI is unavailable; reinstall or update Codex Desktop."
        case .commandFailed:
            "Codex Desktop could not provide its bundled model catalog."
        case .invalidCatalog:
            "Codex Desktop returned an invalid bundled model catalog."
        }
    }
}

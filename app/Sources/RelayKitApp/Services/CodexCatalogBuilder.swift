import AppKit
import Foundation
import RelayKitCore

enum CodexCatalogBuilder {
    struct Catalog {
        let data: Data
        let binaryPath: String
    }

    static func catalog(accountProjection: Bool) throws -> Catalog {
        try catalog(accountProjection: accountProjection, binary: resolveBinary())
    }

    static func catalog(accountProjection: Bool, binary: URL) throws -> Catalog {
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

    static func resolveBinary() throws -> URL {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["RELAYKIT_CODEX_BINARY"] {
            candidates.append(override)
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates.append(appURL.appendingPathComponent("Contents/Resources/codex").path)
        }
        candidates.append(NSHomeDirectory() + "/.local/bin/codex")
        candidates.append("/opt/homebrew/bin/codex")
        candidates.append("/usr/local/bin/codex")
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            guard candidate.hasPrefix("/"), !candidate.contains("\n"),
                  FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            return URL(fileURLWithPath: candidate)
        }
        throw CodexCatalogBuilderError.desktopUnavailable
    }
}

private enum CodexCatalogBuilderError: LocalizedError {
    case desktopUnavailable
    case commandFailed
    case invalidCatalog

    var errorDescription: String? {
        switch self {
        case .desktopUnavailable:
            "Codex Desktop or an installed Codex CLI is required to build the RelayKit model catalog."
        case .commandFailed:
            "Codex CLI could not provide its bundled model catalog."
        case .invalidCatalog:
            "Codex CLI returned an invalid bundled model catalog."
        }
    }
}

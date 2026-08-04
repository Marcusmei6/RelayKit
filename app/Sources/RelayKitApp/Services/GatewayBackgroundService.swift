import Foundation
import ServiceManagement

@MainActor
struct GatewayBackgroundService {
    static let plistName = "dev.relaykit.gateway.plist"

    private var embeddedPlistURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(Self.plistName)
    }

    func ensureRegisteredIfPackaged() throws -> Bool {
        guard FileManager.default.fileExists(atPath: embeddedPlistURL.path) else {
            return false
        }
        let service = SMAppService.agent(plistName: Self.plistName)
        switch service.status {
        case .enabled:
            return true
        case .notRegistered:
            try service.register()
            guard service.status == .enabled else {
                throw GatewayProcessError.commandFailed("RelayKit background gateway requires approval in System Settings > General > Login Items.")
            }
            return true
        case .requiresApproval:
            throw GatewayProcessError.commandFailed("RelayKit background gateway requires approval in System Settings > General > Login Items.")
        case .notFound:
            throw GatewayProcessError.commandFailed("RelayKit background gateway is missing from this app package.")
        @unknown default:
            throw GatewayProcessError.commandFailed("RelayKit background gateway status is unavailable.")
        }
    }
}

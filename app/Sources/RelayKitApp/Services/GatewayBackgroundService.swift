import Foundation
import RelayKitCore
import ServiceManagement

enum GatewayBackgroundRecovery: Equatable {
    case requiresApproval
}

@MainActor
protocol GatewayBackgroundServiceProviding {
    func ensureRegisteredIfPackaged() throws -> Bool
    func openLoginItemsSettings()
}

@MainActor
struct GatewayBackgroundService: GatewayBackgroundServiceProviding {
    static let plistName = "dev.relaykit.gateway.plist"

    private var embeddedPlistURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(Self.plistName)
    }

    func ensureRegisteredIfPackaged() throws -> Bool {
        guard FileManager.default.fileExists(atPath: embeddedPlistURL.path) else {
            guard Bundle.main.bundleURL.pathExtension != "app" else {
                throw GatewayBackgroundRegistrationError.notFound
            }
            return false
        }

        let registration = SMAppServiceRegistration(service: SMAppService.agent(plistName: Self.plistName))
        try GatewayBackgroundRegistrationCoordinator(registration).ensureEnabled()
        return true
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

private struct SMAppServiceRegistration: GatewayBackgroundRegistration {
    let service: SMAppService

    var status: GatewayBackgroundStatus {
        switch service.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unavailable
        }
    }

    func register() throws {
        try service.register()
    }
}

import Foundation
import ServiceManagement

@MainActor
struct LoginItemService {
    enum Status: String {
        case enabled
        case requiresApproval = "requires approval"
        case notRegistered = "not registered"
        case notFound = "not found"
        case unavailable

        var isRequested: Bool {
            switch self {
            case .enabled, .requiresApproval:
                return true
            case .notRegistered, .notFound, .unavailable:
                return false
            }
        }
    }

    var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

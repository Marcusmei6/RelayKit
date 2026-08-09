import Foundation

public enum GatewayBackgroundStatus: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unavailable
}

public protocol GatewayBackgroundRegistration {
    var status: GatewayBackgroundStatus { get }
    func register() throws
}

public enum GatewayBackgroundRegistrationError: Error, LocalizedError, Equatable {
    case requiresApproval
    case notFound
    case unavailable
    case persistentlyNotRegistered

    public var errorDescription: String? {
        switch self {
        case .requiresApproval:
            return "RelayKit background gateway requires approval in System Settings > General > Login Items."
        case .notFound:
            return "RelayKit background gateway is missing from this app package."
        case .unavailable:
            return "RelayKit background gateway status is unavailable."
        case .persistentlyNotRegistered:
            return "RelayKit background gateway could not be registered."
        }
    }
}

public struct GatewayBackgroundRegistrationCoordinator {
    private let registration: any GatewayBackgroundRegistration

    public init(_ registration: any GatewayBackgroundRegistration) {
        self.registration = registration
    }

    public func ensureEnabled() throws {
        switch registration.status {
        case .enabled:
            return
        case .requiresApproval:
            throw GatewayBackgroundRegistrationError.requiresApproval
        case .notFound:
            throw GatewayBackgroundRegistrationError.notFound
        case .unavailable:
            throw GatewayBackgroundRegistrationError.unavailable
        case .notRegistered:
            do {
                try registration.register()
            } catch {
                if registration.status == .requiresApproval {
                    throw GatewayBackgroundRegistrationError.requiresApproval
                }
                throw error
            }

            switch registration.status {
            case .enabled:
                return
            case .requiresApproval:
                throw GatewayBackgroundRegistrationError.requiresApproval
            case .notFound:
                throw GatewayBackgroundRegistrationError.notFound
            case .unavailable:
                throw GatewayBackgroundRegistrationError.unavailable
            case .notRegistered:
                throw GatewayBackgroundRegistrationError.persistentlyNotRegistered
            }
        }
    }
}

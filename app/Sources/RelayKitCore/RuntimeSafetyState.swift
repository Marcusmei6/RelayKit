import Foundation

public enum RuntimeSafetyState: String, Equatable {
    case protected = "Protected"
    case recovering = "Recovering"
    case atRisk = "At risk"
    case disabled = "Disabled"
}

public enum RuntimeSafetyEvent {
    case startupManagedRouteHealthy
    case startupManagedRouteUnhealthy
    case managedRouteHealthFailed
    case helperExited
    case helperRestartSucceeded
    case helperRestartFailed
    case managedFieldsDisabled(helperIsRunning: Bool)
    case managedFieldsCouldNotBeRestored(helperIsRunning: Bool)
    case intentionalShutdown
}

public struct RuntimeSafetyTransition: Equatable {
    public let state: RuntimeSafetyState
    public let restartHelper: Bool
    public let disableManagedFields: Bool
    public let stopHelper: Bool

    public init(state: RuntimeSafetyState, restartHelper: Bool = false, disableManagedFields: Bool = false, stopHelper: Bool = false) {
        self.state = state
        self.restartHelper = restartHelper
        self.disableManagedFields = disableManagedFields
        self.stopHelper = stopHelper
    }
}

public enum RuntimeSafetyReducer {
    public static func transition(from state: RuntimeSafetyState, event: RuntimeSafetyEvent) -> RuntimeSafetyTransition {
        switch event {
        case .startupManagedRouteHealthy:
            RuntimeSafetyTransition(state: .protected)
        case .startupManagedRouteUnhealthy, .managedRouteHealthFailed, .helperExited:
            RuntimeSafetyTransition(state: .recovering, restartHelper: true)
        case .helperRestartSucceeded:
            RuntimeSafetyTransition(state: .protected)
        case .helperRestartFailed:
            RuntimeSafetyTransition(state: .recovering, disableManagedFields: true)
        case .managedFieldsDisabled(let helperIsRunning):
            RuntimeSafetyTransition(state: .disabled, stopHelper: helperIsRunning)
        case .managedFieldsCouldNotBeRestored:
            RuntimeSafetyTransition(state: .atRisk)
        case .intentionalShutdown:
            RuntimeSafetyTransition(state: state)
        }
    }
}

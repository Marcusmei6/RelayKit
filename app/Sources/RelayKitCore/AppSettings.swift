import Foundation

public enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public init(storedValue: String?) {
        self = storedValue.flatMap(AppAppearanceMode.init(rawValue:)) ?? .system
    }
}

public struct AppSettingsStore {
    public static let appearanceModeKey = "appearanceMode"
    public static let launchAtLoginRequestedKey = "launchAtLoginRequested"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var appearanceMode: AppAppearanceMode {
        get { AppAppearanceMode(storedValue: defaults.string(forKey: Self.appearanceModeKey)) }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.appearanceModeKey) }
    }

    public var launchAtLoginRequested: Bool {
        get { defaults.bool(forKey: Self.launchAtLoginRequestedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.launchAtLoginRequestedKey) }
    }
}

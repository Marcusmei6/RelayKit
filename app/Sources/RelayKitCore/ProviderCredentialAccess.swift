import Foundation

public protocol ProviderCredentialAccess {
    func load(service: String) throws -> String
    func loadIfPresent(service: String) throws -> String?
    func save(value: String, service: String) throws
    func delete(service: String) throws
}

public struct KeychainProviderCredentialAccess: ProviderCredentialAccess {
    public init() {}

    public func load(service: String) throws -> String {
        try KeychainCredentialStore.load(service: service)
    }

    public func loadIfPresent(service: String) throws -> String? {
        try KeychainCredentialStore.loadIfPresent(service: service)
    }

    public func save(value: String, service: String) throws {
        try KeychainCredentialStore.save(value: value, service: service)
    }

    public func delete(service: String) throws {
        try KeychainCredentialStore.delete(service: service)
    }
}

public final class InMemoryProviderCredentialAccess: ProviderCredentialAccess {
    private var values: [String: String]

    public init(seed: [String: String] = [:]) {
        values = seed
    }

    public func load(service: String) throws -> String {
        guard let value = try loadIfPresent(service: service) else {
            throw ProviderConfigError.invalid("Provider credential unavailable.")
        }
        return value
    }

    public func loadIfPresent(service: String) throws -> String? {
        let normalizedService = try normalizedService(service)
        return values[normalizedService]
    }

    public func save(value: String, service: String) throws {
        let normalizedService = try normalizedService(service)
        guard !value.isEmpty else {
            throw ProviderConfigError.invalid("Provider credential value is required.")
        }
        values[normalizedService] = value
    }

    public func delete(service: String) throws {
        let normalizedService = try normalizedService(service)
        values.removeValue(forKey: normalizedService)
    }

    private func normalizedService(_ service: String) throws -> String {
        let trimmed = service.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderConfigError.invalid("Provider credential service is required.")
        }
        return trimmed
    }
}

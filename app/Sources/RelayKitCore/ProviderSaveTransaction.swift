import Foundation

public enum ProviderSaveTransaction {
    public struct CredentialChange: Equatable, Sendable {
        public let service: String
        public let value: String

        public init(service: String, value: String) {
            self.service = service
            self.value = value
        }
    }

    public struct Dependencies {
        public let loadCredential: (String) throws -> String?
        public let saveCredential: (String, String) throws -> Void
        public let deleteCredential: (String) throws -> Void
        public let writeConfig: (Data) throws -> Void
        public let readConfig: () throws -> Data
        public let restoreConfig: (Data?) throws -> Void
        public let reloadConfig: () throws -> Void

        public init(
            loadCredential: @escaping (String) throws -> String?,
            saveCredential: @escaping (String, String) throws -> Void,
            deleteCredential: @escaping (String) throws -> Void,
            writeConfig: @escaping (Data) throws -> Void,
            readConfig: @escaping () throws -> Data,
            restoreConfig: @escaping (Data?) throws -> Void,
            reloadConfig: @escaping () throws -> Void
        ) {
            self.loadCredential = loadCredential
            self.saveCredential = saveCredential
            self.deleteCredential = deleteCredential
            self.writeConfig = writeConfig
            self.readConfig = readConfig
            self.restoreConfig = restoreConfig
            self.reloadConfig = reloadConfig
        }
    }

    public static func commit(
        proposedConfig: Data,
        originalConfig: Data?,
        credential: CredentialChange?,
        dependencies: Dependencies
    ) throws {
        let previousCredential: String?
        if let credential {
            previousCredential = try dependencies.loadCredential(credential.service)
        } else {
            previousCredential = nil
        }

        if let credential {
            try dependencies.saveCredential(credential.service, credential.value)
        }

        do {
            try dependencies.writeConfig(proposedConfig)
            guard try dependencies.readConfig() == proposedConfig else {
                throw ProviderConfigError.invalid("Provider config readback did not match the saved config.")
            }
            try dependencies.reloadConfig()
        } catch {
            var rollbackFailed = false
            do { try dependencies.restoreConfig(originalConfig) } catch { rollbackFailed = true }
            if let credential {
                do {
                    if let previousCredential {
                        try dependencies.saveCredential(credential.service, previousCredential)
                    } else {
                        try dependencies.deleteCredential(credential.service)
                    }
                } catch {
                    rollbackFailed = true
                }
            }
            do { try dependencies.reloadConfig() } catch { rollbackFailed = true }
            if rollbackFailed {
                throw ProviderConfigError.invalid("Provider save failed and rollback could not complete.")
            }
            throw error
        }
    }
}

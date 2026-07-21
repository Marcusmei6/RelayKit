import AppKit
import CryptoKit
import Foundation
import RelayKitCore

@MainActor
final class AppModel: ObservableObject {
    enum GatewayDisplayState: String {
        case stopped = "Stopped"
        case running = "Running"
        case error = "Error"

        init(rawGatewayHealth: String) {
            switch rawGatewayHealth.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "ok", "running":
                self = .running
            case "stopped":
                self = .stopped
            default:
                self = .error
            }
        }
    }

    @Published var providerConfigPath: String {
        didSet {
            if persistsProviderConfigPath {
                UserDefaults.standard.set(providerConfigPath, forKey: "providerConfigPath")
            }
            refreshConfiguredProviders()
        }
    }
    @Published var codexTargetPath: String {
        didSet {
            refreshCodexConnectionStatus()
        }
    }
    @Published var gatewayBinaryPath = RelayKitPaths.gatewayBinaryPath()
    @Published var usageLogPath = AppModel.defaultUsageLogPath()
    @Published var codexSourcePath = RelayKitPaths.codexConfigSourcePath()
    @Published var codexConnectionStatus = "target not set"
    @Published var gatewayStatus = "stopped"
    @Published var models: [RelayModel] = []
    @Published var gatewayModelHealth = GatewayModelHealth.empty
    @Published var localCatalog: LocalModelCatalog?
    @Published var localCatalogURL = LocalCatalogClient.defaultModelsURL()
    @Published var localCatalogStatus = "not scanned"
    @Published var localCatalogAuthState = "credential reference needed"
    @Published var staleProviderConfigPreferenceRecovered = false
    @Published var desktopAcceptance = DesktopAcceptanceEvidence.load()
    @Published var usageSummaries: [UsageSummary] = []
    @Published var usageRefreshInProgress = false
    @Published var usageRefreshCount = 0
    @Published var usageLastRefreshDurationMs = 0
    @Published var providerConfigText = ""
    @Published var configuredProviders: [ConfiguredProviderEntry] = []
    @Published var message = ""
    @Published var appearanceMode: AppAppearanceMode {
        didSet {
            settingsStore.appearanceMode = appearanceMode
        }
    }
    @Published var launchAtLoginRequested: Bool {
        didSet {
            settingsStore.launchAtLoginRequested = launchAtLoginRequested
        }
    }
    @Published var launchAtLoginStatus = "not registered"
    @Published var proofCheckInProgress = false
    @Published var officialAuthStatus = OfficialChannelSnapshot.Status.notConnected.rawValue
    @Published var officialAuthDetail = "No current isolated Codex login."
    @Published private(set) var officialSnapshot = OfficialChannelSnapshot(
        status: .notConnected,
        detail: "No current isolated Codex login."
    )
    @Published var officialAuthURL = ""
    @Published var officialDeviceCode = ""
    @Published var officialDeviceCodeCopied = false
    @Published var officialAuthInProgress = false

    var opensOfficialAuthURL = true

    var officialAuthProcessIdentifier: Int32? {
        officialAuthProcess?.processIdentifier
    }

    private let gateway = GatewayProcess()
    private let client = GatewayClient()
    private var catalogClient = LocalCatalogClient()
    private var persistsProviderConfigPath = true
    private let settingsStore = AppSettingsStore()
    private let loginItemService = LoginItemService()
    private let appStartedAt = Date()
    private var gatewayStartedAt: Date?
    private var officialAuthProcess: Process?
    private var usesSmokeModelHealthFixture = false

    init() {
        let savedPath = UserDefaults.standard.string(forKey: "providerConfigPath")
        let resolvedProviderConfigPath = RelayKitPaths.resolvedProviderConfigPath(savedPath: savedPath)
        staleProviderConfigPreferenceRecovered = RelayKitPaths.recoveredStaleTemporaryProviderConfig(savedPath: savedPath)
        providerConfigPath = resolvedProviderConfigPath
        if savedPath != resolvedProviderConfigPath {
            UserDefaults.standard.set(resolvedProviderConfigPath, forKey: "providerConfigPath")
        }
        codexTargetPath = RelayKitPaths.defaultCodexConfigPath()
        appearanceMode = settingsStore.appearanceMode
        launchAtLoginRequested = settingsStore.launchAtLoginRequested
        refreshCodexConnectionStatus()
        refreshLaunchAtLoginStatus()
        refreshConfiguredProviders()
        refreshOfficialAuthStatus()
    }

    func useTemporaryProviderConfigPath(_ path: String) {
        persistsProviderConfigPath = false
        providerConfigPath = path
        persistsProviderConfigPath = true
    }

    func useSmokeModelHealthFixture() {
        usesSmokeModelHealthFixture = true
        models = [
            RelayModel(id: "saved/coder", ownedBy: "fixture-provider"),
        ]
        gatewayModelHealth = GatewayModelHealth(
            probed: true,
            healthy: 1,
            unhealthy: 1,
            hidden: [
                GatewayHiddenModel(id: "saved/missing", reason: "unsupported model"),
            ]
        )
    }

    func startGatewayOnOrdinaryLaunch() {
        guard storedGatewayConfigurationExists() else {
            gatewayStatus = "stopped"
            message = "RelayKit setup required: add a provider or connect Official."
            return
        }
        startGateway()
        if gateway.isRunning {
            Task { await refreshModels() }
        }
    }

    func startGateway() {
        do {
            let runtimeConfig = try makeGatewayRuntimeConfig()
            let credentialHandoff = try GatewayCredentialHandoff.encode(configData: runtimeConfig.data) { reference in
                try KeychainCredentialStore.load(service: reference)
            }
            try gateway.start(
                binaryPath: gatewayBinaryPath,
                configPath: runtimeConfig.path,
                usageLogPath: usageLogPath,
                credentialHandoff: credentialHandoff,
                parentProcessIdentifier: ProcessInfo.processInfo.processIdentifier
            )
            gatewayStatus = "running"
            gatewayStartedAt = Date()
            message = "Gateway started on 127.0.0.1:19777"
            refreshOfficialGatewayProjection()
        } catch {
            gatewayStatus = "error"
            message = gatewayFailureMessage(error)
            refreshOfficialGatewayProjection()
        }
    }

    func stopGateway() {
        gateway.stop()
        gatewayStartedAt = nil
        gatewayStatus = "stopped"
        message = "Gateway stopped"
        refreshOfficialGatewayProjection()
    }

    func restartGateway() {
        stopGateway()
        startGateway()
    }

    func refreshHealth() async {
        do {
            gatewayStatus = try await client.health()
            message = "Gateway health ok"
            await rebuildCodexCatalogIfEnabled()
        } catch {
            gatewayStatus = gateway.isRunning ? "starting/error" : "stopped"
            message = gateway.isRunning ? error.localizedDescription : ProviderFormLabels.gatewayStoppedGuidance
        }
    }

    func refreshModels() async {
        if usesSmokeModelHealthFixture {
            message = "Loaded smoke model health fixture"
            return
        }
        do {
            let gatewayModels = try await client.modelListData()
            let response = try JSONDecoder().decode(ModelListResponse.self, from: gatewayModels)
            models = response.data
            gatewayModelHealth = response.modelHealth ?? .empty
            message = "Loaded \(models.count) model(s)"
            await rebuildCodexCatalogIfEnabled(gatewayModels: gatewayModels)
        } catch {
            message = gateway.isRunning ? error.localizedDescription : ProviderFormLabels.gatewayStoppedGuidance
        }
    }

    func testSavedProviderConnection(providerID: String, modelID: String) async throws -> ProviderTestResponse {
        if !gateway.isRunning {
            startGateway()
        }
        guard gateway.isRunning else {
            throw GatewayClientError.gatewayUnavailable
        }
        let result = try await client.testProvider(providerID: providerID, modelID: modelID)
        recordProviderTestResult(result)
        return result
    }

    private func recordProviderTestResult(_ result: ProviderTestResponse) {
        models.removeAll { $0.id == result.modelID }
        guard result.connectionKind == .connected else { return }
        models.append(RelayModel(id: result.modelID, ownedBy: result.providerID))
    }

    func providerHealth(for provider: ConfiguredProviderEntry) -> ProviderHealthSnapshot {
        let savedIDs = Set(provider.models.map(\.id))
        let available = models.filter { savedIDs.contains($0.id) }.count
        let hidden = gatewayModelHealth.hidden.filter { savedIDs.contains($0.id) }
        return ProviderHealthSnapshot(saved: savedIDs.count, available: available, hidden: hidden)
    }

    func refreshLocalCatalog() async {
        do {
            localCatalog = try await catalogClient.catalog()
            let modelCount = localCatalog?.modelCount ?? 0
            let sourceCount = localCatalog?.sourceGroups.count ?? 0
            localCatalogStatus = "catalog available: \(modelCount) model(s), \(sourceCount) source(s)"
            localCatalogAuthState = "auth required for execution"
            message = "Loaded local catalog"
        } catch {
            localCatalog = nil
            localCatalogStatus = "agent-local-gateway unavailable"
            localCatalogAuthState = "catalog unavailable"
            message = error.localizedDescription
        }
    }

    func setLocalCatalogURL(_ url: URL) {
        localCatalogURL = url
        catalogClient = LocalCatalogClient(modelsURL: url)
    }

    func openManualProofTerminal() {
        do {
            let runDir = URL(fileURLWithPath: desktopAcceptance.proofRoot)
                .appendingPathComponent("run", isDirectory: true)
            try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
            let commandFile = runDir.appendingPathComponent("open-proof-terminal.command")
            try """
            #!/usr/bin/env bash
            set -euo pipefail
            export RELAYKIT_DESKTOP_PROOF_TRIGGER=relaykit_app_terminal
            \(desktopAcceptance.startCommand)
            """.write(to: commandFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commandFile.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [commandFile.path]
            try process.run()
            message = "Opened Terminal for manual proof"
        } catch {
            message = "Run manually: \(desktopAcceptance.startCommand)"
        }
    }

    func runManualProofSetup() {
        guard !proofCheckInProgress else { return }
        proofCheckInProgress = true
        message = "Running isolated proof setup"
        let command = desktopAcceptance.startCommand + " --setup-only"
        Task {
            let result = await Self.runShell(command, environment: ["RELAYKIT_DESKTOP_PROOF_TRIGGER": "relaykit_app"])
            switch result {
            case .success:
                desktopAcceptance = DesktopAcceptanceEvidence.load()
                message = "Isolated proof setup passed"
            case .failure(let error):
                desktopAcceptance = DesktopAcceptanceEvidence.load()
                message = "Isolated proof setup failed: \(error.localizedDescription)"
            }
            proofCheckInProgress = false
        }
    }

    func copyManualProofCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(desktopAcceptance.startCommand, forType: .string)
        message = "Copied verification command"
    }

    func connectOfficial() {
        guard !officialAuthInProgress else { return }
        guard !officialSnapshot.isConnected else {
            message = "Official login is already connected; disconnect first to sign in again."
            return
        }
        do {
            try ensureOfficialAuthDirs()
            officialAuthInProgress = true
            updateOfficialSnapshot(
                loggedIn: false,
                detail: "Waiting for Codex device authorization in RelayKit isolated storage."
            )
            officialAuthURL = ""
            officialDeviceCode = ""
            officialDeviceCodeCopied = false

            let process = Process()
            Self.configureCodexProcess(process, arguments: ["login", "--device-auth"], environment: officialCodexEnvironment())
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    self?.consumeOfficialAuthOutput(chunk)
                }
            }
            officialAuthProcess = process
            try process.run()
            DispatchQueue.global(qos: .utility).async { [weak self, weak process] in
                process?.waitUntilExit()
                DispatchQueue.main.async {
                    output.fileHandleForReading.readabilityHandler = nil
                    self?.officialAuthProcess = nil
                    self?.officialAuthInProgress = false
                    if process?.terminationStatus != 0 {
                        self?.updateOfficialSnapshot(loggedIn: false, detail: "Device authorization did not complete.")
                    }
                    self?.refreshOfficialAuthStatus()
                }
            }
            message = "Opened official device login"
        } catch {
            officialAuthInProgress = false
            updateOfficialSnapshot(loggedIn: false, detail: error.localizedDescription)
            message = error.localizedDescription
        }
    }

    func refreshOfficialAuthStatus() {
        Task {
            let wasConnected = officialSnapshot.isConnected
            do {
                try ensureOfficialAuthDirs()
                let authURL = URL(fileURLWithPath: RelayKitPaths.officialCodexHomePath())
                    .appendingPathComponent("auth.json")
                let loggedIn = (try? Data(contentsOf: authURL))
                    .map(OfficialCodexAuthState.isConnected(data:)) ?? false
                if loggedIn {
                    let verified = officialRouteEvidence(
                        gatewayRunning: gateway.isRunning,
                        executableHash: Self.fileHash(Bundle.main.executableURL),
                        providerConfigHash: Self.fileHash(URL(fileURLWithPath: providerConfigPath))
                    ).isVerified
                    updateOfficialSnapshot(
                        loggedIn: true,
                        detail: verified
                            ? "Current proof verified official and provider routes."
                            : "Isolated Codex login is available; current route proof is unavailable or stale."
                    )
                } else {
                    updateOfficialSnapshot(loggedIn: false, detail: "Use Connect Official to sign in with Codex device authorization.")
                }
                officialAuthURL = ""
                officialDeviceCode = ""
                officialDeviceCodeCopied = false
            } catch {
                updateOfficialSnapshot(loggedIn: false, detail: error.localizedDescription)
            }
            reconcileGatewayAfterOfficialStatusChange(wasConnected: wasConnected)
            await self.rebuildCodexCatalogIfEnabled()
        }
    }

    private func reconcileGatewayAfterOfficialStatusChange(wasConnected: Bool) {
        if wasConnected != officialSnapshot.isConnected, gateway.isRunning {
            stopGateway()
        }
        if storedGatewayConfigurationExists(), !gateway.isRunning {
            startGateway()
        }
    }

    func disconnectOfficial() {
        let wasConnected = officialSnapshot.isConnected
        officialAuthProcess?.terminate()
        officialAuthProcess = nil
        officialAuthInProgress = false
        do {
            let codexHome = RelayKitPaths.officialCodexHomePath()
            if FileManager.default.fileExists(atPath: codexHome) {
                try FileManager.default.removeItem(atPath: codexHome)
            }
            try ensureOfficialAuthDirs()
            updateOfficialSnapshot(loggedIn: false, detail: "RelayKit isolated official login was removed.")
            officialAuthURL = ""
            officialDeviceCode = ""
            officialDeviceCodeCopied = false
            message = "Disconnected RelayKit official login"
            reconcileGatewayAfterOfficialStatusChange(wasConnected: wasConnected)
            Task { await rebuildCodexCatalogIfEnabled() }
        } catch {
            message = error.localizedDescription
        }
    }

    func openOfficialAuthLink() {
        guard let url = URL(string: officialAuthURL),
              url.scheme == "https",
              url.host == "auth.openai.com" else {
            message = "Official sign-in link is not ready"
            return
        }
        NSWorkspace.shared.open(url)
        message = "Opened official sign-in link"
    }

    func copyOfficialDeviceCode() {
        guard officialDeviceCode.range(of: #"[A-Z0-9]{4}-[A-Z0-9]{4,6}"#, options: .regularExpression) != nil else {
            message = "Official device code is not ready"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(officialDeviceCode, forType: .string)
        officialDeviceCodeCopied = true
        message = "Copied official device code"
    }

    func stopOfficialAuthProcessForShutdown() {
        officialAuthProcess?.terminate()
        officialAuthProcess = nil
        officialAuthInProgress = false
    }

    func loadProviderConfig() {
        do {
            let text = try String(contentsOfFile: providerConfigPath, encoding: .utf8)
            let json = try JSONSerialization.jsonObject(with: Data(text.utf8))
            try ProviderConfigValidator.validate(json)
            providerConfigText = text
            refreshConfiguredProviders(from: Data(text.utf8))
            message = "Loaded provider config"
        } catch {
            message = error.localizedDescription
        }
    }

    func saveProviderConfig() {
        do {
            let data = Data(providerConfigText.utf8)
            let json = try JSONSerialization.jsonObject(with: data)
            try ProviderConfigValidator.validate(json)
            let pretty = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            let gatewayWasRunning = gateway.isRunning
            var backupCreated = false
            if FileManager.default.fileExists(atPath: providerConfigPath) {
                let backup = providerConfigPath + ".bak." + UUID().uuidString
                try FileManager.default.copyItem(atPath: providerConfigPath, toPath: backup)
                backupCreated = true
            }
            try ensureProviderConfigDirectory()
            try pretty.write(to: URL(fileURLWithPath: providerConfigPath), options: .atomic)
            providerConfigText = String(data: pretty, encoding: .utf8) ?? providerConfigText
            refreshConfiguredProviders(from: pretty)
            try reloadGatewayAfterProviderConfigChange()
            let lifecycleMessage = gatewayWasRunning ? "gateway reloaded" : "gateway started"
            message = ProviderFormLabels.providerConfigSavedMessage(backupCreated: backupCreated) + "; " + lifecycleMessage
            Task { await rebuildCodexCatalogIfEnabled() }
        } catch {
            message = gatewayFailureMessage(error)
        }
    }

    func addProvider(_ draft: ProviderConfigDraft, keychainCredential: String = "") -> Bool {
        do {
            let existing: Data
            if FileManager.default.fileExists(atPath: providerConfigPath) {
                existing = try Data(contentsOf: URL(fileURLWithPath: providerConfigPath))
            } else if providerConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing = Data(#"{"providers":[]}"#.utf8)
            } else {
                existing = Data(providerConfigText.utf8)
            }
            let pretty = try ProviderConfigDraftWriter.addProvider(draft, to: existing)
            let configURL = URL(fileURLWithPath: providerConfigPath)
            let originalConfig = FileManager.default.fileExists(atPath: providerConfigPath) ? try Data(contentsOf: configURL) : nil
            let backupCreated = try createProviderConfigBackupIfNeeded()
            let gatewayWasRunning = gateway.isRunning
            try saveProviderTransaction(pretty, originalConfig: originalConfig, draft: draft, keychainCredential: keychainCredential)
            providerConfigText = String(data: pretty, encoding: .utf8) ?? ""
            refreshConfiguredProviders(from: pretty)
            let confirmation = ProviderFormLabels.providerAddedMessage(
                storedKey: draft.credentialKind == "keychain" && !keychainCredential.isEmpty,
                backupCreated: backupCreated
            )
            message = gatewayWasRunning ? "\(confirmation); gateway reloaded" : confirmation
            if !gatewayWasRunning { message += "; gateway started" }
            Task { await rebuildCodexCatalogIfEnabled() }
            return true
        } catch {
            message = gatewayFailureMessage(error)
            return false
        }
    }

    func updateProvider(_ originalProviderId: String, draft: ProviderConfigDraft, keychainCredential: String = "") -> Bool {
        do {
            let existing = try providerConfigData()
            let originalConfig = FileManager.default.fileExists(atPath: providerConfigPath)
                ? try Data(contentsOf: URL(fileURLWithPath: providerConfigPath))
                : nil
            let json = try JSONSerialization.jsonObject(with: existing)
            guard var root = json as? [String: Any],
                  let providers = root["providers"] as? [[String: Any]] else {
                throw ProviderConfigError.invalid("providers array is required")
            }
            root["providers"] = providers.filter { ($0["id"] as? String ?? "") != originalProviderId }
            let filtered = try JSONSerialization.data(withJSONObject: root)
            let pretty = try ProviderConfigDraftWriter.addProvider(draft, to: filtered)
            let backupCreated = try createProviderConfigBackupIfNeeded()
            let gatewayWasRunning = gateway.isRunning
            try saveProviderTransaction(pretty, originalConfig: originalConfig, draft: draft, keychainCredential: keychainCredential)
            providerConfigText = String(data: pretty, encoding: .utf8) ?? ""
            refreshConfiguredProviders(from: pretty)
            let confirmation = ProviderFormLabels.providerUpdatedMessage(backupCreated: backupCreated)
            message = gatewayWasRunning ? "\(confirmation); gateway reloaded" : confirmation
            if !gatewayWasRunning { message += "; gateway started" }
            Task { await rebuildCodexCatalogIfEnabled() }
            return true
        } catch {
            message = gatewayFailureMessage(error)
            return false
        }
    }

    private func createProviderConfigBackupIfNeeded() throws -> Bool {
        guard FileManager.default.fileExists(atPath: providerConfigPath) else { return false }
        let backup = providerConfigPath + ".bak." + UUID().uuidString
        try FileManager.default.copyItem(atPath: providerConfigPath, toPath: backup)
        return true
    }

    private func saveProviderTransaction(_ pretty: Data, originalConfig: Data?, draft: ProviderConfigDraft, keychainCredential: String) throws {
        let configURL = URL(fileURLWithPath: providerConfigPath)
        let credential = draft.credentialKind == "keychain" && !keychainCredential.isEmpty
            ? ProviderSaveTransaction.CredentialChange(service: draft.credentialReference, value: keychainCredential)
            : nil
        try ProviderSaveTransaction.commit(
            proposedConfig: pretty,
            originalConfig: originalConfig,
            credential: credential,
            dependencies: .init(
                loadCredential: { try KeychainCredentialStore.loadIfPresent(service: $0) },
                saveCredential: { service, value in try KeychainCredentialStore.save(value: value, service: service) },
                deleteCredential: { try KeychainCredentialStore.delete(service: $0) },
                writeConfig: { data in
                    try self.ensureProviderConfigDirectory()
                    try data.write(to: configURL, options: .atomic)
                },
                readConfig: {
                    let data = try Data(contentsOf: configURL)
                    let json = try JSONSerialization.jsonObject(with: data)
                    try ProviderConfigValidator.validate(json)
                    return data
                },
                restoreConfig: { original in
                    if let original {
                        try original.write(to: configURL, options: .atomic)
                    } else if FileManager.default.fileExists(atPath: configURL.path) {
                        try FileManager.default.removeItem(at: configURL)
                    }
                },
                reloadConfig: {
                    try self.reloadGatewayAfterProviderConfigChange()
                }
            )
        )
    }

    func refreshUsageSummary() async {
        guard !usageRefreshInProgress else {
            return
        }
        usageRefreshInProgress = true
        let binaryPath = gatewayBinaryPath
        let logPath = usageLogPath
        defer {
            usageRefreshInProgress = false
        }
        do {
            let result = try await Self.summarizeUsageOffMainThread(binaryPath: binaryPath, usageLogPath: logPath)
            usageSummaries = result.rows
            usageRefreshCount += 1
            usageLastRefreshDurationMs = result.durationMs
            message = "Loaded \(usageSummaries.count) usage row(s) in \(result.durationMs)ms"
        } catch {
            message = error.localizedDescription
        }
    }

    nonisolated private static func summarizeUsageOffMainThread(binaryPath: String, usageLogPath: String) async throws -> (rows: [UsageSummary], durationMs: Int) {
        try await Task.detached(priority: .utility) {
            let start = Date()
            let output = try GatewayProcess().summarizeUsage(binaryPath: binaryPath, usageLogPath: usageLogPath)
            let rows = try JSONDecoder().decode([UsageSummary].self, from: Data(output.utf8))
            let duration = Int(Date().timeIntervalSince(start) * 1000)
            return (rows, duration)
        }.value
    }

    func enableCodexForDesktop() async {
        do {
            if !gateway.isRunning {
                startGateway()
            }
            guard gateway.isRunning else {
                throw GatewayClientError.gatewayUnavailable
            }
            try await rebuildCodexCatalog()
            let output = try gateway.enableCodexConfig(
                binaryPath: gatewayBinaryPath,
                target: RelayKitPaths.defaultCodexConfigPath(),
                catalog: RelayKitPaths.codexCatalogPath(),
                state: RelayKitPaths.codexConfigStatePath()
            )
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            message = detail.isEmpty ? "RelayKit enabled for Codex. Restart Codex to load the updated route." : "\(detail) Restart Codex to load the updated route."
            refreshCodexConnectionStatus()
        } catch {
            message = gatewayFailureMessage(error)
        }
    }

    func disableCodexForDesktop() async {
        do {
            let output = try gateway.disableCodexConfig(
                binaryPath: gatewayBinaryPath,
                target: RelayKitPaths.defaultCodexConfigPath(),
                state: RelayKitPaths.codexConfigStatePath()
            )
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            message = detail.isEmpty ? "RelayKit disabled for Codex. Restart Codex to restore its previous configuration." : "\(detail) Restart Codex to restore its previous configuration."
            refreshCodexConnectionStatus()
        } catch {
            message = gatewayFailureMessage(error)
        }
    }

    var codexConnectionIsConfigured: Bool {
        codexConnectionStatus.hasPrefix("Enabled")
    }

    var codexIntegrationHasManagedState: Bool {
        FileManager.default.fileExists(atPath: RelayKitPaths.codexConfigStatePath())
    }

    var gatewayIsRunning: Bool {
        gateway.isRunning
    }

    var gatewayDisplayState: GatewayDisplayState {
        GatewayDisplayState(rawGatewayHealth: gatewayStatus)
    }

    var gatewayProcessIdentifier: Int32? {
        gateway.processIdentifier
    }

    var unifiedModels: [UnifiedModelEntry] {
        let configured = configuredProviders.flatMap { provider in
            provider.models.map { model in
                UnifiedModelEntry(
                    id: "configured:\(provider.id):\(model.id)",
                    modelId: model.id,
                    displayName: model.displayName,
                    origin: "configured",
                    originLabel: provider.name,
                    detail: "\(provider.apiFormat) · \(provider.credentialKind)",
                    contextWindow: model.contextWindow
                )
            }
        }
        let sourceLabels = Dictionary(uniqueKeysWithValues: (localCatalog?.sourceGroups ?? []).map { ($0.source, $0.publicLabel) })
        let catalog = (localCatalog?.models ?? []).map { model in
            UnifiedModelEntry(
                id: "catalog:\(model.id)",
                modelId: model.id,
                displayName: model.displayName,
                origin: "catalog",
                originLabel: sourceLabels[model.source] ?? "catalog",
                detail: [model.apiProtocol, model.status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                contextWindow: model.contextWindow
            )
        }
        return configured + catalog
    }

    func refreshCodexConnectionStatus() {
        do {
            let status = try gateway.codexConfigStatus(
                binaryPath: gatewayBinaryPath,
                target: RelayKitPaths.defaultCodexConfigPath(),
                state: RelayKitPaths.codexConfigStatePath()
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            switch status {
            case "enabled": codexConnectionStatus = "Enabled · restart Codex to apply changes"
            case "drifted": codexConnectionStatus = "Needs attention · managed Codex settings changed"
            default: codexConnectionStatus = "Disabled"
            }
        } catch {
            codexConnectionStatus = codexIntegrationHasManagedState
                ? "Needs attention · managed Codex settings could not be verified"
                : "Disabled"
        }
    }

    func setAppearanceMode(_ mode: AppAppearanceMode) {
        appearanceMode = mode
        message = "Appearance set to \(mode.rawValue)"
    }

    func refreshLaunchAtLoginStatus() {
        let status = loginItemService.status
        launchAtLoginStatus = status.rawValue
        launchAtLoginRequested = status.isRequested
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItemService.setEnabled(enabled)
            refreshLaunchAtLoginStatus()
            message = enabled ? "Launch at login requested" : "Launch at login disabled"
        } catch {
            refreshLaunchAtLoginStatus()
            message = "Launch at login failed: \(error.localizedDescription)"
        }
    }

    private static func defaultUsageLogPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RelayKit/usage.jsonl")
            .path
    }

    private func ensureOfficialAuthDirs() throws {
        try FileManager.default.createDirectory(atPath: RelayKitPaths.officialHomePath(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: RelayKitPaths.officialCodexHomePath(), withIntermediateDirectories: true)
        try writeOfficialCredentialReference()
    }

    private func writeOfficialCredentialReference() throws {
        let body: [String: Any] = [
            "credential_ref": [
                "kind": "codex_home",
                "value": RelayKitPaths.officialCodexHomePath(),
            ],
            "managed_by": "RelayKit",
            "token_material": "Codex CLI isolated CODEX_HOME",
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        let url = URL(fileURLWithPath: RelayKitPaths.officialCredentialRefPath())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func officialCodexEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = RelayKitPaths.officialHomePath()
        environment["CODEX_HOME"] = RelayKitPaths.officialCodexHomePath()
        environment["PATH"] = Self.codexSearchPath(existing: environment["PATH"])
        return environment
    }

    private func updateOfficialSnapshot(loggedIn: Bool, detail: String) {
        let evidence = officialRouteEvidence(
            gatewayRunning: gateway.isRunning,
            executableHash: Self.fileHash(Bundle.main.executableURL),
            providerConfigHash: Self.fileHash(URL(fileURLWithPath: providerConfigPath))
        )
        officialSnapshot = OfficialChannelSnapshot.resolve(
            loggedIn: loggedIn,
            authInProgress: officialAuthInProgress,
            routeEvidence: evidence,
            detail: detail
        )
        officialAuthStatus = officialSnapshot.status.rawValue
        officialAuthDetail = officialSnapshot.detail
    }

    private func refreshOfficialGatewayProjection() {
        guard officialSnapshot.isConnected else { return }
        updateOfficialSnapshot(
            loggedIn: true,
            detail: gateway.isRunning
                ? "Isolated Codex login is available; current route proof is unavailable or stale."
                : "Isolated Codex login is available; start the Gateway to verify the current route."
        )
    }

    private func officialRouteEvidence(gatewayRunning: Bool, executableHash: String?, providerConfigHash: String?) -> OfficialRouteEvidence {
        let url = URL(fileURLWithPath: RelayKitPaths.officialRouteEvidencePath())
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let evidence = object as? [String: Any] else {
            return OfficialRouteEvidence(
                gatewayRunning: gatewayRunning,
                currentRun: false,
                loginStatusMatches: false,
                currentOfficialEventFound: false,
                currentProviderEventFound: false,
                appExecutableHashMatches: false,
                providerConfigHashMatches: false,
                appProcessMatches: false,
                gatewayProcessMatches: false,
                evidenceFreshForProcesses: false
            )
        }
        let evidenceModifiedAt = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        let evidenceAppHash = evidence["app_executable_sha256"] as? String
        let evidenceProviderHash = evidence["provider_config_sha256"] as? String
        let hashesArePresent = executableHash?.isEmpty == false && providerConfigHash?.isEmpty == false &&
            evidenceAppHash?.isEmpty == false && evidenceProviderHash?.isEmpty == false
        let freshForProcesses = evidenceModifiedAt.map { modifiedAt in
            guard let gatewayStartedAt else { return false }
            return modifiedAt >= appStartedAt && modifiedAt >= gatewayStartedAt
        } ?? false
        return OfficialRouteEvidence(
            gatewayRunning: gatewayRunning,
            currentRun: evidence["usage_scope"] as? String == "current_run",
            loginStatusMatches: evidence["login_status"] as? String == "logged_in",
            currentOfficialEventFound: evidence["current_official_event_found"] as? Bool == true,
            currentProviderEventFound: evidence["current_provider_event_found"] as? Bool == true,
            appExecutableHashMatches: hashesArePresent && evidenceAppHash == executableHash,
            providerConfigHashMatches: hashesArePresent && evidenceProviderHash == providerConfigHash,
            appProcessMatches: (evidence["app_pid"] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier,
            gatewayProcessMatches: (evidence["gateway_pid"] as? NSNumber)?.int32Value == gateway.processIdentifier,
            evidenceFreshForProcesses: freshForProcesses
        )
    }

    private static func fileHash(_ url: URL?) -> String? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func consumeOfficialAuthOutput(_ chunk: String) {
        let cleanURL = ProviderFormLabels.sanitizedOfficialAuthURL(from: chunk)
        if !cleanURL.isEmpty {
            setOfficialAuthURLIfNeeded(cleanURL)
        }
        let clean = chunk.replacingOccurrences(of: #"\x1B\[[0-9;]*m"#, with: "", options: .regularExpression)
        if officialDeviceCode.isEmpty,
           let range = clean.range(of: #"[A-Z0-9]{4}-[A-Z0-9]{4,6}"#, options: .regularExpression) {
            officialDeviceCode = String(clean[range])
            setOfficialAuthURLIfNeeded("https://auth.openai.com/codex/device")
        }
    }

    private func setOfficialAuthURLIfNeeded(_ value: String) {
        guard officialAuthURL.isEmpty,
              let url = URL(string: value) else {
            return
        }
        officialAuthURL = value
        if opensOfficialAuthURL {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated private static func runShell(_ command: String, environment: [String: String]) async -> Result<String, Error> {
        await Task.detached {
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-lc", command]
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                guard process.terminationStatus == 0 else {
                    return .failure(ShellCommandError(status: process.terminationStatus, output: output))
                }
                return .success(output)
            } catch {
                return .failure(error)
            }
        }.value
    }

    nonisolated private static func configureCodexProcess(_ process: Process, arguments: [String], environment: [String: String]) {
        if let binary = resolvedCodexBinary(environment: environment) {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex"] + arguments
        }
        process.environment = environment
    }

    nonisolated private static func resolvedCodexBinary(environment: [String: String]) -> String? {
        var candidates: [String] = []
        if let override = environment["RELAYKIT_CODEX_BINARY"], isSafeExecutablePath(override) {
            candidates.append(override)
        }
        candidates.append("/Applications/Codex.app/Contents/Resources/codex")
        if let home = environment["NSHomeDirectory"], !home.isEmpty {
            candidates.append(URL(fileURLWithPath: home).appendingPathComponent(".local/bin/codex").path)
        }
        candidates.append(NSHomeDirectory() + "/.local/bin/codex")
        candidates.append("/opt/homebrew/bin/codex")
        candidates.append("/usr/local/bin/codex")

        var seen = Set<String>()
        for candidate in candidates where !candidate.isEmpty && seen.insert(candidate).inserted {
            if isSafeExecutablePath(candidate) {
                return candidate
            }
        }
        return nil
    }

    nonisolated private static func isSafeExecutablePath(_ path: String) -> Bool {
        !path.contains("\n") && path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)
    }

    nonisolated private static func codexSearchPath(existing: String?) -> String {
        let additions = [
            "/Applications/Codex.app/Contents/Resources",
            NSHomeDirectory() + "/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let parts = ((existing ?? "").isEmpty ? [] : (existing ?? "").split(separator: ":").map(String.init)) + additions
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    private func providerConfigData() throws -> Data {
        if FileManager.default.fileExists(atPath: providerConfigPath) {
            return try Data(contentsOf: URL(fileURLWithPath: providerConfigPath))
        }
        if !providerConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Data(providerConfigText.utf8)
        }
        return Data(#"{"providers":[]}"#.utf8)
    }

    private func ensureProviderConfigDirectory() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: providerConfigPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func storedGatewayConfigurationExists() -> Bool {
        guard let data = try? providerConfigData(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let providers = root["providers"] as? [[String: Any]] ?? []
        return !providers.isEmpty || officialSnapshot.isConnected
    }

    private func makeGatewayRuntimeConfig() throws -> (path: String, data: Data) {
        let source = try providerConfigData()
        guard var root = try JSONSerialization.jsonObject(with: source) as? [String: Any] else {
            throw ProviderConfigError.invalid("Provider configuration must be a JSON object.")
        }
        let providers = root["providers"] as? [[String: Any]] ?? []
        root.removeValue(forKey: "official_passthrough")
        if !providers.isEmpty {
            try ProviderConfigValidator.validate(root)
        }

        if officialSnapshot.isConnected {
            let bundled = try CodexCatalogBuilder.catalog(accountProjection: true)
            guard let catalog = try JSONSerialization.jsonObject(with: bundled.data) as? [String: Any],
                  let catalogModels = catalog["models"] as? [[String: Any]] else {
                throw CodexModelCatalogError.invalidOfficialCatalog
            }
            let officialModels = catalogModels.compactMap { model -> [String: String]? in
                guard model["visibility"] as? String == "list",
                      let id = model["slug"] as? String,
                      !id.isEmpty else { return nil }
                return ["id": id, "display_name": (model["display_name"] as? String) ?? id]
            }
            guard !officialModels.isEmpty else {
                throw CodexModelCatalogError.missingOfficialTemplate
            }
            root["official_passthrough"] = [
                "base_url": "https://chatgpt.com/backend-api/codex",
                "credential_ref": ["kind": "codex_home", "value": RelayKitPaths.officialCodexHomePath()],
                "models": officialModels,
            ]
        }

        guard !providers.isEmpty || root["official_passthrough"] != nil else {
            throw ProviderConfigError.invalid("RelayKit setup required: add a provider or connect Official before starting the gateway.")
        }
        root["providers"] = providers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let runtimeURL = URL(fileURLWithPath: RelayKitPaths.gatewayRuntimeConfigPath())
        try FileManager.default.createDirectory(at: runtimeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: runtimeURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeURL.path)
        return (runtimeURL.path, data)
    }

    private func reloadGatewayAfterProviderConfigChange() throws {
        let wasRunning = gateway.isRunning
        if wasRunning {
            restartGateway()
        } else {
            startGateway()
        }
        guard gateway.isRunning else {
            let action = wasRunning ? "reload" : "start"
            throw ProviderConfigError.invalid("Gateway could not \(action). Check the provider configuration, Keychain credential, and whether port 19777 is already in use.")
        }
    }

    private func rebuildCodexCatalogIfEnabled(gatewayModels: Data? = nil) async {
        guard codexConnectionIsConfigured else { return }
        do {
            try await rebuildCodexCatalog(gatewayModels: gatewayModels)
        } catch {
            message = "Codex catalog update failed: \(error.localizedDescription)"
        }
    }

    private func rebuildCodexCatalog(gatewayModels snapshot: Data? = nil) async throws {
        let includeOfficial = officialSnapshot.isConnected
        let bundled = try CodexCatalogBuilder.catalog(accountProjection: includeOfficial)
        let gatewayModels: Data
        if let snapshot {
            gatewayModels = snapshot
        } else {
            gatewayModels = try await gatewayModelsForCodexCatalog()
        }
        let merged = try CodexModelCatalog.merge(
            officialCatalog: bundled.data,
            gatewayModels: gatewayModels,
            includeOfficialModels: includeOfficial
        )
        let catalogURL = URL(fileURLWithPath: RelayKitPaths.codexCatalogPath())
        try FileManager.default.createDirectory(at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try merged.write(to: catalogURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalogURL.path)
    }

    private func gatewayModelsForCodexCatalog() async throws -> Data {
        let models = try await client.modelListData()
        guard try configuredProvidersExist(),
              try CodexModelCatalog.gatewayModelsNeedRetry(models) else {
            return models
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        return try await client.modelListData()
    }

    private func configuredProvidersExist() throws -> Bool {
        guard let root = try JSONSerialization.jsonObject(with: providerConfigData()) as? [String: Any] else {
            throw ProviderConfigError.invalid("Provider configuration must be a JSON object.")
        }
        guard let providers = root["providers"] as? [[String: Any]] else {
            throw ProviderConfigError.invalid("providers array is required")
        }
        return !providers.isEmpty
    }

    private func gatewayFailureMessage(_ error: Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = detail.lowercased()
        if normalized.contains("address already in use") || normalized.contains("port") {
            return "Gateway could not bind port 19777. Stop the conflicting local process, then try again."
        }
        if normalized.contains("keychain") || normalized.contains("credential") {
            return "Gateway credential is unavailable. Update the provider credential in Keychain, then try again."
        }
        if normalized.contains("config") || normalized.contains("provider") || normalized.contains("setup required") {
            return "Gateway configuration needs attention: \(detail)"
        }
        return detail.isEmpty ? "Gateway action failed. Check RelayKit setup and try again." : detail
    }

    private func refreshConfiguredProviders() {
        guard let data = try? providerConfigData() else {
            configuredProviders = []
            return
        }
        refreshConfiguredProviders(from: data)
    }

    private func refreshConfiguredProviders(from data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let providers = root["providers"] as? [[String: Any]] else {
            configuredProviders = []
            return
        }
        configuredProviders = providers.compactMap(ConfiguredProviderEntry.init(provider:))
    }

}

private struct ShellCommandError: LocalizedError {
    let status: Int32
    let output: String

    var errorDescription: String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "command exited with status \(status)"
        }
        return "command exited with status \(status): \(trimmed)"
    }
}

struct ConfiguredProviderEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let baseURL: String
    let apiFormat: String
    let credentialKind: String
    let credentialReference: String
    let keyHeader: String
    let modelId: String
    let upstreamModel: String
    let models: [ConfiguredProviderModelEntry]
    let modelsURL: String
    let source: String
    let modelPrefix: String
    let contextWindow: Int?

    init?(provider: [String: Any]) {
        guard let id = provider["id"] as? String,
              let name = provider["name"] as? String,
              let baseURL = provider["base_url"] as? String,
              let apiFormat = provider["api_format"] as? String,
              let models = provider["models"] as? [[String: Any]] else {
            return nil
        }
        let credentialRef = provider["credential_ref"] as? [String: Any]
        let catalog = provider["catalog"] as? [String: Any]
        let routing = provider["routing"] as? [String: Any]
        let modelPrefix = routing?["model_prefix"] as? String ?? ""
        let parsedModels = models.compactMap { ConfiguredProviderModelEntry(model: $0, modelPrefix: modelPrefix) }
        guard let model = parsedModels.first else { return nil }
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiFormat = apiFormat
        self.credentialKind = credentialRef?["kind"] as? String ?? "env"
        self.credentialReference = credentialRef?["value"] as? String ?? provider["auth_env"] as? String ?? ""
        self.keyHeader = credentialRef?["header"] as? String ?? catalog?["key_header"] as? String ?? "Authorization"
        self.modelId = model.id
        self.upstreamModel = model.upstreamModel
        self.models = parsedModels
        self.modelsURL = catalog?["models_url"] as? String ?? ""
        self.source = routing?["source"] as? String ?? ""
        self.modelPrefix = modelPrefix
        self.contextWindow = model.contextWindow
    }
}

struct ConfiguredProviderModelEntry: Identifiable, Equatable {
    let id: String
    let displayName: String
    let upstreamModel: String
    let contextWindow: Int?

    init?(model: [String: Any], modelPrefix: String = "") {
        guard let id = model["id"] as? String else { return nil }
        let normalized = ConfiguredProviderModelEntry.normalized(id: id, upstreamModel: model["upstream_model"] as? String ?? "", modelPrefix: modelPrefix)
        self.id = normalized.id
        self.displayName = model["display_name"] as? String ?? normalized.id
        self.upstreamModel = normalized.upstreamModel
        self.contextWindow = model["context_window"] as? Int
    }

    private static func normalized(id: String, upstreamModel: String, modelPrefix: String) -> (id: String, upstreamModel: String) {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPrefix = modelPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanUpstream = upstreamModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrefix.isEmpty else {
            return (cleanID, cleanUpstream)
        }
        if cleanID.hasPrefix(cleanPrefix) {
            if cleanUpstream.isEmpty {
                cleanUpstream = String(cleanID.dropFirst(cleanPrefix.count))
            }
            return (cleanID, cleanUpstream)
        }
        if cleanUpstream.isEmpty {
            cleanUpstream = cleanID
        }
        return (cleanPrefix + safeModelSlug(cleanID), cleanUpstream)
    }

    private static func safeModelSlug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars {
            let isLetter = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            if isLetter || isDigit {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        let slug = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else { return "model" }
        guard let first = slug.unicodeScalars.first,
              first.value >= 97,
              first.value <= 122 else {
            return "model-\(slug)"
        }
        return slug
    }
}

struct ProviderHealthSnapshot: Equatable {
    let saved: Int
    let available: Int
    let hidden: [GatewayHiddenModel]
}

struct UnifiedModelEntry: Identifiable, Equatable {
    let id: String
    let modelId: String
    let displayName: String?
    let origin: String
    let originLabel: String
    let detail: String
    let contextWindow: Int?
}

struct DesktopAcceptanceEvidence: Equatable {
    let available: Bool
    let evidencePath: String
    let manualAvailable: Bool
    let manualEvidencePath: String
    let proofRoot: String
    let manualStatus: String
    let startCommand: String
    let gateway: String
    let catalog: String
    let tempConfig: String
    let pickerData: String
    let routeProof: String
    let globalFiles: String

    static func load(bundle: Bundle = .main) -> DesktopAcceptanceEvidence {
        let automaticPath = evidencePath(bundle: bundle, name: "codex-desktop-acceptance")
        let manualPath = evidencePath(bundle: bundle, name: "codex-desktop-manual-proof")
        let automaticJSON = readJSON(path: automaticPath)
        let manualJSON = readJSON(path: manualPath)
        guard automaticJSON != nil || manualJSON != nil else {
            return DesktopAcceptanceEvidence(
                available: false,
                evidencePath: automaticPath,
                manualAvailable: false,
                manualEvidencePath: manualPath,
                proofRoot: defaultProofRoot(),
                manualStatus: "not run",
                startCommand: manualProofCommand(bundle: bundle),
                gateway: "not run",
                catalog: "not run",
                tempConfig: "not run",
                pickerData: "not run",
                routeProof: "not run",
                globalFiles: "not run"
            )
        }
        let primary = manualJSON ?? automaticJSON ?? [:]
        let pickerSource = automaticJSON ?? manualJSON ?? [:]
        let routedModels = pickerSource["app_server_demo_models"] as? [[String: Any]] ?? []
        let catalogCount = ((primary["gateway_model_health"] as? [String: Any])?["healthy"] as? Int) ?? routedModels.count
        return DesktopAcceptanceEvidence(
            available: true,
            evidencePath: automaticPath,
            manualAvailable: manualJSON != nil,
            manualEvidencePath: manualPath,
            proofRoot: primary["proof_root"] as? String ?? defaultProofRoot(),
            manualStatus: manualStatus(primary["manual_status"] as? String),
            startCommand: manualProofCommand(bundle: bundle),
            gateway: (primary["gateway_health_ok"] as? Bool) == true ? "gateway ok" : "gateway missing",
            catalog: (primary["gateway_models_include_demo"] as? Bool) == true ? "catalog ok: \(catalogCount) models" : "catalog pending",
            tempConfig: (primary["generated_config_model"] as? String) == "gpt-5.5" ? "temp default gpt-5.5" : "temp config invalid",
            pickerData: !routedModels.isEmpty && routedModels.allSatisfy { ($0["hidden"] as? Bool) == false } ? "picker data has \(routedModels.count) routed models" : "picker data incomplete",
            routeProof: routeProof(primary["route_proof_status"] as? String),
            globalFiles: globalFiles(primary)
        )
    }

    private static func evidencePath(bundle: Bundle, name: String) -> String {
        let bundleSibling = bundle.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(name)/evidence.json")
            .path
        if FileManager.default.fileExists(atPath: bundleSibling) {
            return bundleSibling
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/\(name)/evidence.json")
            .path
    }

    private static func readJSON(path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func manualProofCommand(bundle: Bundle) -> String {
        let root = repositoryRoot(bundle: bundle)
        return "cd \(shellQuoted(root)) && ./scripts/codex-desktop-manual-proof.sh"
    }

    private static func repositoryRoot(bundle: Bundle) -> String {
        let fileManager = FileManager.default
        let distURL = bundle.bundleURL.deletingLastPathComponent()
        let bundledRoot = distURL.deletingLastPathComponent()
        if distURL.lastPathComponent == "dist",
           fileManager.fileExists(atPath: bundledRoot.appendingPathComponent("scripts/codex-desktop-manual-proof.sh").path) {
            return bundledRoot.path
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        if fileManager.fileExists(atPath: cwd.appendingPathComponent("scripts/codex-desktop-manual-proof.sh").path) {
            return cwd.path
        }
        let parent = cwd.deletingLastPathComponent()
        if fileManager.fileExists(atPath: parent.appendingPathComponent("scripts/codex-desktop-manual-proof.sh").path) {
            return parent.path
        }
        return cwd.path
    }

    private static func defaultProofRoot() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RelayKit/DesktopProof")
            .path
    }

    private static func globalFiles(_ json: [String: Any]) -> String {
        let configBefore = json["global_config_signature_before"] as? String
        let configAfter = json["global_config_signature_after"] as? String
        let authBefore = json["global_auth_signature_before"] as? String
        let authAfter = json["global_auth_signature_after"] as? String
        return configBefore == configAfter && authBefore == authAfter ? "global unchanged" : "global changed"
    }

    private static func manualStatus(_ status: String?) -> String {
        switch status {
        case "setup_preflight_passed":
            "manual setup ready"
        case "awaiting_user_login":
            "waiting for isolated login"
        case "awaiting_user_model_selection":
            "waiting for routed model request"
        case "manual_route_proof_passed", "manual_route_proof_succeeded":
            "manual proof passed"
        case "manual_route_proof_missing":
            "usage proof missing"
        case "official_reauthentication_required":
            "需要重新认证官方 Codex"
        case let status?:
            status
        case nil:
            "not run"
        }
    }

    private static func routeProof(_ status: String?) -> String {
        switch status {
        case "blocked_by_desktop_gui_global_config_write":
            "blocked: Desktop writes global config"
        case "not_started_manual_user_step":
            "manual: ready for user"
        case "waiting_for_relaykit_usage_event":
            "manual: waiting for usage"
        case "succeeded", "routed_provider_and_official_requests":
            "manual: succeeded"
        case "missing_relaykit_usage_event", "missing_provider_or_official_usage_event":
            "manual: usage missing"
        case "waiting_for_provider_and_official_usage_events":
            "manual: waiting for provider + official usage"
        case "official_auth_required":
            "需要重新认证官方 Codex"
        case "missing_required_usage_event":
            "manual: missing demo or official usage"
        case let status?:
            status
        case nil:
            "not run"
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

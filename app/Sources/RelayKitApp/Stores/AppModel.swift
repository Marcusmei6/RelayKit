import AppKit
import Foundation
import RelayKitCore

@MainActor
final class AppModel: ObservableObject {
    private enum OfficialAuthState {
        static let notConnected = "not connected"
        static let deviceLoginPending = "device login pending"
        static let loginAvailable = "login available"
        static let routeVerified = "route verified"
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
            UserDefaults.standard.set(codexTargetPath, forKey: "codexTargetPath")
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
    @Published var officialAuthStatus = OfficialAuthState.notConnected
    @Published var officialAuthDetail = "No current isolated Codex login."
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
        codexTargetPath = UserDefaults.standard.string(forKey: "codexTargetPath") ?? ""
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

    func startGateway() {
        do {
            let configPath = runtimeProviderConfigPath()
            let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let credentialHandoff = try GatewayCredentialHandoff.encode(configData: configData) { reference in
                try KeychainCredentialStore.load(service: reference)
            }
            try gateway.start(
                binaryPath: gatewayBinaryPath,
                configPath: configPath,
                usageLogPath: usageLogPath,
                credentialHandoff: credentialHandoff
            )
            gatewayStatus = "running"
            message = "Gateway started on 127.0.0.1:19777"
        } catch {
            gatewayStatus = "error"
            message = error.localizedDescription
        }
    }

    func stopGateway() {
        gateway.stop()
        gatewayStatus = "stopped"
        message = "Gateway stopped"
    }

    func restartGateway() {
        stopGateway()
        startGateway()
    }

    func refreshHealth() async {
        do {
            gatewayStatus = try await client.health()
            message = "Gateway health ok"
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
            let response = try await client.modelList()
            models = response.data
            gatewayModelHealth = response.modelHealth ?? .empty
            message = "Loaded \(models.count) model(s)"
        } catch {
            message = gateway.isRunning ? error.localizedDescription : ProviderFormLabels.gatewayStoppedGuidance
        }
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
        guard officialAuthStatus != OfficialAuthState.loginAvailable,
              officialAuthStatus != OfficialAuthState.routeVerified else {
            message = "Official login is already connected; disconnect first to sign in again."
            return
        }
        do {
            try ensureOfficialAuthDirs()
            officialAuthInProgress = true
            officialAuthStatus = OfficialAuthState.deviceLoginPending
            officialAuthDetail = "Waiting for Codex device authorization in RelayKit isolated storage."
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
                        self?.officialAuthStatus = OfficialAuthState.notConnected
                        self?.officialAuthDetail = "Device authorization did not complete."
                    }
                    self?.refreshOfficialAuthStatus()
                }
            }
            message = "Opened official device login"
        } catch {
            officialAuthInProgress = false
            officialAuthStatus = OfficialAuthState.notConnected
            officialAuthDetail = error.localizedDescription
            message = error.localizedDescription
        }
    }

    func refreshOfficialAuthStatus() {
        Task {
            do {
                try ensureOfficialAuthDirs()
                let result = await Self.runCodex(arguments: ["login", "status"], environment: officialCodexEnvironment())
                switch result {
                case .success(let output):
                    if Self.codexLoginStatusIsLoggedIn(output) {
                        if Self.officialRouteProofVerified() {
                            officialAuthStatus = OfficialAuthState.routeVerified
                            officialAuthDetail = "Current proof verified official and provider routes."
                        } else {
                            officialAuthStatus = OfficialAuthState.loginAvailable
                            officialAuthDetail = "Isolated Codex login is available; run official proof to verify routing."
                        }
                        officialAuthURL = ""
                        officialDeviceCode = ""
                        officialDeviceCodeCopied = false
                    } else {
                        officialAuthStatus = OfficialAuthState.notConnected
                        officialAuthDetail = "Use Connect Official to sign in with Codex device authorization."
                        officialAuthURL = ""
                        officialDeviceCode = ""
                        officialDeviceCodeCopied = false
                    }
                case .failure(let error):
                    officialAuthStatus = OfficialAuthState.notConnected
                    officialAuthDetail = error.localizedDescription
                }
            } catch {
                officialAuthStatus = OfficialAuthState.notConnected
                officialAuthDetail = error.localizedDescription
            }
        }
    }

    func disconnectOfficial() {
        officialAuthProcess?.terminate()
        officialAuthProcess = nil
        officialAuthInProgress = false
        do {
            let codexHome = RelayKitPaths.officialCodexHomePath()
            if FileManager.default.fileExists(atPath: codexHome) {
                try FileManager.default.removeItem(atPath: codexHome)
            }
            try ensureOfficialAuthDirs()
            officialAuthStatus = OfficialAuthState.notConnected
            officialAuthDetail = "RelayKit isolated official login was removed."
            officialAuthURL = ""
            officialDeviceCode = ""
            officialDeviceCodeCopied = false
            message = "Disconnected RelayKit official login"
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
            var backupCreated = false
            if FileManager.default.fileExists(atPath: providerConfigPath) {
                let backup = providerConfigPath + ".bak." + UUID().uuidString
                try FileManager.default.copyItem(atPath: providerConfigPath, toPath: backup)
                backupCreated = true
            }
            try pretty.write(to: URL(fileURLWithPath: providerConfigPath), options: .atomic)
            providerConfigText = String(data: pretty, encoding: .utf8) ?? providerConfigText
            refreshConfiguredProviders(from: pretty)
            message = ProviderFormLabels.providerConfigSavedMessage(backupCreated: backupCreated)
        } catch {
            message = error.localizedDescription
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
            if draft.credentialKind == "keychain" && !keychainCredential.isEmpty {
                try KeychainCredentialStore.save(value: keychainCredential, service: draft.credentialReference)
            }
            var backupCreated = false
            if FileManager.default.fileExists(atPath: providerConfigPath) {
                let backup = providerConfigPath + ".bak." + UUID().uuidString
                try FileManager.default.copyItem(atPath: providerConfigPath, toPath: backup)
                backupCreated = true
            }
            try pretty.write(to: URL(fileURLWithPath: providerConfigPath), options: .atomic)
            providerConfigText = String(data: pretty, encoding: .utf8) ?? ""
            refreshConfiguredProviders(from: pretty)
            let confirmation = ProviderFormLabels.providerAddedMessage(
                storedKey: draft.credentialKind == "keychain" && !keychainCredential.isEmpty,
                backupCreated: backupCreated
            )
            reloadGatewayAfterProviderSave(confirmation: confirmation)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func updateProvider(_ originalProviderId: String, draft: ProviderConfigDraft, keychainCredential: String = "") -> Bool {
        do {
            let existing = try providerConfigData()
            let json = try JSONSerialization.jsonObject(with: existing)
            guard var root = json as? [String: Any],
                  let providers = root["providers"] as? [[String: Any]] else {
                throw ProviderConfigError.invalid("providers array is required")
            }
            root["providers"] = providers.filter { ($0["id"] as? String ?? "") != originalProviderId }
            let filtered = try JSONSerialization.data(withJSONObject: root)
            let pretty = try ProviderConfigDraftWriter.addProvider(draft, to: filtered)
            if draft.credentialKind == "keychain" && !keychainCredential.isEmpty {
                try KeychainCredentialStore.save(value: keychainCredential, service: draft.credentialReference)
            }
            var backupCreated = false
            if FileManager.default.fileExists(atPath: providerConfigPath) {
                let backup = providerConfigPath + ".bak." + UUID().uuidString
                try FileManager.default.copyItem(atPath: providerConfigPath, toPath: backup)
                backupCreated = true
            }
            try pretty.write(to: URL(fileURLWithPath: providerConfigPath), options: .atomic)
            providerConfigText = String(data: pretty, encoding: .utf8) ?? ""
            refreshConfiguredProviders(from: pretty)
            let confirmation = ProviderFormLabels.providerUpdatedMessage(backupCreated: backupCreated)
            reloadGatewayAfterProviderSave(confirmation: confirmation)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private func reloadGatewayAfterProviderSave(confirmation: String) {
        guard gateway.isRunning else {
            message = confirmation
            return
        }
        restartGateway()
        message = gateway.isRunning
            ? "\(confirmation); gateway reloaded"
            : "\(confirmation); gateway reload failed: open Settings and restart gateway"
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

    func activateCodexConfig() async {
        guard !codexTargetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "Codex target path is required"
            return
        }
        do {
            let output = try gateway.activateCodexConfig(
                binaryPath: gatewayBinaryPath,
                source: codexSourcePath,
                target: codexTargetPath
            )
            message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            refreshCodexConnectionStatus()
        } catch {
            message = error.localizedDescription
        }
    }

    var codexConnectionIsConfigured: Bool {
        codexConnectionStatus == "configured"
    }

    var gatewayIsRunning: Bool {
        gateway.isRunning
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
        let path = codexTargetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            codexConnectionStatus = "target not set"
            return
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            codexConnectionStatus = "target missing"
            return
        }
        if text.contains("base_url = \"http://127.0.0.1:19777/v1\"") &&
            text.contains("wire_api = \"responses\"") {
            codexConnectionStatus = "configured"
        } else {
            codexConnectionStatus = "not RelayKit"
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

    private static func codexLoginStatusIsLoggedIn(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("logged in") &&
            !output.localizedCaseInsensitiveContains("not logged in")
    }

    private static func officialRouteProofVerified() -> Bool {
        let url = URL(fileURLWithPath: RelayKitPaths.officialRouteEvidencePath())
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let evidence = object as? [String: Any] else {
            return false
        }
        return evidence["usage_scope"] as? String == "current_run" &&
            evidence["login_status"] as? String == "logged_in" &&
            evidence["current_official_event_found"] as? Bool == true &&
            evidence["current_provider_event_found"] as? Bool == true &&
            evidence["official_route_verified"] as? Bool == true
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

    nonisolated private static func runCodex(arguments: [String], environment: [String: String]) async -> Result<String, Error> {
        await Task.detached {
            do {
                let process = Process()
                configureCodexProcess(process, arguments: arguments, environment: environment)
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

    private func runtimeProviderConfigPath() -> String {
        FileManager.default.fileExists(atPath: providerConfigPath)
            ? providerConfigPath
            : RelayKitPaths.exampleProviderConfigPath()
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

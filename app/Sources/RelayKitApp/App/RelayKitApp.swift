import AppKit
import Foundation
import RelayKitCore
import SwiftUI

@main
@MainActor
final class RelayKitApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let popoverAccessibilityIdentifier = "relaykit-popover-root"
    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var smokeSections = Set<String>()
    private let smokeTab = Tab(rawValue: value(after: "--ui-smoke-tab") ?? "") ?? .connect
    private let smokeShowsProvider = CommandLine.arguments.contains("--ui-smoke-provider")
    private let smokeShowsDetail = CommandLine.arguments.contains("--ui-smoke-detail")
    private let smokeShowsImport = CommandLine.arguments.contains("--ui-smoke-import")
    private let smokeEvidencePath = value(after: "--ui-smoke-evidence")
    private let smokeProviderConfigPath = value(after: "--ui-smoke-provider-config")
    private let smokeUsageLogPath = value(after: "--ui-smoke-usage-log")
    private let smokeUsageRefreshIntervalSeconds = UInt64(value(after: "--ui-smoke-usage-refresh-interval") ?? "") ?? 60
    private let smokeCatalogURL = value(after: "--ui-smoke-catalog-url")
    private let smokeSeedKeychainService = value(after: "--ui-smoke-seed-keychain")
    private let smokeModelHealthFixture = CommandLine.arguments.contains("--ui-smoke-model-health-fixture")
    private let smokeSkipsGatewayExercise = CommandLine.arguments.contains("--ui-smoke-skip-gateway-exercise")
    private let smokeKeepsPopoverOpen = CommandLine.arguments.contains("--ui-smoke-keep-open")
    private var smokeQuitMenuVisible = false
    private var outsideClickMonitor: Any?

    static func main() {
        if CommandLine.arguments.contains("--verify-bundled-gateway") {
            exit(BundledGatewayVerifier.run(arguments: CommandLine.arguments))
        }
        if let service = value(after: "--delete-dogfood-keychain") {
            exit(deleteFixtureKeychain(service: service, requiredPrefix: "relaykit.provider.dogfood"))
        }
        if let service = value(after: "--delete-desktop-proof-keychain") {
            exit(deleteFixtureKeychain(service: service, requiredPrefix: "relaykit.desktop-proof.provider-"))
        }
        let app = NSApplication.shared
        let delegate = RelayKitApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        _ = delegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--ui-smoke") {
            model.opensOfficialAuthURL = false
            seedSmokeKeychainCredentialIfNeeded()
        }
        if let smokeProviderConfigPath {
            model.useTemporaryProviderConfigPath(smokeProviderConfigPath)
        }
        if let smokeUsageLogPath {
            model.usageLogPath = smokeUsageLogPath
        }
        if smokeModelHealthFixture {
            model.useSmokeModelHealthFixture()
        }
        if let smokeCatalogURL, let url = URL(string: smokeCatalogURL) {
            model.setLocalCatalogURL(url)
        }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "RelayKit")
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "RelayKit"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.statusItem = statusItem

        popover.behavior = smokeKeepsPopoverOpen ? .applicationDefined : .transient
        popover.contentSize = NSSize(width: 520, height: 680)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(initialTab: smokeTab, showProviderForm: smokeShowsProvider, showCatalogDetail: smokeShowsDetail, showImportCandidate: smokeShowsImport, usageRefreshIntervalSeconds: smokeUsageRefreshIntervalSeconds) { [weak self] section in
                self?.smokeSections.insert(section)
            }
                .environmentObject(model)
                .frame(width: 520, height: 680)
        )
        popover.delegate = self
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.popover.performClose(nil)
            }
        }

        if CommandLine.arguments.contains("--ui-smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApplication.shared.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.model.refreshLocalCatalog()
                        if self.smokeTab == .usage {
                            await self.model.refreshUsageSummary()
                        }
                        let gatewayExercise = await self.runGatewayControlSmokeExercise()
                        self.writeSmokeEvidenceRepeatedly(gatewayExercise: gatewayExercise)
                    }
                }
            }
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard !CommandLine.arguments.contains("--ui-smoke") else { return }
        popover.performClose(nil)
    }

    func popoverDidShow(_ notification: Notification) {
        attachPopoverAccessibilityRoot()
    }

    func popoverDidClose(_ notification: Notification) {
        detachPopoverAccessibilityRoot()
    }

    private func attachPopoverAccessibilityRoot() {
        guard let statusItem, let button = statusItem.button else { return }
        popover.setAccessibilityElement(true)
        popover.setAccessibilityRole(.popover)
        popover.setAccessibilityIdentifier(Self.popoverAccessibilityIdentifier)
        popover.setAccessibilityParent(button)
        button.setAccessibilityChildren([popover])
    }

    private func detachPopoverAccessibilityRoot() {
        statusItem?.button?.setAccessibilityChildren([])
        popover.setAccessibilityParent(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        detachPopoverAccessibilityRoot()
        model.stopGateway()
        model.stopOfficialAuthProcessForShutdown()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            showStatusMenu(sender)
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApplication.shared.activate()
        }
    }

    private func showStatusMenu(_ button: NSStatusBarButton) {
        smokeQuitMenuVisible = true
        smokeSections.insert("quit-menu")
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit RelayKit", action: #selector(quitRelayKit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func quitRelayKit(_ sender: Any?) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        NSApplication.shared.terminate(sender)
    }

    private static func value(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else {
            return nil
        }
        return CommandLine.arguments[index + 1]
    }

    private static func deleteFixtureKeychain(service: String, requiredPrefix: String) -> Int32 {
        guard service.hasPrefix(requiredPrefix),
              !service.contains("\n"),
              !service.contains("\r") else {
            return 2
        }
        do {
            try KeychainCredentialStore.delete(service: service)
            return 0
        } catch {
            FileHandle.standardError.write(Data("RelayKit fixture Keychain cleanup failed\n".utf8))
            return 1
        }
    }

    private func seedSmokeKeychainCredentialIfNeeded() {
        guard let smokeSeedKeychainService else { return }
        do {
            try KeychainCredentialStore.save(value: "relaykit-ui-smoke-key", service: smokeSeedKeychainService)
        } catch {
            fputs("failed to seed UI smoke keychain credential\n", stderr)
        }
    }

    private func runGatewayControlSmokeExercise() async -> [String: Any]? {
        guard smokeTab == .connect, !smokeSkipsGatewayExercise, !smokeShowsProvider, !smokeShowsDetail, !smokeShowsImport else {
            return nil
        }

        model.stopGateway()
        model.startGateway()
        let startProcessID = model.gatewayProcessIdentifier
        let startProcessRunning = model.gatewayIsRunning
        let healthStatus = await waitForGatewayHealth()
        let gatewayModelCount = await waitForGatewayModels()
        model.restartGateway()
        let restartProcessID = model.gatewayProcessIdentifier
        let restartProcessRunning = model.gatewayIsRunning
        let restartHealthStatus = await waitForGatewayHealth()
        model.stopGateway()
        await model.refreshHealth()

        return [
            "start_invoked": true,
            "start_process_id": startProcessID ?? 0,
            "start_process_running": startProcessRunning,
            "health_status": healthStatus,
            "gateway_model_count": gatewayModelCount,
            "restart_invoked": true,
            "restart_process_id": restartProcessID ?? 0,
            "restart_process_running": restartProcessRunning,
            "restart_health_status": restartHealthStatus,
            "stop_status": model.gatewayStatus,
            "post_stop_health_status": model.gatewayStatus,
        ]
    }

    private func waitForGatewayHealth() async -> String {
        for _ in 0..<8 {
            await model.refreshHealth()
            if model.gatewayStatus == "ok" {
                return model.gatewayStatus
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return model.gatewayStatus
    }

    private func waitForGatewayModels() async -> Int {
        for _ in 0..<8 {
            await model.refreshModels()
            if !model.models.isEmpty {
                return model.models.count
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return model.models.count
    }

    private func writeSmokeEvidenceRepeatedly(gatewayExercise: [String: Any]?, remaining: Int = 240) {
        writeSmokeEvidence(gatewayExercise: gatewayExercise)
        guard remaining > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.writeSmokeEvidenceRepeatedly(gatewayExercise: gatewayExercise, remaining: remaining - 1)
        }
    }

    private func writeSmokeEvidence(gatewayExercise: [String: Any]?) {
        guard let smokeEvidencePath else { return }
        let buttonFrame = statusItem?.button?.window?.frame ?? .zero
        let activeTab = smokeShowsProvider ? "provider" : smokeTab.rawValue
        let contentWindow = popover.contentViewController?.view.window
        let referenceLabels = model.localCatalog?.sourceGroups.map(\.publicLabel) ?? []
        let importGroup = model.localCatalog?.sourceGroups.first
        let configuredLabels = model.configuredProviders.map(\.name)
        let configuredModelLabels = model.configuredProviders.flatMap { $0.models.map(\.id) }
        let firstProviderHealth = model.configuredProviders.first.map { model.providerHealth(for: $0) }
        let realDemo = model.configuredProviders.first { $0.id == "demo" || $0.name == "Demo Anthropic" }
        let realDemoModelIDs = Set(realDemo?.models.map(\.id) ?? [])
        let unifiedModels = model.unifiedModels
        let unifiedModelIDs = Set(unifiedModels.map(\.modelId))
        let unifiedConfiguredCount = unifiedModels.filter { $0.origin == "configured" }.count
        let unifiedCatalogCount = unifiedModels.filter { $0.origin == "catalog" }.count
        let officialConnected = model.officialAuthStatus == "login available" || model.officialAuthStatus == "route verified"
        let usageAnalytics = UsageAnalytics(model.usageSummaries)
        let usageSevenDayBuckets = usageAnalytics.activityBuckets(range: .sevenDays)
        let demoModelRowsPresent = referenceLabels.contains { label in
            label == "qwen3-coder" || label == "claude-example"
        } || configuredLabels.contains { label in
            label == "qwen3-coder" || label == "claude-example"
        } || configuredModelLabels.contains { label in
            label == "qwen3-coder" || label == "claude-example"
        }
        var connectEvidence: [String: Any] = [
            "display_mode": "model-access",
            "provider_config_path_is_app_support": model.providerConfigPath == RelayKitPaths.providerConfigPath(),
            "stale_tmp_provider_config_recovered": model.staleProviderConfigPreferenceRecovered,
            "status_summary_inline": smokeSections.contains("status-summary-inline"),
            "model_access_and_model_list_merged": smokeSections.contains("model-access-merged"),
            "duplicate_empty_state": smokeSections.contains("provider-empty-state") && smokeSections.contains("model-empty-state"),
            "official_provider_row_visible": smokeSections.contains("official-provider-row"),
            "official_provider_row_managed_by_relaykit": smokeSections.contains("official-provider-row"),
            "official_provider_row_actionable": smokeSections.contains("official-provider-row-action"),
            "official_sheet_opened": smokeSections.contains("official-channel-sheet"),
            "official_auth_required_visible": smokeSections.contains("official-auth-required-state"),
            "official_auth_cta_visible": smokeSections.contains("official-auth-cta-action"),
            "official_auth_cta_clicked": smokeSections.contains("official-auth-cta-clicked"),
            "official_auth_cta_has_real_action": smokeSections.contains("official-auth-cta-action"),
            "official_auth_cta_disabled_as_unimplemented": false,
            "official_auth_unimplemented_visible": false,
            "official_auth_in_progress": model.officialAuthInProgress,
            "official_auth_process_id_present": model.officialAuthProcessIdentifier != nil,
            "official_device_url_captured": !model.officialAuthURL.isEmpty,
            "official_device_code_captured": !model.officialDeviceCode.isEmpty,
            "official_device_code_copied": model.officialDeviceCodeCopied,
            "official_credential_ref_exists": FileManager.default.fileExists(atPath: RelayKitPaths.officialCredentialRefPath()),
            "official_current_status": model.officialAuthStatus,
            "official_connected_by_login_status": officialConnected,
            "official_connected_cta_disabled": officialConnected && smokeSections.contains("official-connected-cta-disabled"),
            "official_connected_device_code_hidden": officialConnected && model.officialAuthURL.isEmpty && model.officialDeviceCode.isEmpty,
            "official_connected_click_does_not_start_login": officialConnected && !model.officialAuthInProgress && model.officialAuthProcessIdentifier == nil && !smokeSections.contains("official-auth-cta-clicked"),
            "official_route_verified_status": model.officialAuthStatus == "route verified",
            "official_product_actions_visible": smokeSections.contains("official-product-auth-actions"),
            "official_authenticate_action_visible": smokeSections.contains("official-auth-cta-action"),
            "official_status_refresh_action_visible": smokeSections.contains("official-status-refresh-action"),
            "official_reauth_action_visible": false,
            "official_disconnect_action_visible": smokeSections.contains("official-disconnect-action"),
            "official_device_login_visible": smokeSections.contains("official-device-login-visible"),
            "official_open_signin_link_action_visible": smokeSections.contains("official-open-signin-link-action"),
            "official_open_signin_link_clicked": smokeSections.contains("official-open-signin-link-clicked"),
            "official_copy_device_code_action_visible": smokeSections.contains("official-copy-device-code-action"),
            "official_copy_device_code_clicked": smokeSections.contains("official-copy-device-code-clicked"),
            "official_isolated_desktop_entry_visible": smokeSections.contains("official-isolated-desktop-entry"),
            "official_token_boundary_visible": smokeSections.contains("official-token-boundary"),
            "official_debug_status_visible": false,
            "official_debug_actions_visible": smokeSections.contains("official-open-codex-desktop-action") ||
                smokeSections.contains("official-run-isolated-check-action") ||
                smokeSections.contains("official-copy-command-action"),
            "official_mock_passthrough_status_visible": smokeSections.contains("official-mock-passthrough-verified"),
            "official_not_connected_status_visible": model.officialAuthStatus == "not connected",
            "official_device_login_pending_status_visible": smokeSections.contains("official-device-login-pending-state"),
            "official_login_available_status_visible": smokeSections.contains("official-login-available-state"),
            "official_route_verified_status_visible": smokeSections.contains("official-route-verified-state"),
            "official_state_details_collapsed": smokeSections.contains("official-state-details-collapsed"),
            "official_state_details_expanded": smokeSections.contains("official-state-details-expanded"),
            "official_login_required_status_visible": smokeSections.contains("official-status-login-required"),
            "official_real_auth_not_verified_visible": smokeSections.contains("official-real-auth-not-verified"),
            "official_open_codex_desktop_action_visible": smokeSections.contains("official-open-codex-desktop-action"),
            "official_run_isolated_check_action_visible": smokeSections.contains("official-run-isolated-check-action"),
            "official_copy_command_action_visible": smokeSections.contains("official-copy-command-action"),
            "official_run_isolated_check_clicked": smokeSections.contains("official-run-isolated-check-clicked"),
            "official_copy_command_clicked": smokeSections.contains("official-copy-command-clicked"),
            "official_proof_check_in_progress": model.proofCheckInProgress,
            "connect_first_screen_locked": smokeSections.contains("status-summary-inline") &&
                smokeSections.contains("model-access-merged") &&
                smokeSections.contains("official-provider-row") &&
                !smokeSections.contains("codex-card-relaykit-status"),
            "configured_provider_count": model.configuredProviders.count,
            "configured_provider_labels": configuredLabels,
            "configured_provider_model_labels": configuredModelLabels,
            "unified_model_count": unifiedModels.count,
            "unified_model_configured_count": unifiedConfiguredCount,
            "unified_model_catalog_count": unifiedCatalogCount,
            "unified_model_has_official_and_provider_catalog_fixture": unifiedModelIDs.isSuperset(of: ["gpt-5.5", "demo/claude-haiku-4-5"]),
            "unified_model_has_demo_fixture": unifiedModelIDs.isSuperset(of: ["demo/claude-haiku-4-5", "demo/claude-sonnet-4-6"]),
            "header_models_match_unified_models": true,
            "unified_model_ids_redacted": true,
            "status_under_codex_card": smokeSections.contains("codex-card-relaykit-status"),
            "top_level_relaykit_status_visible": smokeSections.contains("relaykit-product-status"),
            "catalog_url_uses_shared_18787": model.localCatalogURL.port == 18787,
            "desktop_acceptance_available": model.desktopAcceptance.available,
            "desktop_acceptance_gateway": model.desktopAcceptance.gateway,
            "desktop_acceptance_catalog": model.desktopAcceptance.catalog,
            "desktop_acceptance_temp_config": model.desktopAcceptance.tempConfig,
            "desktop_acceptance_picker_data": model.desktopAcceptance.pickerData,
            "desktop_acceptance_route_proof": model.desktopAcceptance.routeProof,
            "desktop_acceptance_global_files": model.desktopAcceptance.globalFiles,
            "desktop_acceptance_manual_available": model.desktopAcceptance.manualAvailable,
            "desktop_acceptance_manual_status": model.desktopAcceptance.manualStatus,
            "desktop_acceptance_manual_route_status": model.desktopAcceptance.routeProof,
            "desktop_acceptance_proof_root": model.desktopAcceptance.proofRoot,
            "desktop_acceptance_start_command": model.desktopAcceptance.startCommand,
            "desktop_acceptance_manual_entry_visible": smokeSections.contains("desktop-acceptance-manual-proof-entry"),
            "discovered_row_labels": referenceLabels,
            "discovered_catalog_model_count": model.localCatalog?.modelCount ?? 0,
            "discovered_catalog_source_group_count": model.localCatalog?.sourceGroups.count ?? 0,
            "catalog_status": model.localCatalogStatus,
            "auth_state": model.localCatalogAuthState,
            "model_ids_redacted": true,
            "source_names_redacted": true,
            "demo_model_rows_present": demoModelRowsPresent,
            "provider_edit_opened": smokeSections.contains("provider-edit-modal"),
            "provider_edit_row_action_invoked": smokeSections.contains("configured-provider-row-action"),
            "provider_edit_has_save": smokeSections.contains("provider-edit-mode"),
            "provider_edit_has_add_cta": false,
            "provider_edit_base_url_prefilled": smokeSections.contains("provider-edit-base-url-prefilled"),
            "provider_edit_models_loaded": smokeSections.contains("provider-edit-models-loaded"),
            "provider_health_summary_visible": smokeSections.contains("provider-health-summary") ||
                smokeSections.contains("provider-health-summary-hidden") ||
                smokeSections.contains("provider-health-counts"),
            "provider_health_has_hidden": smokeSections.contains("provider-health-summary-hidden"),
            "provider_health_saved_count": firstProviderHealth?.saved ?? 0,
            "provider_health_available_count": firstProviderHealth?.available ?? 0,
            "provider_health_hidden_count": firstProviderHealth?.hidden.count ?? 0,
            "provider_hidden_models_toggle_visible": smokeSections.contains("provider-hidden-models-toggle"),
            "provider_hidden_model_reasons_visible": smokeSections.contains("provider-hidden-model-reasons"),
            "real_demo_provider_clicked": realDemo != nil,
            "real_demo_provider_config_path": model.providerConfigPath == RelayKitPaths.providerConfigPath() ||
                model.providerConfigPath.hasPrefix("/tmp/relaykit-") ||
                model.providerConfigPath.hasPrefix("/private/tmp/relaykit-"),
            "real_demo_base_url_visible": realDemo?.baseURL == "https://example.test/api" ||
                realDemo?.baseURL.hasPrefix("http://127.0.0.1:") == true,
            "real_demo_key_saved_visible": realDemo?.credentialKind == "keychain",
            "real_demo_models_visible": realDemo != nil &&
                !realDemoModelIDs.isEmpty &&
                realDemoModelIDs.allSatisfy { $0.hasPrefix("demo/") },
            "import_mode_opened": smokeSections.contains("provider-import-modal"),
            "import_row_action_invoked": smokeSections.contains("discovered-row-action"),
            "import_has_prefilled_fields": smokeSections.contains("provider-import-prefilled-fields"),
            "import_has_multiple_model_rows": (importGroup?.count ?? 0) > 1,
            "import_model_rows_collapsible": false,
            "import_model_list_bounded": smokeSections.contains("provider-model-table"),
            "import_has_missing_required_fields": smokeSections.contains("provider-import-missing-required-fields"),
            "import_selected_model_count": importGroup?.count ?? 0,
            "import_bridge_host_detected": !(importGroup?.bridgeHost ?? "").isEmpty,
            "import_execution_base_url_prefilled": !(importGroup?.executionBaseURL ?? "").isEmpty,
            "import_protocol_checked": importGroup?.protocolSummary != nil,
            "import_protocol_requires_choice": importGroup?.protocolSummary == "unknown" || importGroup?.protocolSummary == "mixed",
            "import_uses_first_model_only": false,
            "redacted_only_detail_opened": false,
            "add_strip_available": smokeSections.contains("add-strip"),
            "add_strip_opens_provider_modal": smokeShowsProvider && smokeSections.contains("add-strip") && smokeSections.contains("add-strip-action") && smokeSections.contains("provider-modal"),
            "add_form_has_save": smokeSections.contains("provider-add-mode"),
            "add_form_has_gateway_port_control": false,
            "provider_form_user_main_flow": smokeSections.contains("provider-name-field") &&
                smokeSections.contains("provider-base-url-field") &&
                smokeSections.contains("provider-api-key-field") &&
                smokeSections.contains("provider-model-detection-entry") &&
                smokeSections.contains("provider-model-table"),
            "provider_form_raw_protocol_visible": smokeSections.contains("provider-protocol-field"),
            "provider_form_credential_mode_visible": smokeSections.contains("credential-reference-form") || smokeSections.contains("provider-credential-mode-field"),
            "provider_form_keychain_ref_visible_on_main": smokeSections.contains("provider-credential-ref-field") || smokeSections.contains("provider-keychain-ref-main"),
            "provider_form_catalog_url_visible_on_main": smokeSections.contains("provider-models-url-field"),
            "provider_form_model_mapping_visible_on_main": smokeSections.contains("provider-model-mapping-field"),
            "provider_form_use_models_visible": smokeSections.contains("provider-use-models-entry"),
            "provider_form_detect_models_visible": smokeSections.contains("provider-model-detection-entry"),
            "provider_form_test_connection_visible": smokeSections.contains("provider-connection-test-entry"),
            "provider_connection_connected_visible": smokeSections.contains("provider-connection-connected"),
            "provider_connection_reachable_visible": smokeSections.contains("provider-connection-reachable"),
            "provider_connection_auth_failed_visible": smokeSections.contains("provider-connection-auth_failed"),
            "provider_connection_model_list_unavailable_visible": smokeSections.contains("provider-connection-model_list_unavailable"),
            "provider_connection_network_failed_visible": smokeSections.contains("provider-connection-network_failed"),
            "provider_connection_use_discovered_visible": smokeSections.contains("provider-connection-use-discovered-models"),
            "provider_connection_counts_separated": smokeSections.contains("provider-connection-counts-separated"),
            "provider_connection_use_reachable_visible": smokeSections.contains("provider-connection-use-reachable-visible"),
            "provider_connection_used_reachable_models_only": smokeSections.contains("provider-connection-used-reachable-models-only"),
            "provider_form_model_table_visible": smokeSections.contains("provider-model-table"),
            "provider_model_reachable_row_visible": smokeSections.contains("provider-model-reachable-row"),
            "provider_model_unavailable_row_visible": smokeSections.contains("provider-model-unavailable-row"),
            "protocol_tag_distinguishes_codex_route_and_upstream": smokeSections.contains("provider-codex-route-chip") &&
                smokeSections.contains("provider-upstream-protocol-chip"),
            "provider_model_main_field_count": smokeSections.contains("provider-model-id-main-field") ? 1 : 0,
            "provider_display_name_visible_on_main": smokeSections.contains("provider-display-name-main-field"),
            "provider_upstream_model_visible_on_main": smokeSections.contains("provider-upstream-model-main-field"),
            "api_key_input_visible": smokeSections.contains("provider-api-key-field"),
            "api_key_saved_state_visible": smokeSections.contains("api-key-saved-state"),
            "api_key_saved_mask_control_visible": smokeSections.contains("api-key-saved-masked-control"),
            "api_key_masked_field_visible": smokeSections.contains("api-key-saved-masked-control"),
            "api_key_saved_eye_visible": smokeSections.contains("api-key-eye-saved-state"),
            "saved_key_fake_eye_visible": false,
            "saved_key_disabled_eye_reason_visible": false,
            "saved_key_unavailable_visible": smokeSections.contains("api-key-saved-key-unavailable"),
            "saved_key_reveal_visible": smokeSections.contains("api-key-saved-input-visible"),
            "saved_key_eye_toggle_works": smokeSections.contains("api-key-saved-masked-control") &&
                smokeSections.contains("api-key-saved-input-visible") &&
                smokeSections.contains("api-key-eye-toggle-action"),
            "api_key_new_eye_visible": smokeSections.contains("api-key-eye-new-input"),
            "api_key_new_input_hidden_visible": smokeSections.contains("api-key-new-input-hidden"),
            "api_key_new_input_visible": smokeSections.contains("api-key-new-input-visible"),
            "api_key_eye_toggle_clicked": smokeSections.contains("api-key-eye-toggle-action"),
            "new_key_eye_toggle_clicked": smokeSections.contains("api-key-eye-toggle-action"),
            "new_key_eye_toggle_works": ProviderFormLabels.apiKeyEyeLabel(showingKey: false) == "Show API key" &&
                ProviderFormLabels.apiKeyEyeLabel(showingKey: true) == "Hide API key",
            "api_key_replace_available": false,
            "api_key_replace_visible": false,
            "api_key_replace_clicked": smokeSections.contains("api-key-replace-action"),
            "saved_key_plaintext_hidden": smokeSections.contains("api-key-saved-state") &&
                !smokeSections.contains("api-key-plaintext"),
            "saved_key_state_visible": smokeSections.contains("api-key-saved-state"),
            "advanced_default_collapsed": smokeSections.contains("provider-advanced-default-collapsed"),
            "advanced_toggle_row_visible": smokeSections.contains("provider-advanced-toggle-row"),
            "advanced_scrollable_when_expanded": smokeSections.contains("provider-advanced-expanded") &&
                smokeSections.contains("provider-advanced-scroll-container"),
            "advanced_can_collapse_after_expand": smokeSections.contains("provider-advanced-collapsed-after-expand"),
            "advanced_has_protocol_selector": smokeSections.contains("provider-upstream-protocol-selector"),
            "advanced_has_custom_models_url": smokeSections.contains("provider-models-url-field"),
            "advanced_has_custom_auth_header": smokeSections.contains("provider-auth-header-field"),
            "advanced_has_upstream_model_override": smokeSections.contains("provider-upstream-model-override-field"),
            "advanced_raw_fields_hidden": !smokeSections.contains("provider-credential-ref-field") &&
                !smokeSections.contains("provider-keychain-ref-main") &&
                !smokeSections.contains("provider-protocol-field") &&
                !smokeSections.contains("provider-display-name-advanced-field") &&
                !smokeSections.contains("provider-provider-id-field") &&
                !smokeSections.contains("provider-source-field") &&
                !smokeSections.contains("provider-display-prefix-field") &&
                !smokeSections.contains("provider-context-window-field"),
            "ordinary_advanced_labels": ProviderFormLabels.ordinaryAdvancedLabels,
            "enabled_gateway_provider_protocols": ProviderFormLabels.upstreamProtocolOptions.filter(\.isEnabled).map(\.id),
            "planned_provider_protocols": ProviderFormLabels.upstreamProtocolOptions.filter { !$0.isEnabled }.map(\.label),
            "cli_selected": "codex",
        ]
        if let gatewayExercise {
            connectEvidence["gateway_control_exercise"] = gatewayExercise
        }
        let evidence: [String: Any] = [
            "status_item": [
                "visible": buttonFrame.width > 0 && buttonFrame.height > 0,
                "x": buttonFrame.origin.x,
                "y": buttonFrame.origin.y,
                "width": buttonFrame.width,
                "height": buttonFrame.height,
                "kind": "compact-icon",
            ],
            "popover": [
                "shown": popover.isShown,
                "ordinary_window": contentWindow?.styleMask.contains(.titled) ?? false,
                "anchored": popover.isShown && buttonFrame.width > 0 && buttonFrame.height > 0,
                "width": popover.contentSize.width,
                "height": popover.contentSize.height,
            ],
            "surface": [
                "kind": "menu-bar-popover",
                "tab": activeTab,
                "sections": Array(smokeSections).sorted(),
            ],
            "quit_menu_visible": smokeQuitMenuVisible || smokeSections.contains("quit-menu"),
            "settings": [
                "appearance_mode": model.appearanceMode.rawValue,
                "launch_at_login_requested": model.launchAtLoginRequested,
                "launch_at_login_status": model.launchAtLoginStatus,
                "general_group_visible": smokeSections.contains("settings-general-group"),
                "gateway_group_visible": smokeSections.contains("settings-gateway-group"),
                "codex_group_visible": smokeSections.contains("settings-codex-group"),
                "data_privacy_group_visible": smokeSections.contains("settings-data-privacy-group"),
                "developer_collapsed": smokeSections.contains("settings-developer-collapsed"),
                "developer_expanded": smokeSections.contains("settings-developer-expanded"),
                "manual_proof_hidden_when_collapsed": smokeSections.contains("desktop-acceptance-manual-proof-entry-hidden"),
                "manual_proof_visible_when_expanded": smokeSections.contains("desktop-acceptance-manual-proof-entry"),
                "gateway_port": "127.0.0.1:19777",
                "global_codex_activate_visible": false,
            ],
            "usage": [
                "auto_refresh_enabled": smokeSections.contains("usage-auto-refresh-enabled"),
                "refresh_interval_seconds": smokeUsageRefreshIntervalSeconds,
                "refresh_count": model.usageRefreshCount,
                "refresh_in_progress": model.usageRefreshInProgress,
                "summary_background": true,
                "last_refresh_duration_ms": model.usageLastRefreshDurationMs,
                "has_rows": !model.usageSummaries.isEmpty,
                "empty_state_visible": model.usageSummaries.isEmpty && smokeSections.contains("usage-empty-state"),
                "today_tokens": usageAnalytics.todayTokens,
                "today_tokens_label": UsageAnalytics.formatTokens(usageAnalytics.todayTokens),
                "seven_day_tokens": usageAnalytics.sevenDayTokens,
                "seven_day_tokens_label": UsageAnalytics.formatTokens(usageAnalytics.sevenDayTokens),
                "all_time_tokens": usageAnalytics.allTimeTokens,
                "all_time_tokens_label": UsageAnalytics.formatTokens(usageAnalytics.allTimeTokens),
                "requests": usageAnalytics.requestCount,
                "top_model_7d": usageAnalytics.topModelSevenDays ?? "",
                "top_model_7d_readable": UsageAnalytics.readableModelName(usageAnalytics.topModelSevenDays ?? ""),
                "top_model_readable_visible": smokeSections.contains("usage-top-model-readable"),
                "active_days": usageAnalytics.activeDayCount,
                "provider_group_names": usageAnalytics.providerRollups.map(\.name),
                "provider_tokens_labels": usageAnalytics.providerRollups.map { UsageAnalytics.formatTokens($0.tokens) },
                "provider_source_shifted": true,
                "model_count": usageAnalytics.modelRollups.count,
                "activity_bucket_count_7d": usageSevenDayBuckets.count,
                "activity_active_days_7d": usageSevenDayBuckets.filter(\.isActive).count,
                "activity_unit_labels": UsageActivityRange.allCases.map { usageAnalytics.activityUnitLabel(range: $0) },
                "activity_heatmap_visible": smokeSections.contains("usage-activity-heatmap"),
                "activity_range_control_visible": smokeSections.contains("usage-activity-range-control"),
                "activity_unit_label_visible": smokeSections.contains("usage-activity-unit-label"),
                "cost_unavailable_visible": smokeSections.contains("usage-cost-unavailable"),
                "token_unit_formatting": UsageAnalytics.formatTokens(103_912) == "103.9K" &&
                    UsageAnalytics.formatTokens(103_700_000) == "103.7M" &&
                    UsageAnalytics.formatTokens(2_500_000_000) == "2.5B",
            ],
            "connect": connectEvidence,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: smokeEvidencePath), options: .atomic)
        } catch {
            fputs("failed to write UI smoke evidence: \(error)\n", stderr)
        }
    }
}

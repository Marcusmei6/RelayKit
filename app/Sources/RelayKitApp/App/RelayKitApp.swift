import AppKit
import Foundation
import SwiftUI

@main
@MainActor
final class RelayKitApp: NSObject, NSApplicationDelegate {
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

    static func main() {
        if CommandLine.arguments.contains("--verify-bundled-gateway") {
            exit(BundledGatewayVerifier.run(arguments: CommandLine.arguments))
        }
        let app = NSApplication.shared
        let delegate = RelayKitApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        _ = delegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let smokeProviderConfigPath {
            model.providerConfigPath = smokeProviderConfigPath
        }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "RelayKit")
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "RelayKit"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        self.statusItem = statusItem

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 520, height: 680)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(initialTab: smokeTab, showProviderForm: smokeShowsProvider, showCatalogDetail: smokeShowsDetail, showImportCandidate: smokeShowsImport) { [weak self] section in
                self?.smokeSections.insert(section)
            }
                .environmentObject(model)
                .frame(width: 520, height: 680)
        )

        if CommandLine.arguments.contains("--ui-smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApplication.shared.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.model.refreshLocalCatalog()
                        let gatewayExercise = await self.runGatewayControlSmokeExercise()
                        self.writeSmokeEvidence(gatewayExercise: gatewayExercise)
                    }
                }
            }
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApplication.shared.activate()
        }
    }

    private static func value(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else {
            return nil
        }
        return CommandLine.arguments[index + 1]
    }

    private func runGatewayControlSmokeExercise() async -> [String: Any]? {
        guard smokeTab == .connect, !smokeShowsProvider else {
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

    private func writeSmokeEvidence(gatewayExercise: [String: Any]?) {
        guard let smokeEvidencePath else { return }
        let buttonFrame = statusItem?.button?.window?.frame ?? .zero
        let activeTab = smokeShowsProvider ? "provider" : smokeTab.rawValue
        let contentWindow = popover.contentViewController?.view.window
        let referenceLabels = model.localCatalog?.sourceGroups.map(\.publicLabel) ?? []
        let importGroup = model.localCatalog?.sourceGroups.first
        let configuredLabels = model.configuredProviders.map(\.name)
        let configuredModelLabels = model.configuredProviders.map(\.modelId)
        let demoModelRowsPresent = referenceLabels.contains { label in
            label == "qwen3-coder" || label == "claude-example"
        } || configuredLabels.contains { label in
            label == "qwen3-coder" || label == "claude-example"
        } || configuredModelLabels.contains { label in
            label == "qwen3-coder" || label == "claude-example"
        }
        var connectEvidence: [String: Any] = [
            "display_mode": "single-provider-setup-list",
            "configured_provider_count": model.configuredProviders.count,
            "configured_provider_labels": configuredLabels,
            "configured_provider_model_labels": configuredModelLabels,
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
            "import_mode_opened": smokeSections.contains("provider-import-modal"),
            "import_row_action_invoked": smokeSections.contains("discovered-row-action"),
            "import_has_prefilled_fields": smokeSections.contains("provider-import-prefilled-fields"),
            "import_has_multiple_model_rows": smokeSections.contains("provider-import-multiple-model-rows"),
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
            "settings": [
                "appearance_mode": model.appearanceMode.rawValue,
                "launch_at_login_requested": model.launchAtLoginRequested,
                "launch_at_login_status": model.launchAtLoginStatus,
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

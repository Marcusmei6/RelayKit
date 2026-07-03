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
    private let smokeEvidencePath = value(after: "--ui-smoke-evidence")

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
            rootView: ContentView(initialTab: smokeTab, showProviderForm: smokeShowsProvider) { [weak self] section in
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
                    self?.writeSmokeEvidence()
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

    private func writeSmokeEvidence() {
        guard let smokeEvidencePath else { return }
        let buttonFrame = statusItem?.button?.window?.frame ?? .zero
        let activeTab = smokeShowsProvider ? "provider" : smokeTab.rawValue
        let contentWindow = popover.contentViewController?.view.window
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
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: smokeEvidencePath), options: .atomic)
        } catch {
            fputs("failed to write UI smoke evidence: \(error)\n", stderr)
        }
    }
}

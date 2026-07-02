import AppKit
import Foundation
import SwiftUI

@main
@MainActor
final class RelayKitApp: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private let smokeTab = Tab(rawValue: value(after: "--ui-smoke-tab") ?? "") ?? .connect
    private let smokeShowsProvider = CommandLine.arguments.contains("--ui-smoke-provider")

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
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "RelayKit")
        statusItem.button?.title = " RelayKit"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        self.statusItem = statusItem

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 460, height: 620)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(initialTab: smokeTab, showProviderForm: smokeShowsProvider)
                .environmentObject(model)
                .frame(width: 460, height: 620)
        )

        if CommandLine.arguments.contains("--ui-smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApplication.shared.activate()
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
}

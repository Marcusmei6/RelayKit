import Foundation
import SwiftUI

@main
struct RelayKitApp: App {
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--verify-bundled-gateway") {
            exit(BundledGatewayVerifier.run(arguments: CommandLine.arguments))
        }
    }

    var body: some Scene {
        MenuBarExtra("RelayKit", systemImage: "bolt.horizontal.circle") {
            ContentView()
                .environmentObject(model)
                .frame(width: 460, height: 620)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

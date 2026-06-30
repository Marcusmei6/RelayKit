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
        WindowGroup("RelayKit") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

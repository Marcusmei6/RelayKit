import SwiftUI

@main
struct RelayKitApp: App {
    @StateObject private var model = AppModel()

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
